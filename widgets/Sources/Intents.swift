import AppIntents
import WidgetKit
import HouseCore

/// The home the widgets show: what the app last wrote, or the demo apartment before it ran.
enum HomeData {
    static var current: HomeSnapshot? { SharedHome()?.snapshot() }
    static var orSample: HomeSnapshot { current ?? sample }

    static let sample: HomeSnapshot = {
        guard let url = Bundle.main.url(forResource: "sample-home", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let home = try? JSONDecoder().decode(HomeSnapshot.self, from: data) else {
            return HomeSnapshot(name: "Home", plan: "home", rooms: [], lights: [], acs: [], scenes: [])
        }
        return home
    }()
}

// MARK: - Entities (what a configurable widget or control can be pointed at)

struct LightEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightQuery()
    var id: String
    var name: String
    var room: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(room)", image: .init(systemName: "lightbulb.fill"))
    }

    init(_ light: HomeSnapshot.Light, in home: HomeSnapshot) {
        id = light.id
        name = light.name
        room = home.room(light.room)?.name ?? light.room
    }
}

struct LightQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LightEntity] {
        let home = HomeData.orSample
        return identifiers.compactMap { id in home.light(id).map { LightEntity($0, in: home) } }
    }

    func suggestedEntities() async throws -> [LightEntity] {
        let home = HomeData.orSample
        return home.lights.map { LightEntity($0, in: home) }
    }

    func defaultResult() async -> LightEntity? { try? await suggestedEntities().first }
}

struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomQuery()
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "square.split.bottomrightquarter"))
    }
}

struct RoomQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        let home = HomeData.orSample
        return identifiers.compactMap { id in home.room(id).map { RoomEntity(id: $0.id, name: $0.name) } }
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        HomeData.orSample.roomsWithLights.map { RoomEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> RoomEntity? { try? await suggestedEntities().first }
}

struct ACEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Air Conditioner"
    static let defaultQuery = ACQuery()
    var id: String
    var name: String
    var room: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(room)", image: .init(systemName: "air.conditioner.horizontal.fill"))
    }

    init(_ ac: HomeSnapshot.AC, in home: HomeSnapshot) {
        id = ac.id
        name = ac.name
        room = home.room(ac.room)?.name ?? ac.room
    }
}

struct ACQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ACEntity] {
        let home = HomeData.orSample
        return identifiers.compactMap { id in home.ac(id).map { ACEntity($0, in: home) } }
    }

    func suggestedEntities() async throws -> [ACEntity] {
        let home = HomeData.orSample
        return home.acs.map { ACEntity($0, in: home) }
    }

    func defaultResult() async -> ACEntity? { try? await suggestedEntities().first }
}

struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneQuery()
    var id: String
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(_ scene: HomeSnapshot.Scene) {
        id = scene.id
        name = scene.name
        symbol = scene.symbol
    }
}

struct SceneQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        let home = HomeData.orSample
        return identifiers.compactMap { id in home.scenes.first { $0.id == id }.map(SceneEntity.init) }
    }

    func suggestedEntities() async throws -> [SceneEntity] { HomeData.orSample.scenes.map(SceneEntity.init) }

    func defaultResult() async -> SceneEntity? { try? await suggestedEntities().first }
}

// MARK: - Widget configuration

struct LightConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Light"
    static let description = IntentDescription("Choose the lamp this widget switches.")
    @Parameter(title: "Light") var light: LightEntity?
}

struct RoomConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Room"
    static let description = IntentDescription("Choose the room whose lamps this widget shows.")
    @Parameter(title: "Room") var room: RoomEntity?
}

struct ClimateConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Air Conditioner"
    static let description = IntentDescription("Choose the air conditioner this widget controls.")
    @Parameter(title: "Air Conditioner") var ac: ACEntity?
}

// MARK: - Actions behind the widgets' buttons

struct ToggleLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Light"
    static let isDiscoverable = false
    @Parameter(title: "Light") var lightID: String

    init() {}
    init(lightID: String) { self.lightID = lightID }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.light(lightID))
        return .result()
    }
}

struct ToggleRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Room Lights"
    static let isDiscoverable = false
    @Parameter(title: "Room") var roomID: String
    @Parameter(title: "On") var on: Bool?

    init() {}
    init(roomID: String, on: Bool? = nil) { self.roomID = roomID; self.on = on }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.room(roomID, on: on))
        return .result()
    }
}

struct AllLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch All Lights"
    static let isDiscoverable = false
    @Parameter(title: "On") var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.allLights(on: on))
        return .result()
    }
}

struct ApplySceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Scene"
    static let isDiscoverable = false
    @Parameter(title: "Scene") var sceneID: String

    init() {}
    init(sceneID: String) { self.sceneID = sceneID }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.scene(sceneID))
        return .result()
    }
}

struct ACPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Air Conditioner"
    static let isDiscoverable = false
    @Parameter(title: "Air Conditioner") var acID: String

    init() {}
    init(acID: String) { self.acID = acID }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.acPower(acID))
        return .result()
    }
}

struct ACStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Temperature"
    static let isDiscoverable = false
    @Parameter(title: "Air Conditioner") var acID: String
    @Parameter(title: "Step") var step: Int

    init() {}
    init(acID: String, step: Int) { self.acID = acID; self.step = step }

    func perform() async throws -> some IntentResult {
        guard let ac = HomeData.current?.ac(acID) else { return .result() }
        await WidgetActions.run(.acTarget(acID, ac.target + Double(step)))
        return .result()
    }
}
