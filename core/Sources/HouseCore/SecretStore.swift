import Foundation
import Security

/// Where a secret (the Smart Life session, the sync key) is kept. The Mac app uses a
/// file only its user can read, next to the plan; the iPhone app uses the Keychain.
public protocol SecretStore {
    func read() -> Data?
    /// Stores `data`; nil removes the secret.
    func write(_ data: Data?)
    /// Changes whenever another process rewrites the secret. Nil when that cannot happen.
    var stamp: Date? { get }
    /// A file every process sharing the secret can lock around a read-modify-write of it
    /// (a Smart Life token refresh). Nil when no other process shares it.
    var lockURL: URL? { get }
}

public extension SecretStore {
    var lockURL: URL? { nil }
}

public struct FileSecretStore: SecretStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> Data? { try? Data(contentsOf: url) }

    public func write(_ data: Data?) {
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public var stamp: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `smartlife.json.lock` next to the file: the Mac app and `--diagnose` share it.
    public var lockURL: URL? { URL(fileURLWithPath: url.path + ".lock") }
}

/// A generic-password Keychain item that never leaves this device (no iCloud Keychain,
/// not part of a backup restored to another phone).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String
    /// Where the lock file goes: the App Group container the app shares with its widgets.
    public let lockDirectory: URL?

    public init(service: String, account: String, lockDirectory: URL? = nil) {
        self.service = service
        self.account = account
        self.lockDirectory = lockDirectory
    }

    public var lockURL: URL? { lockDirectory?.appendingPathComponent(".\(account).lock") }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    /// When the item was last written. The iPhone's widgets share these items with the app
    /// (one Keychain access group), and a Smart Life refresh in one process rotates the token
    /// the other one holds.
    public var stamp: Date? {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attributes = out as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }
}

/// An exclusive `flock` on a file, held across `await`s: the app and its widgets run in
/// separate processes and must not refresh one Smart Life session at the same time.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Waits up to `timeout` seconds for the lock without blocking the caller's thread;
    /// nil when the file cannot be opened or the other holder never lets go.
    public static func acquire(_ url: URL, timeout: TimeInterval = 15) async -> FileLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return FileLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Keeps a secret in memory only (tests, throw-away runs).
public final class MemorySecretStore: SecretStore {
    private var data: Data?
    public init(_ data: Data? = nil) { self.data = data }
    public func read() -> Data? { data }
    public func write(_ data: Data?) { self.data = data }
    public var stamp: Date? { nil }
}
