import Foundation

struct ChangelogEntry: Identifiable {
    let version: String
    let date: String
    let changes: [String]
    var id: String { version }
}

/// Version history shown in the app. Newest first. Keep in step with version.txt.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.0.0", date: "2026-11-18",
            changes: [
                "First iPhone release. It follows the Android app (v1.4.0): the nearest VATSIM or IVAO aircraft to your callsign or to an airport, as a list or on a map.",
                "Callsign can be typed or fetched from SimBrief (auto-fetch is a setting), with auto refresh every 3 minutes (15 s to 10 min) while the app is on screen.",
                "Active ATC (with controller names), a Listen helper, the networks' web maps, and an optional IVAO API key for names.",
                "The map uses Apple Maps. Tapping an aircraft shows its route (this downloads the airport list once, about 12 MB). The \"All routes\" view is not in the iPhone app yet.",
            ]
        ),
    ]

    private static func key(_ version: String) -> Int {
        let p = version.split(separator: ".").map { Int($0) ?? 0 }
        func at(_ i: Int) -> Int { i < p.count ? p[i] : 0 }
        return at(0) * 1_000_000 + at(1) * 1_000 + at(2)
    }

    /// Entries to show on start: everything newer than `lastSeen` up to `current`. On a fresh install
    /// only the latest entry is shown.
    static func newerThan(_ lastSeen: String?, current: String) -> [ChangelogEntry] {
        let upToCurrent = entries.filter { key($0.version) <= key(current) }
        guard let lastSeen = lastSeen else { return Array(upToCurrent.prefix(1)) }
        return upToCurrent.filter { key($0.version) > key(lastSeen) }
    }
}
