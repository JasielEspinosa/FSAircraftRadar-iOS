import SwiftUI
import UIKit

struct AircraftCard: View {
    let row: AircraftRow

    var body: some View {
        let ac = row.aircraft
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ac.callsign).font(.headline)
                if !ac.aircraftType.isEmpty {
                    Text(ac.aircraftType).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let d = row.distanceNm {
                    Text(String(format: "%.1f NM", d)).font(.subheadline.weight(.semibold))
                }
            }
            Text(row.displayName).font(.subheadline)
            Text("\(ac.altitudeFt.formatted()) ft  ·  \(ac.route)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ControllerCard: View {
    let row: ControllerRow
    let network: Network
    @State private var showListen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let c = row.controller
        let info = listenInfo(network, callsign: c.callsign, frequency: c.frequency)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(c.callsign).font(.headline)
                Text(c.positionLabel).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let d = row.distanceNm {
                    Text(String(format: "%.1f NM", d)).font(.subheadline.weight(.semibold))
                }
            }
            HStack {
                if let f = c.frequency {
                    Text(String(format: "%.3f MHz", f)).font(.subheadline)
                } else {
                    Text("No frequency").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Listen") { showListen = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let name = row.displayName {
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Listen to \(c.callsign)", isPresented: $showListen, titleVisibility: .visible) {
            if let u = info.url, let url = URL(string: u) {
                Button("Open VATSIM Listen") { openURL(url) }
            }
            if let f = info.frequencyText {
                Button("Copy frequency") { UIPasteboard.general.string = f }
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(info.message)
        }
    }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
