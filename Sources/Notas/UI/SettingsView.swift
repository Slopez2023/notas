import SwiftUI

/// The Settings window (⌘,): appearance and updates.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { app.appearance }, set: { app.appearance = $0 })) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Updates") {
                LabeledContent("Notas", value: updater.versionDescription)
                if let version = updater.availableVersion {
                    LabeledContent("Available", value: "Version \(version)")
                }
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                HStack {
                    if let lastChecked = updater.lastChecked {
                        Text("Last checked \(lastChecked, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button(updater.availableVersion.map { "Install Notas \($0)…" } ?? updater.activityTitle) {
                        updater.checkForUpdates()
                    }
                    .disabled(updater.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
