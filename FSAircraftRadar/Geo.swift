import Foundation

enum Geo {
    static let earthRadiusNm = 3440.065

    /// Great-circle distance in nautical miles (haversine).
    static func distanceNm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadiusNm * asin(min(1.0, a.squareRoot()))
    }

    /// Points along the great circle between two positions, `steps` + 1 of them including both ends.
    static func greatCircle(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double, steps: Int = 48) -> [Coord] {
        let start = Coord(lat: lat1, lon: lon1)
        let end = Coord(lat: lat2, lon: lon2)
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let l1 = lon1 * .pi / 180
        let l2 = lon2 * .pi / 180
        let d = distanceNm(lat1, lon1, lat2, lon2) / earthRadiusNm
        let sinD = sin(d)
        if steps < 1 || sinD < 1e-9 { return [start, end] }
        var out: [Coord] = []
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let a = sin((1 - f) * d) / sinD
            let b = sin(f * d) / sinD
            let x = a * cos(phi1) * cos(l1) + b * cos(phi2) * cos(l2)
            let y = a * cos(phi1) * sin(l1) + b * cos(phi2) * sin(l2)
            let z = a * sin(phi1) + b * sin(phi2)
            out.append(Coord(lat: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi, lon: atan2(y, x) * 180 / .pi))
        }
        return out
    }
}

enum Sorting {
    static func withinRange(_ rows: [AircraftRow], _ rangeNm: Int) -> [AircraftRow] {
        rows.filter { row in
            if let d = row.distanceNm { return d <= Double(rangeNm) }
            return true
        }
    }

    /// Controllers with at least one site within range, nearest first (distance of the nearest site).
    static func controllersInRange(_ controllers: [Controller], lat: Double, lon: Double, rangeNm: Int) -> [ControllerRow] {
        var rows: [ControllerRow] = []
        for c in controllers {
            var best = Double.greatestFiniteMagnitude
            for p in c.points {
                best = min(best, Geo.distanceNm(lat, lon, p.lat, p.lon))
            }
            if best <= Double(rangeNm) {
                rows.append(ControllerRow(controller: c, distanceNm: best, displayName: nil))
            }
        }
        rows.sort { a, b in
            let da = a.distanceNm ?? Double.greatestFiniteMagnitude
            let db = b.distanceNm ?? Double.greatestFiniteMagnitude
            if da != db { return da < db }
            return a.controller.callsign < b.controller.callsign
        }
        return rows
    }

    /// Keeps the `limit` nearest rows (by distance), then orders them by `option`.
    static func nearestThenSort(_ rows: [AircraftRow], limit: Int, option: SortOption) -> [AircraftRow] {
        let nearest = Array(sort(rows, .distance).prefix(max(limit, 0)))
        return sort(nearest, option)
    }

    private static func cmp<T: Comparable>(_ x: T, _ y: T) -> Int {
        if x < y { return -1 }
        if y < x { return 1 }
        return 0
    }

    private static func compare(_ a: AircraftRow, _ b: AircraftRow, _ option: SortOption) -> Int {
        switch option {
        case .distance:
            return cmp(a.distanceNm ?? Double.greatestFiniteMagnitude, b.distanceNm ?? Double.greatestFiniteMagnitude)
        case .callsign:
            return cmp(a.aircraft.callsign.uppercased(), b.aircraft.callsign.uppercased())
        case .aircraftType:
            let e = cmp(a.aircraft.aircraftType.isEmpty ? 1 : 0, b.aircraft.aircraftType.isEmpty ? 1 : 0)
            if e != 0 { return e }
            return cmp(a.aircraft.aircraftType.uppercased(), b.aircraft.aircraftType.uppercased())
        case .name:
            let e = cmp(a.nameKnown ? 0 : 1, b.nameKnown ? 0 : 1)
            if e != 0 { return e }
            return cmp(a.displayName.uppercased(), b.displayName.uppercased())
        case .altitude:
            return cmp(b.aircraft.altitudeFt, a.aircraft.altitudeFt)
        case .route:
            let e = cmp(a.aircraft.departure.isEmpty ? 1 : 0, b.aircraft.departure.isEmpty ? 1 : 0)
            if e != 0 { return e }
            let d = cmp(a.aircraft.departure, b.aircraft.departure)
            if d != 0 { return d }
            return cmp(a.aircraft.arrival, b.aircraft.arrival)
        }
    }

    /// Ascending, except Altitude (highest first). Falls back to Callsign when no distances are known.
    static func sort(_ rows: [AircraftRow], _ option: SortOption) -> [AircraftRow] {
        var effective = option
        if option == .distance && rows.allSatisfy({ $0.distanceNm == nil }) { effective = .callsign }
        return rows.sorted { a, b in
            let c = compare(a, b, effective)
            if c != 0 { return c < 0 }
            return a.aircraft.callsign.uppercased() < b.aircraft.callsign.uppercased()
        }
    }
}

struct WebMap {
    let label: String
    let url: String
}

func webMap(_ network: Network) -> WebMap {
    switch network {
    case .vatsim: return WebMap(label: "VATSIM Map", url: "https://map.vatsim.net/")
    case .ivao: return WebMap(label: "IVAO Webeye", url: "https://webeye.ivao.aero/")
    }
}

struct ListenInfo {
    let url: String?
    let frequencyText: String?
    let message: String
}

func listenInfo(_ network: Network, callsign: String, frequency: Double?) -> ListenInfo {
    let freq = frequency.map { String(format: "%.3f", $0) }
    switch network {
    case .vatsim:
        let f = freq.map { " (\($0) MHz)" } ?? ""
        return ListenInfo(
            url: "https://listen.vatsim.net", frequencyText: freq,
            message: "VATSIM Listen opens in your browser (VATSIM login needed). Pick \(callsign)\(f) there."
        )
    case .ivao:
        let f = freq.map { "\($0) MHz" } ?? "its frequency"
        return ListenInfo(
            url: nil, frequencyText: freq,
            message: "IVAO has no web listener. Tune \(callsign) on \(f) in Altitude or Aurora (receive-only is enough)."
        )
    }
}
