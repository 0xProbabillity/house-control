#if os(iOS) && canImport(HomeKit)
import HomeKit

/// Apple Home through HomeKit: every lamp, outlet, air conditioner (heater cooler or
/// thermostat) and temperature sensor in the user's homes, Matter devices included.
/// HomeKit is only offered to iPhone and iPad apps (and to Mac Catalyst apps from the
/// App Store), so the Mac reaches it through the iPhone's catalog — see `RemoteCatalogService`.
///
/// Nothing is asked of the user until `enable()` — creating the home manager is what shows
/// the system's "would like to access your Home Data" prompt.
@MainActor
public final class HomeKitService: NSObject, DeviceService {
    public let id = "homekit"
    public let title = "Apple Home"
    public var onChange: (() -> Void)?
    /// Called whenever the list of homes, accessories or rooms changes.
    public var onCatalogChange: (() -> Void)?

    private var manager: HMHomeManager?
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watched: Set<String> = []
    /// Lamps last set to a white temperature (true) or a colour (false) from this app.
    private var whiteMode: [String: Bool] = [:]
    private static let enabledKey = "homekit.enabled"

    public override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    public var isEnabled: Bool { manager != nil }
    public var isConnected: Bool { manager != nil && authorized }
    private var authorized: Bool { manager?.authorizationStatus.contains(.authorized) == true }
    /// True when the user said no to the system prompt (Settings → Privacy → HomeKit undoes it).
    public var isDenied: Bool {
        guard let status = manager?.authorizationStatus else { return false }
        return status.contains(.determined) && !status.contains(.authorized)
    }

    public var info: [String: Any] {
        guard let manager else { return ["connected": false] }
        let homes = manager.homes.map(\.name)
        return ["connected": isConnected, "denied": isDenied, "homes": homes,
                "accessories": manager.homes.reduce(0) { $0 + $1.accessories.count }]
    }

    /// Starts HomeKit (and with it the permission prompt the first time).
    public func enable() async {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start()
        await untilReady()
    }

    public func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        manager?.delegate = nil
        manager = nil
        ready = false
    }

    public func watch(_ ids: Set<String>) {
        watched = ids
        subscribe()
    }

    private func start() {
        guard manager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    private func untilReady(timeout: Double = 20) async {
        guard !ready, manager != nil else { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.release()
            }
        }
    }

    private func release() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }

    // MARK: - Catalog

    private struct Entry {
        let service: HMService
        let accessory: HMAccessory
        let kind: HomeKitMapper.Kind
        let home: HMHome
    }

    private func entries() -> [Entry] {
        var out: [Entry] = []
        for home in manager?.homes ?? [] {
            for accessory in home.accessories {
                for service in accessory.services {
                    guard let kind = HomeKitMapper.kind(ofService: service.serviceType) else { continue }
                    out.append(Entry(service: service, accessory: accessory, kind: kind, home: home))
                }
            }
        }
        return out
    }

    private func names(_ service: HMService) -> [String: HMCharacteristic] {
        var out: [String: HMCharacteristic] = [:]
        for c in service.characteristics {
            if let name = HomeKitMapper.name(ofCharacteristic: c.characteristicType) { out[name] = c }
        }
        return out
    }

    public func devices() async throws -> [ServiceDevice] {
        guard manager != nil else { throw ServiceFailure("Turn on Apple Home first") }
        await untilReady()
        guard authorized else { throw ServiceFailure("House Control may not use your Home data. Allow it in Settings → Privacy & Security → HomeKit.") }
        let several = (manager?.homes.count ?? 0) > 1
        return entries().map { entry in
            let characteristics = Set(names(entry.service).keys)
            let label = entry.service.name.isEmpty ? entry.accessory.name : entry.service.name
            let room = entry.accessory.room.map { several ? "\(entry.home.name) · \($0.name)" : $0.name }
            var device = ServiceDevice(id: entry.service.uniqueIdentifier.uuidString, name: label, kind: entry.kind.device, room: room)
            device.online = entry.accessory.isReachable
            if entry.kind == .light { device.capabilities = HomeKitMapper.capabilities(characteristics) }
            if entry.kind.device == .ac {
                let key = entry.kind == .thermostat ? "targetTemperature" : "coolingThreshold"
                if let c = names(entry.service)[key], let lo = c.metadata?.minimumValue?.doubleValue,
                   let hi = c.metadata?.maximumValue?.doubleValue { device.range = (lo, hi) }
            }
            let maker = entry.accessory.manufacturer.map { "\($0) · " } ?? ""
            device.detail = maker + entry.kind.rawValue
            return device
        }.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard isConnected else { return [:] }
        await untilReady()
        var out: [String: DeviceReading] = [:]
        for entry in entries() where ids.contains(entry.service.uniqueIdentifier.uuidString) {
            let id = entry.service.uniqueIdentifier.uuidString
            guard entry.accessory.isReachable else { out[id] = DeviceReading(online: false); continue }
            var values: [String: Any] = [:]
            for (name, characteristic) in names(entry.service) {
                try? await characteristic.readValue()
                if let value = characteristic.value { values[name] = value }
            }
            switch entry.kind {
            case .light, .outlet:
                out[id] = DeviceReading(light: HomeKitMapper.lightState(values, whiteMode: whiteMode[id]))
            case .heaterCooler, .thermostat:
                let has = Set(names(entry.service).keys)
                let valid = names(entry.service)[entry.kind == .thermostat ? "targetHeatingCooling" : "targetState"]?
                    .metadata?.validValues?.map(\.intValue)
                out[id] = DeviceReading(ac: HomeKitMapper.acState(values, kind: entry.kind),
                                        features: HomeKitMapper.acFeatures(kind: entry.kind, has: has, validModes: valid))
            case .sensor:
                out[id] = DeviceReading(temperature: values.double("currentTemperature"))
            }
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        guard let entry = entries().first(where: { $0.service.uniqueIdentifier.uuidString == id }) else {
            throw ServiceFailure("This device is no longer in Apple Home")
        }
        guard entry.accessory.isReachable else { throw ServiceFailure("\(entry.accessory.name) is not responding") }
        let characteristics = names(entry.service)
        var limits: [String: (Double, Double)] = [:]
        for (name, c) in characteristics {
            if let lo = c.metadata?.minimumValue?.doubleValue, let hi = c.metadata?.maximumValue?.doubleValue { limits[name] = (lo, hi) }
        }
        let has = Set(characteristics.keys)
        let writes = kind == .light
            ? HomeKitMapper.lightWrites(DeviceKind.withPower(patch, state: state), kind: entry.kind, has: has, limits: limits)
            : HomeKitMapper.acWrites(patch, state: state, kind: entry.kind, has: has, limits: limits)
        if patch["temp"] != nil { whiteMode[id] = true }
        if patch["color"] is String { whiteMode[id] = false }
        for (name, value) in writes {
            guard let characteristic = characteristics[name] else { continue }
            do {
                try await characteristic.writeValue(value)
            } catch {
                throw ServiceFailure("\(entry.accessory.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Live updates

    private func subscribe() {
        for entry in entries() where watched.contains(entry.service.uniqueIdentifier.uuidString) {
            entry.accessory.delegate = self
            for (_, characteristic) in names(entry.service)
            where characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) && !characteristic.isNotificationEnabled {
                characteristic.enableNotification(true) { _ in }
            }
        }
    }
}

extension HomeKitService: HMHomeManagerDelegate, HMAccessoryDelegate, HMHomeDelegate {
    nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated {
            ready = true
            for home in manager.homes { home.delegate = self }
            release()
            subscribe()
            onCatalogChange?()
        }
    }

    nonisolated public func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        MainActor.assumeIsolated { onCatalogChange?() }
    }

    nonisolated public func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        MainActor.assumeIsolated { subscribe(); onCatalogChange?() }
    }

    nonisolated public func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        MainActor.assumeIsolated { onCatalogChange?() }
    }

    nonisolated public func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        MainActor.assumeIsolated { onChange?() }
    }

    nonisolated public func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        MainActor.assumeIsolated { onChange?() }
    }
}
#endif
