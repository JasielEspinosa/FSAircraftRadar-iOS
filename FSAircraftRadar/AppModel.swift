import Foundation
import SwiftUI

private let justLoadedSeconds: TimeInterval = 10
private let settingsKey = "settings-v1"

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            if oldValue.ivaoApiKey != settings.ivaoApiKey {
                ivaoKeyRejected = false
                failedNameLookups.removeAll()
            }
            if oldValue.maxAircraft != settings.maxAircraft || oldValue.maxRangeNm != settings.maxRangeNm {
                rebuild(resolveNames: true)
            }
        }
    }
    @Published var sort: SortOption {
        didSet { if oldValue != sort { rebuild(resolveNames: false) } }
    }
    @Published var loading = false
    @Published var error: String? = nil
    @Published var rows: [AircraftRow] = []
    @Published var controllerRows: [ControllerRow] = []
    @Published var referenceSource: ReferenceSource = .none
    @Published var referencePoint: Coord? = nil
    /// Your own aircraft (Callsign mode, when it is online).
    @Published var referenceAircraft: Aircraft? = nil
    @Published var airport: Airport? = nil
    @Published var lastUpdated: Date? = nil
    @Published var simbriefBusy = false
    @Published var message: String? = nil
    @Published var showChangelog = false
    @Published var changelogEntries: [ChangelogEntry] = []
    /// Positions of airports used for a selected aircraft's route on the map (ICAO -> position).
    @Published var routeAirports: [String: Coord] = [:]

    private var feed: [Aircraft] = []
    private var controllerFeed: [Controller] = []
    private var ivaoNames: [Int: String] = [:]
    private var failedNameLookups = Set<Int>()
    private var ivaoKeyRejected = false

    private var loadTask: Task<Void, Never>? = nil
    private var simbriefTask: Task<Void, Never>? = nil
    private var nameTask: Task<Void, Never>? = nil
    private var started = false
    private var lastAttempt: Date? = nil

    init() {
        var initial = AppSettings()
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            initial = saved
        }
        settings = initial
        sort = initial.defaultSort
        showChangelogIfNew()
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    var canLoad: Bool {
        switch settings.referenceMode {
        case .callsign: return !settings.callsign.isEmpty
        case .airport: return settings.airportIcao.count == 4
        }
    }

    var hasLoaded: Bool { lastUpdated != nil }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: Version changes

    private func showChangelogIfNew() {
        let entries = Changelog.newerThan(settings.lastSeenVersion, current: currentVersion)
        if !entries.isEmpty {
            changelogEntries = entries
            showChangelog = true
        }
        settings.lastSeenVersion = currentVersion
    }

    func showFullChangelog() {
        changelogEntries = Changelog.entries
        showChangelog = true
    }

    // MARK: Actions

    func setNetwork(_ network: Network) {
        if network == settings.network { return }
        settings.network = network
        feed = []
        controllerFeed = []
        rows = []
        controllerRows = []
        error = nil
        if canLoad { refresh() }
    }

    func setReferenceMode(_ mode: ReferenceMode) {
        if mode == settings.referenceMode { return }
        loadTask?.cancel()
        simbriefTask?.cancel()
        simbriefBusy = false
        loading = false
        settings.referenceMode = mode
        rows = []
        controllerRows = []
        referenceSource = .none
        referencePoint = nil
        referenceAircraft = nil
        airport = nil
        error = nil
        loadWithAutoSimbrief()
    }

    /// Makes `callsign` (an aircraft tapped on the map) your callsign and re-centres everything on it.
    func useAsCallsign(_ callsign: String) {
        let cs = normalizeCallsign(callsign)
        if cs.isEmpty { return }
        simbriefTask?.cancel()
        simbriefBusy = false
        settings.callsign = cs
        settings.referenceMode = .callsign
        airport = nil
        rebuild(resolveNames: true)
        message = "Callsign set to \(cs)"
    }

    /// Start of the app, and switching to the Callsign tab: SimBrief first when enabled, then load.
    func loadWithAutoSimbrief() {
        if settings.referenceMode == .callsign && settings.autoFetchSimbrief
            && !settings.simbriefId.trimmingCharacters(in: .whitespaces).isEmpty {
            fetchCallsignFromSimbrief(auto: true)
        } else {
            refresh()
        }
    }

    func fetchCallsignFromSimbrief(auto: Bool = false) {
        let id = settings.simbriefId.trimmingCharacters(in: .whitespaces)
        if id.isEmpty {
            if !auto { message = "Enter your SimBrief username or Pilot ID in Settings first." }
            if auto { refresh() }
            return
        }
        simbriefTask?.cancel()
        simbriefBusy = true
        simbriefTask = Task { [self] in
            do {
                let cs = try await SimBrief.fetchCallsign(id)
                if Task.isCancelled { return }
                let changed = cs != settings.callsign
                settings.callsign = cs
                simbriefBusy = false
                if !auto || changed { message = "Callsign set to \(cs)" }
                refresh()
            } catch {
                if Task.isCancelled { return }
                simbriefBusy = false
                if !auto { message = error.localizedDescription }
                if auto { refresh() }
            }
        }
    }

    /// Downloads the network feed (and the airport, in Closest Airport mode) and rebuilds the list.
    func refresh() {
        guard canLoad else { return }
        loadTask?.cancel()
        loading = true
        error = nil
        lastAttempt = Date()
        let s = settings
        loadTask = Task { [self] in
            do {
                var found: Airport? = nil
                if s.referenceMode == .airport {
                    found = try await AirportStore.shared.find(s.airportIcao)
                    if found == nil { throw AppError("Unknown airport code \(s.airportIcao).") }
                }
                let snapshot: TrafficSnapshot
                if s.network == .vatsim {
                    snapshot = try await VatsimFeed.fetch()
                } else {
                    snapshot = try await IvaoFeed.fetch()
                }
                if Task.isCancelled { return }
                feed = snapshot.aircraft
                controllerFeed = snapshot.controllers
                airport = found
                lastUpdated = Date()
                loading = false
                rebuild(resolveNames: true)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                loading = false
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs while the app is on screen: first load, a refresh each time it comes back, then every N seconds.
    func keepFresh() async {
        if !started {
            started = true
            loadWithAutoSimbrief()
        } else if canLoad && !loading && !justLoaded() {
            refresh()
        }
        while !Task.isCancelled {
            if !settings.autoRefresh {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            let seconds = min(max(settings.autoRefreshSec, minRefreshSec), maxRefreshSec)
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if Task.isCancelled { break }
            if settings.autoRefresh && canLoad && !loading { refresh() }
        }
    }

    private func justLoaded() -> Bool {
        guard let t = lastAttempt else { return false }
        return Date().timeIntervalSince(t) < justLoadedSeconds
    }

    // MARK: Build the lists

    /// Recomputes distances and ordering from the cached feed.
    private func rebuild(resolveNames: Bool) {
        let own = settings.callsign
        var ownAircraft: Aircraft? = nil
        if !own.isEmpty { ownAircraft = feed.first { $0.callsign.caseInsensitiveCompare(own) == .orderedSame } }

        var reference: Coord? = nil
        var source = ReferenceSource.none
        if settings.referenceMode == .airport {
            if let a = airport {
                reference = Coord(lat: a.latitude, lon: a.longitude)
                source = .airport
            }
        } else if let o = ownAircraft {
            reference = Coord(lat: o.latitude, lon: o.longitude)
            source = .ownAircraft
        }

        let candidates: [Aircraft] = (settings.referenceMode == .callsign && reference == nil) ? [] : feed
        var built: [AircraftRow] = []
        for ac in candidates {
            if ownAircraft != nil && ac.callsign.caseInsensitiveCompare(own) == .orderedSame { continue }
            let resolved = ac.name ?? ivaoNames[ac.userId]
            var distance: Double? = nil
            if let r = reference { distance = Geo.distanceNm(r.lat, r.lon, ac.latitude, ac.longitude) }
            built.append(AircraftRow(
                aircraft: ac, distanceNm: distance, displayName: resolved ?? ac.idLabel, nameKnown: resolved != nil
            ))
        }
        let inRange = Sorting.withinRange(built, settings.maxRangeNm)
        let sorted = Sorting.nearestThenSort(inRange, limit: settings.maxAircraft, option: sort)

        var controllers: [ControllerRow] = []
        if let r = reference {
            let isIvao = settings.network == .ivao
            let prefix = isIvao ? "VID" : "CID"
            controllers = Sorting.controllersInRange(controllerFeed, lat: r.lat, lon: r.lon, rangeNm: settings.maxRangeNm)
            for i in controllers.indices {
                let c = controllers[i].controller
                var name = c.name
                if name == nil && isIvao { name = ivaoNames[c.userId] }
                if name == nil && c.userId != 0 { name = "\(prefix) \(c.userId)" }
                controllers[i].displayName = name
            }
        }

        rows = sorted
        controllerRows = controllers
        referenceSource = source
        referencePoint = reference
        referenceAircraft = source == .ownAircraft ? ownAircraft : nil

        if resolveNames && settings.network == .ivao { resolveIvaoNames(top: sorted, controllers: controllers) }
    }

    // MARK: IVAO names

    private func resolveIvaoNames(top: [AircraftRow], controllers: [ControllerRow]) {
        let key = settings.ivaoApiKey
        if key.isEmpty || ivaoKeyRejected { return }
        var wanted: [(Int, Int)] = []
        for r in top { wanted.append((r.aircraft.userId, r.aircraft.sessionId)) }
        for r in controllers { wanted.append((r.controller.userId, r.controller.sessionId)) }
        var seen = Set<Int>()
        var todo: [(Int, Int)] = []
        for (uid, sid) in wanted {
            if uid == 0 || ivaoNames[uid] != nil || failedNameLookups.contains(uid) || seen.contains(uid) { continue }
            seen.insert(uid)
            todo.append((uid, sid))
        }
        if todo.isEmpty { return }

        nameTask?.cancel()
        nameTask = Task { [self] in
            var found = false
            var index = 0
            while index < todo.count && !Task.isCancelled {
                let batch = Array(todo[index..<min(index + 4, todo.count)])
                index += 4
                let results: [(Int, String?, Bool)] = await withTaskGroup(of: (Int, String?, Bool).self) { group in
                    for (uid, sid) in batch {
                        group.addTask {
                            do {
                                let n = try await IvaoFeed.fetchName(userId: uid, sessionId: sid, apiKey: key)
                                return (uid, n, false)
                            } catch is IvaoAuthError {
                                return (uid, nil, true)
                            } catch {
                                return (uid, nil, false)
                            }
                        }
                    }
                    var collected: [(Int, String?, Bool)] = []
                    for await r in group { collected.append(r) }
                    return collected
                }
                for (uid, name, rejected) in results {
                    if rejected { ivaoKeyRejected = true }
                    if let n = name {
                        ivaoNames[uid] = n
                        found = true
                    } else if !rejected {
                        failedNameLookups.insert(uid)
                    }
                }
                if ivaoKeyRejected { break }
            }
            if Task.isCancelled { return }
            if ivaoKeyRejected { message = "IVAO rejected the API key, so names can't be looked up." }
            if found { rebuild(resolveNames: false) }
        }
    }

    // MARK: Routes (map)

    /// Finds the departure/arrival airports of an aircraft so its route can be drawn.
    func loadRoute(for aircraft: Aircraft) {
        let codes = [aircraft.departure, aircraft.arrival]
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && routeAirports[$0] == nil }
        if codes.isEmpty { return }
        Task { [self] in
            for code in codes {
                if let a = try? await AirportStore.shared.find(code) {
                    routeAirports[code] = Coord(lat: a.latitude, lon: a.longitude)
                }
            }
        }
    }
}
