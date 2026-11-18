import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private var refreshBinding: Binding<Double> {
        Binding(get: { Double(model.settings.autoRefreshSec) }, set: { model.settings.autoRefreshSec = Int($0.rounded()) })
    }

    private var countBinding: Binding<Double> {
        Binding(get: { Double(model.settings.maxAircraft) }, set: { model.settings.maxAircraft = Int($0.rounded()) })
    }

    private var rangeBinding: Binding<Double> {
        Binding(get: { Double(model.settings.maxRangeNm) }, set: { model.settings.maxRangeNm = Int($0.rounded()) })
    }

    var body: some View {
        Form {
            Section("SimBrief") {
                TextField("SimBrief username or Pilot ID", text: $model.settings.simbriefId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Used by the SimBrief button on the main page and by auto-fetch. Digits only = Pilot ID.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Auto-fetch SimBrief callsign",
                    isOn: Binding(get: { model.settings.autoFetchSimbrief }, set: { model.settings.autoSimbrief = $0 })
                )
                Text("Re-reads your callsign from SimBrief when the app starts and every time you switch to the Callsign tab. On by default once a SimBrief username is filled in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Auto refresh") {
                Toggle("Auto refresh", isOn: $model.settings.autoRefresh)
                Text("Reloads the traffic by itself while the app is on screen, and straight away each time the app comes back to the foreground. Also the switch on the main page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Refresh every: \(formatInterval(model.settings.autoRefreshSec)) (\(formatInterval(minRefreshSec))–\(formatInterval(maxRefreshSec)))")
                    Slider(
                        value: refreshBinding,
                        in: Double(minRefreshSec)...Double(maxRefreshSec),
                        step: Double(refreshStepSec)
                    )
                    .disabled(!model.settings.autoRefresh)
                }
            }

            Section("List") {
                VStack(alignment: .leading) {
                    Text("Nearest aircraft to show: \(model.settings.maxAircraft) (max \(maxAircraftLimit))")
                    Slider(value: countBinding, in: 1...Double(maxAircraftLimit), step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Maximum range: \(model.settings.maxRangeNm) NM (\(rangeMinNm)–\(rangeMaxNm))")
                    Slider(value: rangeBinding, in: Double(rangeMinNm)...Double(rangeMaxNm), step: Double(rangeStepNm))
                }
                Picker(
                    "Default sorting",
                    selection: Binding(
                        get: { model.settings.defaultSort },
                        set: {
                            model.settings.defaultSort = $0
                            model.sort = $0
                        }
                    )
                ) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.label + (option == .altitude ? " (highest first)" : "")).tag(option)
                    }
                }
            }

            Section("Theme") {
                Picker("Theme", selection: $model.settings.themeMode) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("IVAO (optional)") {
                SecureField("IVAO API key", text: $model.settings.ivaoApiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("IVAO's public feed has no pilot names. With a key, a pilot's or controller's real name is shown if they allow sharing it, together with their public nickname if they set one; otherwise the VID is shown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("FS Aircraft Radar").font(.body)
                Text("Version \(model.currentVersion)")
                Text("Created by 97Espi")
                Button("Version changes") { model.showFullChangelog() }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
