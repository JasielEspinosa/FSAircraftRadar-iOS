import Foundation

/// Looks up airports by ICAO code. The OurAirports list is downloaded once and cached on the phone.
actor AirportStore {
    static let shared = AirportStore()

    private var index: [String: Airport]? = nil
    private let sourceUrl = URL(string: "https://davidmegginson.github.io/ourairports-data/airports.csv")!

    private var cacheFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("airports-v1.tsv")
    }

    /// Returns nil if the code is unknown. Downloads the airport list the first time (about 12 MB).
    func find(_ icao: String) async throws -> Airport? {
        if index == nil { index = try await loadIndex() }
        return index?[icao.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    private func loadIndex() async throws -> [String: Airport] {
        let file = cacheFile
        if !FileManager.default.fileExists(atPath: file.path) { try await download(to: file) }
        let map = Self.readCache(file)
        if map.isEmpty {
            try? FileManager.default.removeItem(at: file)
            throw AppError("Airport data was empty, try again")
        }
        return map
    }

    private func download(to file: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: sourceUrl)
        if let http = response as? HTTPURLResponse, !Http.isOk(http.statusCode) {
            throw AppError("Airport data download failed (HTTP \(http.statusCode))")
        }
        let data = try Data(contentsOf: tmp)
        let airports = try Self.parseOurAirports(data)
        var text = ""
        text.reserveCapacity(airports.count * 40)
        for a in airports {
            let name = a.name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            text += "\(a.icao)\t\(a.latitude)\t\(a.longitude)\t\(name)\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func readCache(_ file: URL) -> [String: Airport] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var map: [String: Airport] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            if p.count < 3 { continue }
            guard let lat = Double(p[1]), let lon = Double(p[2]) else { continue }
            let icao = String(p[0])
            if map[icao] == nil {
                map[icao] = Airport(icao: icao, name: p.count > 3 ? String(p[3]) : "", latitude: lat, longitude: lon)
            }
        }
        return map
    }

    /// Minimal RFC 4180 CSV reader: quoted fields, escaped quotes and newlines inside quotes.
    static func forEachCsvRow(_ data: Data, _ onRow: ([String]) -> Void) {
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var field: [UInt8] = []
        var row: [String] = []
        var inQuotes = false
        while i < n {
            let b = bytes[i]
            i += 1
            if inQuotes {
                if b == 0x22 {
                    if i < n && bytes[i] == 0x22 {
                        field.append(0x22)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(b)
                }
            } else {
                switch b {
                case 0x22:
                    inQuotes = true
                case 0x2C:
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                case 0x0D:
                    break
                case 0x0A:
                    row.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                    onRow(row)
                    row.removeAll(keepingCapacity: true)
                default:
                    field.append(b)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            onRow(row)
        }
    }

    /// Reads airports.csv from ourairports.com. Closed airports are skipped. An airport is listed under
    /// its `ident` and, when different, under its `icao_code` too.
    static func parseOurAirports(_ data: Data) throws -> [Airport] {
        var out: [Airport] = []
        var cols: [String: Int]? = nil
        forEachCsvRow(data) { row in
            guard let header = cols else {
                var map: [String: Int] = [:]
                for (i, name) in row.enumerated() { map[name] = i }
                cols = map
                return
            }
            func get(_ name: String) -> String {
                guard let idx = header[name], idx < row.count else { return "" }
                return row[idx].trimmingCharacters(in: .whitespaces)
            }
            if get("type") == "closed" { return }
            guard let lat = Double(get("latitude_deg")), let lon = Double(get("longitude_deg")) else { return }
            let ident = get("ident").uppercased()
            if ident.isEmpty { return }
            let name = get("name")
            out.append(Airport(icao: ident, name: name, latitude: lat, longitude: lon))
            let icaoCode = get("icao_code").uppercased()
            if !icaoCode.isEmpty && icaoCode != ident {
                out.append(Airport(icao: icaoCode, name: name, latitude: lat, longitude: lon))
            }
        }
        if cols?["ident"] == nil || cols?["latitude_deg"] == nil { throw AppError("Unexpected airport data format") }
        return out
    }
}
