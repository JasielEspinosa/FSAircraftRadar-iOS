import SwiftUI

struct ChangelogView: View {
    let entries: [ChangelogEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    Section("v\(entry.version)  ·  \(entry.date)") {
                        ForEach(entry.changes, id: \.self) { change in
                            Text(change).font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Version changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
