import SwiftUI
import ServiceManagement

/// Eigenständiges Einstellungs-Fenster (⌘,) mit Tabs — hier ist Platz für mehr.
struct SettingsWindow: View {
    @Bindable var engine: StatsEngine

    var body: some View {
        TabView {
            Tab("Anzeige", systemImage: "paintbrush") {
                displayTab
            }
            Tab("Messung", systemImage: "gauge.with.dots.needle.67percent") {
                measurementTab
            }
            Tab("Allgemein", systemImage: "gearshape") {
                generalTab
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Anzeige

    private var displayTab: some View {
        Form {
            Picker("Stil in der Menüleiste", selection: $engine.labelStyle) {
                ForEach(MenuLabelStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Symbol", selection: $engine.iconStyle) {
                ForEach(MenuIconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Einheit", selection: $engine.units) {
                ForEach(SpeedUnits.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section("Dropdown") {
                Toggle("Spitzenwerte anzeigen", isOn: $engine.showPeaks)
                Toggle("Einzelne Geräte anzeigen", isOn: $engine.showDevices)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Messung

    private var measurementTab: some View {
        Form {
            Picker("Intervall", selection: $engine.interval) {
                Text("0,5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
            }
            .pickerStyle(.segmented)

            Picker("Diagramm-Zeitfenster", selection: $engine.chartWindow) {
                Text("30 s").tag(30.0)
                Text("60 s").tag(60.0)
                Text("120 s").tag(120.0)
            }
            .pickerStyle(.segmented)

            Section("Quellen") {
                Toggle("Disk-Images mitzählen", isOn: $engine.includeVirtualDisks)
                Toggle("VPN & virtuelle Interfaces mitzählen", isOn: $engine.includeVirtualNets)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Allgemein

    private var generalTab: some View {
        GeneralSettingsTab()
    }
}

private struct GeneralSettingsTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FlooshWordmark(height: 30)
                        Text("Version 1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://jrn.digital")!) {
                        JRNLogo(height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("jrn.digital öffnen")
                }
                .padding(.vertical, 4)
            }

            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section {
                LabeledContent("Entwickelt von") {
                    Link("jrn.digital", destination: URL(string: "https://jrn.digital")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func updateLoginItem(enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Login-Start nicht möglich: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
