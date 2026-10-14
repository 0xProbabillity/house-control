import WidgetKit
import AppIntents
import HouseCore

struct HomeEntry: TimelineEntry {
    let date: Date
    let home: HomeSnapshot
    /// True while the app has not written a home yet: the demo apartment stands in.
    let isSample: Bool
}

/// The app reloads the widgets whenever the home changes; the half-hourly refresh only
/// catches a simulated room temperature creeping towards its set-point.
private let refresh: TimeInterval = 30 * 60

struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        HomeEntry(date: .now, home: HomeData.sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(refresh))))
    }

    private func entry() -> HomeEntry {
        let current = HomeData.current
        return HomeEntry(date: .now, home: current ?? HomeData.sample, isSample: current == nil)
    }
}

struct ConfiguredEntry<Configuration: WidgetConfigurationIntent>: TimelineEntry {
    let date: Date
    let home: HomeSnapshot
    let isSample: Bool
    let configuration: Configuration
}

/// One provider for the widgets that are pointed at a lamp, a room or an AC.
struct ConfiguredProvider<Configuration: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    typealias Entry = ConfiguredEntry<Configuration>

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, home: HomeData.sample, isSample: true, configuration: Configuration())
    }

    func snapshot(for configuration: Configuration, in context: Context) async -> Entry {
        entry(configuration)
    }

    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [entry(configuration)], policy: .after(.now.addingTimeInterval(refresh)))
    }

    private func entry(_ configuration: Configuration) -> Entry {
        let current = HomeData.current
        return Entry(date: .now, home: current ?? HomeData.sample, isSample: current == nil, configuration: configuration)
    }
}
