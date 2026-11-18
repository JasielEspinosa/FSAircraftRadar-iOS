import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var atcTab = false
    @State private var showAtcOnMap = true
    @State private var controlsOpen = false
    @State private var selectedID: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.viewMode == .map {
                    VStack(spacing: 8) {
                        header
                        mapArea
                    }
                    .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            header
                            listArea
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("FS Aircraft Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { model.showFullChangelog() } label: { Image(systemName: "info.circle") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .overlay(alignment: .bottom) {
                if let m = model.message {
                    Text(m)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await model.keepFresh() }
        }
        .task(id: model.message) {
            if model.message != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.message = nil
            }
        }
        .sheet(isPresented: $model.showChangelog) {
            ChangelogView(entries: model.changelogEntries)
        }
    }

    // MARK: Header (controls + status)

    private var header: some View {
        VStack(spacing: 8) {
            if model.settings.viewMode == .map {
                DisclosureGroup("Controls", isExpanded: $controlsOpen) { controls.padding(.top, 6) }
            } else {
                controls
            }

            Picker("View", selection: $model.settings.viewMode) {
                ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            statusLines
        }
    }

    private var callsignBinding: Binding<String> {
        Binding(get: { model.settings.callsign }, set: { model.settings.callsign = normalizeCallsign($0) })
    }

    private var icaoBinding: Binding<String> {
        Binding(get: { model.settings.airportIcao }, set: { model.settings.airportIcao = normalizeIcao($0) })
    }

    private var countBinding: Binding<Double> {
        Binding(get: { Double(model.settings.maxAircraft) }, set: { model.settings.maxAircraft = Int($0.rounded()) })
    }

    private var rangeBinding: Binding<Double> {
        Binding(get: { Double(model.settings.maxRangeNm) }, set: { model.settings.maxRangeNm = Int($0.rounded()) })
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Network", selection: Binding(get: { model.settings.network }, set: { model.setNetwork($0) })) {
                ForEach(Network.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: Binding(get: { model.settings.referenceMode }, set: { model.setReferenceMode($0) })) {
                ForEach(ReferenceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.settings.referenceMode == .callsign {
                HStack {
                    TextField("Callsign", text: callsignBinding)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            model.refresh()
                        }
                    Button {
                        dismissKeyboard()
                        model.fetchCallsignFromSimbrief()
                    } label: {
                        if model.simbriefBusy { ProgressView() } else { Text("SimBrief") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.simbriefBusy)
                }
            } else {
                TextField("Airport ICAO code (e.g. EGLL)", text: icaoBinding)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        dismissKeyboard()
                        model.refresh()
                    }
            }

            HStack {
                Image(systemName: "airplane").frame(width: 22)
                Slider(value: countBinding, in: 1...Double(maxAircraftLimit), step: 1)
                Text("\(model.settings.maxAircraft)").frame(width: 56, alignment: .trailing).monospacedDigit()
            }
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").frame(width: 22)
                Slider(value: rangeBinding, in: Double(rangeMinNm)...Double(rangeMaxNm), step: Double(rangeStepNm))
                Text("\(model.settings.maxRangeNm) NM").frame(width: 56, alignment: .trailing).monospacedDigit()
            }

            Toggle("Auto refresh (every \(formatInterval(model.settings.autoRefreshSec)))", isOn: $model.settings.autoRefresh)
                .font(.subheadline)

            HStack {
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort: \(model.sort.label)", systemImage: "arrow.up.arrow.down")
                }
                Spacer()
                Button {
                    dismissKeyboard()
                    model.refresh()
                } label: {
                    if model.loading { ProgressView() } else { Text(model.hasLoaded ? "Refresh" : "Scan") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.loading || !model.canLoad)
            }
        }
    }

    // MARK: Status

    private var statusText: String {
        var parts: [String] = []
        if model.referenceSource != .none { parts.append("\(model.rows.count) aircraft") }
        if let t = model.lastUpdated { parts.append("updated " + t.formatted(date: .omitted, time: .shortened)) }
        switch model.referenceSource {
        case .ownAircraft: parts.append("Distances from your aircraft (\(model.settings.callsign))")
        case .airport: parts.append("Distances from \(model.airport?.icao ?? model.settings.airportIcao)")
        case .none: break
        }
        return parts.joined(separator: " • ")
    }

    private var hintText: String? {
        if !model.canLoad {
            return model.settings.referenceMode == .callsign
                ? "Enter your callsign (or tap SimBrief), then tap Done or Scan."
                : "Enter a 4-letter airport code, then tap Done or Scan."
        }
        if model.hasLoaded && model.referenceSource == .none {
            return model.settings.referenceMode == .callsign
                ? "\(model.settings.callsign) is not online on \(model.settings.network.label), so no aircraft are shown."
                : "Airport not found."
        }
        if model.hasLoaded && model.rows.isEmpty {
            return "No aircraft within \(model.settings.maxRangeNm) NM."
        }
        return nil
    }

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !statusText.isEmpty {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            if let e = model.error {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            if let h = hintText, model.error == nil {
                Text(h).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    private var listArea: some View {
        let web = webMap(model.settings.network)
        return VStack(spacing: 8) {
            if model.referenceSource != .none {
                HStack {
                    Picker("Show", selection: $atcTab) {
                        Text("Aircraft (\(model.rows.count))").tag(false)
                        Text("ATC (\(model.controllerRows.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button(web.label) {
                        if let url = URL(string: web.url) { openURL(url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if atcTab {
                    ForEach(model.controllerRows) { row in
                        ControllerCard(row: row, network: model.settings.network)
                    }
                    if model.controllerRows.isEmpty {
                        Text("No ATC within \(model.settings.maxRangeNm) NM.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.rows) { row in AircraftCard(row: row) }
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: Map

    private var mapArea: some View {
        let web = webMap(model.settings.network)
        return VStack(spacing: 6) {
            if let center = model.referencePoint {
                HStack {
                    Toggle("ATC", isOn: $showAtcOnMap)
                        .toggleStyle(.button)
                        .controlSize(.small)
                    Button(web.label) {
                        if let url = URL(string: web.url) { openURL(url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                MapScreen(center: center, showAtc: showAtcOnMap, selectedID: $selectedID)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 8)
            } else {
                Spacer()
            }
        }
    }
}
