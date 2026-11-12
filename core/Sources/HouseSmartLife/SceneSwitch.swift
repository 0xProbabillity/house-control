import Foundation

/// An explicit pair of Tap-to-Run actions for a learned IR light switch.
enum SceneSwitch {
    struct Command { let homeId: String; let sceneId: String; let on: Bool }

    static func command(link: [String: Any], patch: [String: Any]) throws -> Command {
        guard let pair = link["sceneSwitch"] as? [String: Any],
              let home = pair["homeId"] as? String, !home.isEmpty,
              let onScene = pair["on"] as? String, !onScene.isEmpty,
              let offScene = pair["off"] as? String, !offScene.isEmpty,
              onScene != offScene, let on = patch["on"] as? Bool else {
            throw SmartLifeService.Failure(message: "Link separate Smart Life ON and OFF commands for this IR light")
        }
        guard Set(patch.keys).isSubset(of: ["on"]) else {
            throw SmartLifeService.Failure(message: "This IR light supports on/off only")
        }
        return Command(homeId: home, sceneId: on ? onScene : offScene, on: on)
    }
}
