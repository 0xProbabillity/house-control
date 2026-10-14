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
}

/// A generic-password Keychain item that never leaves this device (no iCloud Keychain,
/// not part of a backup restored to another phone).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

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

/// Keeps a secret in memory only (tests, throw-away runs).
public final class MemorySecretStore: SecretStore {
    private var data: Data?
    public init(_ data: Data? = nil) { self.data = data }
    public func read() -> Data? { data }
    public func write(_ data: Data?) { self.data = data }
    public var stamp: Date? { nil }
}
