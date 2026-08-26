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
            Tab("Lüfter", systemImage: "fan") {
                FanSettingsTab(fans: FanService.shared)
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

            Picker("CPU & GPU in der Menüleiste", selection: $engine.menuSystemStyle) {
                ForEach(MenuSystemStyle.allCases) { Text($0.title).tag($0) }
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

/// Lüfter-Tab: Drehzahl-Favoriten und Status des privilegierten Helpers.
private struct FanSettingsTab: View {
    @Bindable var fans: FanService

    var body: some View {
        Form {
            Section("Drehzahl-Favoriten") {
                favoriteRow(label: "Favorit 1", value: $fans.favorite1)
                favoriteRow(label: "Favorit 2", value: $fans.favorite2)
                Text("Die Favoriten erscheinen als Schnellwahl-Knöpfe im Dropdown (Manuell-Modus).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Steuerung") {
                LabeledContent("System-Helfer") {
                    switch fans.helperState {
                    case .ready:
                        Label("Aktiv", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .needsApproval:
                        Button("In Systemeinstellungen erlauben …") { fans.openApprovalSettings() }
                    case .needsRegistration:
                        Button("Aktivieren …") { fans.registerHelper() }
                    case .unavailable(let reason):
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Manuelle Lüftersteuerung braucht einen kleinen Root-Helfer (einmalige Freigabe unter Anmeldeobjekte). Sicherheitsnetz: Ohne Lebenszeichen der App schaltet er nach 3 Minuten selbstständig zurück auf Automatik.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { fans.refreshHelperState() }
    }

    private func favoriteRow(label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...100, step: 5)
                    .frame(width: 160)
                Text("\(Int(value.wrappedValue)) %")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
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
                        Text("Version 1.1.0")
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
