import Foundation
import SwiftUI

struct AppError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

enum Network: String, CaseIterable, Identifiable, Codable {
    case vatsim = "VATSIM"
    case ivao = "IVAO"
    var id: String { rawValue }
    var label: String { rawValue }
}

enum SortOption: String, CaseIterable, Identifiable, Codable {
    case distance = "Distance"
    case callsign = "Callsign"
    case aircraftType = "Aircraft type"
    case name = "Name"
    case altitude = "Altitude"
    case route = "Route"
    var id: String { rawValue }
    var label: String { rawValue }
}

enum ThemeMode: String, CaseIterable, Identifiable, Codable {
    case system = "Follow phone's theme"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var label: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ReferenceMode: String, CaseIterable, Identifiable, Codable {
    case callsign = "Callsign"
    case airport = "Closest Airport"
    var id: String { rawValue }
    var label: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable, Codable {
    case list = "List"
    case map = "Map"
    var id: String { rawValue }
    var label: String { rawValue }
}

enum ReferenceSource { case ownAircraft, airport, none }

struct Coord: Equatable, Hashable, Codable {
    var lat: Double
    var lon: Double
}

struct Airport {
    let icao: String
    let name: String
    let latitude: Double
    let longitude: Double
}

/// One pilot/aircraft as reported by a network feed.
struct Aircraft: Identifiable {
    let callsign: String
    let aircraftType: String
    /// Real pilot name if the feed provides one.
    let name: String?
    /// VATSIM CID or IVAO VID.
    let userId: Int
    /// Fallback label when no name is known, e.g. "CID 123456".
    let idLabel: String
    let latitude: Double
    let longitude: Double
    let altitudeFt: Int
    let departure: String
    let arrival: String
    /// IVAO tracker session id (used to look up the pilot's name); 0 when not applicable.
    var sessionId: Int = 0
    var headingDeg: Int = 0

    var id: String { "\(callsign)-\(userId)" }

    var route: String {
        if departure.isEmpty && arrival.isEmpty { return "—" }
        return "\(departure.isEmpty ? "????" : departure) – \(arrival.isEmpty ? "????" : arrival)"
    }
}

struct AircraftRow: Identifiable {
    let aircraft: Aircraft
    let distanceNm: Double?
    let displayName: String
    let nameKnown: Bool
    var id: String { aircraft.id }
}

/// An air traffic controller that is online. `points` are the radio sites / position (at least one).
struct Controller: Identifiable {
    let callsign: String
    /// DEL, GND, TWR, APP, CTR, FSS (IVAO may use others).
    let position: String
    /// MHz, or nil when the feed has no real frequency.
    let frequency: Double?
    let userId: Int
    let points: [Coord]
    var name: String? = nil
    var sessionId: Int = 0

    var id: String { "\(callsign)-\(userId)" }

    /// Centre of the points (longitudes are averaged relative to the first so the date line is safe).
    var centre: Coord {
        let baseLon = points[0].lon
        var sum = 0.0
        for p in points {
            sum += ((p.lon - baseLon + 540.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
        }
        let lon = baseLon + sum / Double(points.count)
        let lat = points.map { $0.lat }.reduce(0, +) / Double(points.count)
        return Coord(lat: lat, lon: (lon + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0)
    }

    var positionLabel: String {
        switch position {
        case "DEL": return "Delivery"
        case "GND": return "Ground"
        case "TWR": return "Tower"
        case "APP": return "Approach"
        case "DEP": return "Departure"
        case "CTR": return "Centre"
        case "FSS": return "Flight Service"
        default: return position
        }
    }
}

struct ControllerRow: Identifiable {
    let controller: Controller
    let distanceNm: Double?
    var displayName: String?
    var id: String { controller.id }
}

struct TrafficSnapshot {
    let aircraft: [Aircraft]
    let controllers: [Controller]
}

let maxAircraftLimit = 100
let defaultAircraftCount = 30
let rangeMinNm = 5
let rangeMaxNm = 300
let defaultRangeNm = 50
let rangeStepNm = 5
let minRefreshSec = 15
let maxRefreshSec = 600
let defaultRefreshSec = 180
let refreshStepSec = 15

struct AppSettings: Codable, Equatable {
    var callsign: String = ""
    var themeMode: ThemeMode = .system
    var viewMode: ViewMode = .list
    var referenceMode: ReferenceMode = .callsign
    /// 4-letter ICAO code used in Closest Airport mode.
    var airportIcao: String = ""
    var maxAircraft: Int = defaultAircraftCount
    var maxRangeNm: Int = defaultRangeNm
    var simbriefId: String = ""
    var autoRefresh: Bool = true
    var autoRefreshSec: Int = defaultRefreshSec
    /// The user's own choice for auto-fetching the callsign from SimBrief; nil = never chosen.
    var autoSimbrief: Bool? = nil
    var network: Network = .vatsim
    var defaultSort: SortOption = .distance
    var ivaoApiKey: String = ""
    var lastSeenVersion: String? = nil

    init() {}

    // Tolerant decoding: settings saved by an older version still load when new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        callsign = try c.decodeIfPresent(String.self, forKey: .callsign) ?? d.callsign
        themeMode = try c.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? d.themeMode
        viewMode = try c.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? d.viewMode
        referenceMode = try c.decodeIfPresent(ReferenceMode.self, forKey: .referenceMode) ?? d.referenceMode
        airportIcao = try c.decodeIfPresent(String.self, forKey: .airportIcao) ?? d.airportIcao
        maxAircraft = try c.decodeIfPresent(Int.self, forKey: .maxAircraft) ?? d.maxAircraft
        maxRangeNm = try c.decodeIfPresent(Int.self, forKey: .maxRangeNm) ?? d.maxRangeNm
        simbriefId = try c.decodeIfPresent(String.self, forKey: .simbriefId) ?? d.simbriefId
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? d.autoRefresh
        autoRefreshSec = try c.decodeIfPresent(Int.self, forKey: .autoRefreshSec) ?? d.autoRefreshSec
        autoSimbrief = try c.decodeIfPresent(Bool.self, forKey: .autoSimbrief)
        network = try c.decodeIfPresent(Network.self, forKey: .network) ?? d.network
        defaultSort = try c.decodeIfPresent(SortOption.self, forKey: .defaultSort) ?? d.defaultSort
        ivaoApiKey = try c.decodeIfPresent(String.self, forKey: .ivaoApiKey) ?? d.ivaoApiKey
        lastSeenVersion = try c.decodeIfPresent(String.self, forKey: .lastSeenVersion)
    }

    /// On until the user decides: exactly when a SimBrief username / Pilot ID is filled in.
    var autoFetchSimbrief: Bool { autoSimbrief ?? !simbriefId.isEmpty }
}

/// Airport ICAO codes are up to 4 upper-case letters/digits.
func normalizeIcao(_ input: String) -> String {
    String(input.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
}

/// Callsigns are upper case with no spaces.
func normalizeCallsign(_ input: String) -> String {
    input.uppercased().filter { !$0.isWhitespace }
}

func formatInterval(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    if m == 0 { return "\(s) s" }
    if s == 0 { return "\(m) min" }
    return "\(m) min \(s) s"
}
