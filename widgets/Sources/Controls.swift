import SwiftUI
import WidgetKit
import AppIntents
import HouseCore

// Controls: Control Center, the Lock Screen and the Action button on the iPhone (iOS 18),
// Control Center and the menu bar on the Mac (macOS 26).

// MARK: - Intents the controls run (also offered to Shortcuts)

struct SetLightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Switch a Light"
    static let description = IntentDescription("Turns a House Control lamp on or off.")
    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "On") var value: Bool

    init() {}
    init(light: LightEntity) { self.light = light }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.light(light.id, on: value))
        return .result()
    }
}

struct SetAllLightsIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Switch Every Light"
    static let description = IntentDescription("Turns every lamp of the home on or off.")
    @Parameter(title: "On") var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.allLights(on: value))
        return .result()
    }
}

struct SetClimateIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Switch an Air Conditioner"
    static let description = IntentDescription("Turns a House Control air conditioner on or off.")
    @Parameter(title: "Air Conditioner") var ac: ACEntity
    @Parameter(title: "On") var value: Bool

    init() {}
    init(ac: ACEntity) { self.ac = ac }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.acPower(ac.id, on: value))
        return .result()
    }
}

struct RunSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply a Scene"
    static let description = IntentDescription("Sets every lamp and air conditioner the way a House Control scene says.")
    @Parameter(title: "Scene") var scene: SceneEntity

    init() {}
    init(scene: SceneEntity) { self.scene = scene }

    func perform() async throws -> some IntentResult {
        await WidgetActions.run(.scene(scene.id))
        return .result()
    }
}

// MARK: - Control configuration

@available(iOS 18.0, macOS 26.0, *)
struct LightControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Light"
    @Parameter(title: "Light") var light: LightEntity?
}

@available(iOS 18.0, macOS 26.0, *)
struct ClimateControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Air Conditioner"
    @Parameter(title: "Air Conditioner") var ac: ACEntity?
}

@available(iOS 18.0, macOS 26.0, *)
struct SceneControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Scene"
    @Parameter(title: "Scene") var scene: SceneEntity?
}

// MARK: - Controls

@available(iOS 18.0, macOS 26.0, *)
struct LightControl: ControlWidget {
    static let kind = "io.github.0xprobabillity.HouseControl.light-control"

    struct Value {
        var light: LightEntity?
        var isOn: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: LightControlConfiguration) -> Value {
            Value(light: configuration.light, isOn: true)
        }

        func currentValue(configuration: LightControlConfiguration) async throws -> Value {
            let home = HomeData.orSample
            let id = configuration.light?.id ?? home.lights.first?.id
            let light = id.flatMap(home.light)
            return Value(light: configuration.light ?? light.map { LightEntity($0, in: home) }, isOn: light?.on ?? false)
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetToggle(value.light?.name ?? "Light", isOn: value.isOn,
                                action: value.light.map(SetLightIntent.init(light:)) ?? SetLightIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "lightbulb.fill" : "lightbulb")
            }
            .tint(.orange)
        }
        .displayName("Light")
        .description("Switch one lamp.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct AllLightsControl: ControlWidget {
    static let kind = "io.github.0xprobabillity.HouseControl.all-lights-control"

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool { (HomeData.current?.lightsOn ?? 0) > 0 }
    }

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("All Lights", isOn: isOn, action: SetAllLightsIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "lightbulb.2.fill" : "lightbulb.2")
            }
            .tint(.orange)
        }
        .displayName("All Lights")
        .description("Every lamp of the home at once.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct ClimateControl: ControlWidget {
    static let kind = "io.github.0xprobabillity.HouseControl.climate-control"

    struct Value {
        var ac: ACEntity?
        var isOn: Bool
        var label: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ClimateControlConfiguration) -> Value {
            Value(ac: configuration.ac, isOn: true, label: "Cool 23°")
        }

        func currentValue(configuration: ClimateControlConfiguration) async throws -> Value {
            let home = HomeData.orSample
            let ac = (configuration.ac?.id ?? home.acs.first?.id).flatMap(home.ac)
            return Value(ac: configuration.ac ?? ac.map { ACEntity($0, in: home) }, isOn: ac?.on ?? false,
                         label: ac.map { $0.on ? "\($0.modeName) \($0.targetText)" : "Off" } ?? "Off")
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetToggle(value.ac?.name ?? "Air Conditioner", isOn: value.isOn,
                                action: value.ac.map(SetClimateIntent.init(ac:)) ?? SetClimateIntent()) { on in
                Label(on ? value.label : "Off", systemImage: on ? "snowflake" : "air.conditioner.horizontal")
            }
            .tint(.cyan)
        }
        .displayName("Air Conditioner")
        .description("Switch an air conditioner on or off.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct SceneControl: ControlWidget {
    static let kind = "io.github.0xprobabillity.HouseControl.scene-control"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: SceneControlConfiguration.self) { configuration in
            ControlWidgetButton(action: configuration.scene.map(RunSceneIntent.init(scene:)) ?? RunSceneIntent()) {
                Label(configuration.scene?.name ?? "Scene", systemImage: configuration.scene?.symbol ?? "sparkles")
            }
        }
        .displayName("Scene")
        .description("Apply a scene with one tap.")
        .promptsForUserConfiguration()
    }
}
