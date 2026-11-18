import SwiftUI
import MapKit

private struct RouteLine: Identifiable {
    let id: String
    let coords: [CLLocationCoordinate2D]
    let dashed: Bool
}

private func clCoord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

/// Apple Maps view of the nearby aircraft, centred on your aircraft (or the airport) and zoomed to the range.
struct MapScreen: View {
    @EnvironmentObject var model: AppModel
    let center: Coord
    let showAtc: Bool
    @Binding var selectedID: String?

    @State private var camera: MapCameraPosition = .automatic

    private var selectedRow: AircraftRow? {
        guard let id = selectedID else { return nil }
        return model.rows.first { $0.id == id }
    }

    private var selectedController: ControllerRow? {
        guard showAtc, let id = selectedID else { return nil }
        return model.controllerRows.first { $0.id == id }
    }

    private var centerLabel: String {
        if model.settings.referenceMode == .airport { return model.airport?.icao ?? model.settings.airportIcao }
        return model.settings.callsign
    }

    private var frameKey: String {
        "\(model.settings.referenceMode.rawValue)|\(model.settings.callsign)|\(model.settings.airportIcao)|\(model.settings.maxRangeNm)"
    }

    private var routeLines: [RouteLine] {
        guard let row = selectedRow else { return [] }
        let ac = row.aircraft
        var out: [RouteLine] = []
        if let dep = model.routeAirports[ac.departure.trimmingCharacters(in: .whitespaces).uppercased()] {
            let pts = Geo.greatCircle(dep.lat, dep.lon, ac.latitude, ac.longitude).map { clCoord($0.lat, $0.lon) }
            out.append(RouteLine(id: "dep", coords: pts, dashed: false))
        }
        if let arr = model.routeAirports[ac.arrival.trimmingCharacters(in: .whitespaces).uppercased()] {
            let pts = Geo.greatCircle(ac.latitude, ac.longitude, arr.lat, arr.lon).map { clCoord($0.lat, $0.lon) }
            out.append(RouteLine(id: "arr", coords: pts, dashed: true))
        }
        return out
    }

    var body: some View {
        Map(position: $camera) {
            MapCircle(center: clCoord(center.lat, center.lon), radius: Double(model.settings.maxRangeNm) * 1852)
                .foregroundStyle(Color.blue.opacity(0.08))
                .stroke(Color.blue.opacity(0.8), lineWidth: 2)

            ForEach(routeLines) { line in
                MapPolyline(coordinates: line.coords)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: line.dashed ? [8, 6] : []))
            }

            ForEach(showAtc ? model.controllerRows : []) { row in
                let c = row.controller.centre
                let isSelected = row.id == selectedID
                Annotation(row.controller.callsign, coordinate: clCoord(c.lat, c.lon)) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: isSelected ? 22 : 17))
                        .foregroundStyle(isSelected ? Color.orange : Color.teal)
                        .shadow(color: .white, radius: 1)
                        .onTapGesture { selectedID = row.id }
                }
            }

            ForEach(model.rows) { row in
                let isSelected = row.id == selectedID
                Annotation(row.aircraft.callsign, coordinate: clCoord(row.aircraft.latitude, row.aircraft.longitude)) {
                    Image(systemName: "airplane")
                        .font(.system(size: isSelected ? 26 : 21, weight: .bold))
                        .foregroundStyle(isSelected ? Color.orange : Color.blue)
                        .rotationEffect(.degrees(Double(row.aircraft.headingDeg) - 90))
                        .shadow(color: .white, radius: 1)
                        .onTapGesture { selectedID = row.id }
                }
            }

            // Your own aircraft (a larger red plane) or the chosen airport (a red dot), on top.
            Annotation(centerLabel, coordinate: clCoord(center.lat, center.lon)) {
                if let own = model.referenceAircraft {
                    Image(systemName: "airplane")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.red)
                        .rotationEffect(.degrees(Double(own.headingDeg) - 90))
                        .shadow(color: .white, radius: 1.5)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
            }
        }
        .overlay(alignment: .bottom) { detailCard }
        .onAppear { reframe() }
        .onChange(of: frameKey) { reframe() }
        .onChange(of: selectedID) {
            if let row = selectedRow { model.loadRoute(for: row.aircraft) }
        }
    }

    @ViewBuilder
    private var detailCard: some View {
        if let row = selectedRow {
            VStack(spacing: 6) {
                AircraftCard(row: row)
                Button("Use as Callsign and center map") {
                    model.useAsCallsign(row.aircraft.callsign)
                    selectedID = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)
        } else if let c = selectedController {
            ControllerCard(row: c, network: model.settings.network)
                .padding(8)
        }
    }

    private func reframe() {
        let meters = Double(model.settings.maxRangeNm) * 1852 * 2.3
        camera = .region(MKCoordinateRegion(
            center: clCoord(center.lat, center.lon), latitudinalMeters: meters, longitudinalMeters: meters
        ))
    }
}
