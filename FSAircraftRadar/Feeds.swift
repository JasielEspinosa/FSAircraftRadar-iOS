import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String {
        if let s = self[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }

    func dbl(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        guard let d = dbl(key), d.isFinite, abs(d) < 1e15 else { return fallback }
        return Int(d)
    }

    func obj(_ key: String) -> JSON? { self[key] as? JSON }

    func arr(_ key: String) -> [JSON] {
        guard let list = self[key] as? [Any] else { return [] }
        return list.compactMap { $0 as? JSON }
    }
}

enum Http {
    static func get(_ urlString: String, headers: [String: String] = [:]) async throws -> (code: Int, data: Data) {
        guard let url = URL(string: urlString) else { throw AppError("Bad address: \(urlString)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("FSAircraftRadar/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    static func isOk(_ code: Int) -> Bool { code >= 200 && code < 300 }
}

private func cleanName(_ raw: String) -> String? {
    // Some users have their CID (digits only) as their name.
    if raw.isEmpty || raw.allSatisfy({ $0.isNumber }) { return nil }
    return raw
}

// MARK: - VATSIM

enum VatsimFeed {
    private static let url = "https://data.vatsim.net/v3/vatsim-data.json"
    private static let transceiversUrl = "https://data.vatsim.net/v3/transceivers-data.json"

    static func fetch() async throws -> TrafficSnapshot {
        let r = try await Http.get(url)
        guard Http.isOk(r.code) else { throw AppError("VATSIM returned HTTP \(r.code)") }
        guard let root = try JSONSerialization.jsonObject(with: r.data) as? JSON else {
            throw AppError("VATSIM returned unreadable data")
        }
        let aircraft = parse(root)
        // Controller positions are only in a second feed; without it there are just no controllers.
        var controllers: [Controller] = []
        if let t = try? await Http.get(transceiversUrl), Http.isOk(t.code),
           let list = (try? JSONSerialization.jsonObject(with: t.data)) as? [Any] {
            controllers = parseControllers(root, positions: parseTransceivers(list))
        }
        return TrafficSnapshot(aircraft: aircraft, controllers: controllers)
    }

    static func parseTransceivers(_ list: [Any]) -> [String: [Coord]] {
        var out: [String: [Coord]] = [:]
        for item in list {
            guard let entry = item as? JSON else { continue }
            let callsign = entry.str("callsign")
            var points: [Coord] = []
            for t in entry.arr("transceivers") {
                if let lat = t.dbl("latDeg"), let lon = t.dbl("lonDeg") { points.append(Coord(lat: lat, lon: lon)) }
            }
            if !callsign.isEmpty && !points.isEmpty { out[callsign] = points }
        }
        return out
    }

    static func parseControllers(_ root: JSON, positions: [String: [Coord]]) -> [Controller] {
        var out: [Controller] = []
        for c in root.arr("controllers") {
            let position: String
            switch c.int("facility") {
            case 1: position = "FSS"
            case 2: position = "DEL"
            case 3: position = "GND"
            case 4: position = "TWR"
            case 5: position = "APP"
            case 6: position = "CTR"
            default: continue
            }
            let callsign = c.str("callsign")
            guard let points = positions[callsign] else { continue }
            // 199.998 is VATSIM's "no frequency" placeholder.
            var frequency: Double? = Double(c.str("frequency"))
            if let f = frequency, !(f > 0 && f < 199.99) { frequency = nil }
            out.append(Controller(
                callsign: callsign, position: position, frequency: frequency,
                userId: c.int("cid"), points: points, name: cleanName(c.str("name"))
            ))
        }
        return out
    }

    static func parse(_ root: JSON) -> [Aircraft] {
        var out: [Aircraft] = []
        for p in root.arr("pilots") {
            guard let lat = p.dbl("latitude"), let lon = p.dbl("longitude") else { continue }
            let callsign = p.str("callsign")
            if callsign.isEmpty { continue }
            let cid = p.int("cid")
            let plan = p.obj("flight_plan")
            var type = plan?.str("aircraft_short") ?? ""
            if type.isEmpty {
                let full = plan?.str("aircraft") ?? ""
                type = String(full.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            }
            out.append(Aircraft(
                callsign: callsign, aircraftType: type, name: cleanName(p.str("name")),
                userId: cid, idLabel: "CID \(cid)", latitude: lat, longitude: lon,
                altitudeFt: p.int("altitude"), departure: plan?.str("departure") ?? "",
                arrival: plan?.str("arrival") ?? "", sessionId: 0, headingDeg: p.int("heading")
            ))
        }
        return out
    }
}

// MARK: - IVAO

struct IvaoAuthError: Error {}

enum IvaoFeed {
    private static let whazzup = "https://api.ivao.aero/v2/tracker/whazzup"
    private static let userUrl = "https://api.ivao.aero/v2/users/"
    private static let sessionUrl = "https://api.ivao.aero/v2/tracker/sessions/"

    static func fetch() async throws -> TrafficSnapshot {
        let r = try await Http.get(whazzup)
        guard Http.isOk(r.code) else { throw AppError("IVAO returned HTTP \(r.code)") }
        guard let root = try JSONSerialization.jsonObject(with: r.data) as? JSON else {
            throw AppError("IVAO returned unreadable data")
        }
        let clients = root.obj("clients") ?? [:]
        return TrafficSnapshot(aircraft: parsePilots(clients), controllers: parseControllers(clients))
    }

    static func parseControllers(_ clients: JSON) -> [Controller] {
        var out: [Controller] = []
        for a in clients.arr("atcs") {
            let callsign = a.str("callsign")
            if callsign.isEmpty { continue }
            guard let track = a.obj("lastTrack"), let lat = track.dbl("latitude"), let lon = track.dbl("longitude") else { continue }
            let session = a.obj("atcSession")
            var position = session?.str("position") ?? ""
            if position.isEmpty { position = String(callsign.split(separator: "_").last ?? "") }
            var frequency = session?.dbl("frequency")
            if let f = frequency, f <= 0 { frequency = nil }
            out.append(Controller(
                callsign: callsign, position: position.uppercased(), frequency: frequency,
                userId: a.int("userId"), points: [Coord(lat: lat, lon: lon)], name: nil,
                sessionId: a.int("id")
            ))
        }
        return out
    }

    static func parsePilots(_ clients: JSON) -> [Aircraft] {
        var out: [Aircraft] = []
        for p in clients.arr("pilots") {
            guard let track = p.obj("lastTrack"), let lat = track.dbl("latitude"), let lon = track.dbl("longitude") else { continue }
            let callsign = p.str("callsign")
            if callsign.isEmpty { continue }
            let vid = p.int("userId")
            let plan = p.obj("flightPlan")
            var type = plan?.obj("aircraft")?.str("icaoCode") ?? ""
            if type.isEmpty { type = plan?.str("aircraftId") ?? "" }
            out.append(Aircraft(
                callsign: callsign, aircraftType: type, name: nil, userId: vid, idLabel: "VID \(vid)",
                latitude: lat, longitude: lon, altitudeFt: track.int("altitude"),
                departure: plan?.str("departureId") ?? "", arrival: plan?.str("arrivalId") ?? "",
                sessionId: p.int("id"), headingDeg: track.int("heading")
            ))
        }
        return out
    }

    /// Best-effort name lookup, needs an API key: the tracker session holds the real name if shared,
    /// the public profile holds a nickname. Throws IvaoAuthError if the key is rejected.
    static func fetchName(userId: Int, sessionId: Int, apiKey: String) async throws -> String? {
        let headers = ["apiKey": apiKey]
        var realName: String? = nil
        if sessionId != 0 {
            let s = try await Http.get(sessionUrl + String(sessionId), headers: headers)
            if s.code == 401 || s.code == 403 { throw IvaoAuthError() }
            if Http.isOk(s.code), let root = (try? JSONSerialization.jsonObject(with: s.data)) as? JSON {
                realName = fullName(root.obj("user"))
            }
        }
        let u = try await Http.get(userUrl + String(userId), headers: headers)
        if u.code == 401 || u.code == 403 { throw IvaoAuthError() }
        var nickname: String? = nil
        if Http.isOk(u.code), let root = (try? JSONSerialization.jsonObject(with: u.data)) as? JSON {
            if realName == nil { realName = fullName(root) }
            let nick = root.str("publicNickname")
            if !nick.isEmpty && nick.range(of: "^User \\d+$", options: .regularExpression) == nil { nickname = nick }
        }
        return combineNames(realName, nickname)
    }

    private static func fullName(_ obj: JSON?) -> String? {
        guard let obj = obj else { return nil }
        let full = "\(obj.str("firstName")) \(obj.str("lastName"))".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? nil : full
    }

    /// "Real Name · nickname" when both are known and different; otherwise whichever one exists.
    static func combineNames(_ realName: String?, _ nickname: String?) -> String? {
        guard let realName = realName else { return nickname }
        guard let nickname = nickname else { return realName }
        let real = realName.lowercased()
        let nick = nickname.lowercased()
        if real == nick || real.contains(nick) { return realName }
        if nick.contains(real) { return nickname }
        return "\(realName) · \(nickname)"
    }
}

// MARK: - SimBrief

enum SimBrief {
    static func fetchCallsign(_ userIdOrName: String) async throws -> String {
        let key = userIdOrName.allSatisfy({ $0.isNumber }) ? "userid" : "username"
        var comps = URLComponents(string: "https://www.simbrief.com/api/xml.fetcher.php")!
        comps.queryItems = [URLQueryItem(name: key, value: userIdOrName), URLQueryItem(name: "json", value: "v2")]
        guard let url = comps.url else { throw AppError("Bad SimBrief address") }
        let r = try await Http.get(url.absoluteString)
        if r.data.isEmpty { throw AppError("SimBrief returned HTTP \(r.code) with no data") }
        // Unknown users get HTTP 400 with a JSON body describing the error, so parse before checking the code.
        return try parseCallsign(r.data)
    }

    static func parseCallsign(_ data: Data) throws -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw AppError("SimBrief returned an unreadable response")
        }
        let status = root.obj("fetch")?.str("status") ?? ""
        if !status.isEmpty && status.lowercased() != "success" {
            let text = status.hasPrefix("Error: ") ? String(status.dropFirst(7)) : status
            throw AppError("SimBrief: \(text)")
        }
        let atc = root.obj("atc")?.str("callsign") ?? ""
        if !atc.isEmpty { return atc.uppercased() }
        let general = root.obj("general")
        let built = (general?.str("icao_airline") ?? "") + (general?.str("flight_number") ?? "")
        if !built.isEmpty { return built.uppercased() }
        throw AppError("SimBrief has no callsign in your latest flight plan")
    }
}
