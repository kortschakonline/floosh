import SwiftUI

/// Inhalt des Menüleisten-Fensters: drei Gruppen-Karten in Liquid Glass.
struct DropdownView: View {
    @Bindable var engine: StatsEngine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                header

                ForEach(SpeedGroup.allCases) { group in
                    GroupCard(engine: engine, group: group)
                }

                footer
            }
            .padding(14)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            FlooshWordmark(height: 24)
            Spacer()
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .help("Einstellungen …")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .help("floosh beenden")
        }
        .padding(.horizontal, 2)
    }

    /// Dezente Credit-Zeile: die JRN.digital-Wortmarke, klickbar zur Website.
    private var footer: some View {
        Link(destination: URL(string: "https://jrn.digital")!) {
            JRNLogo(height: 9)
                .opacity(0.45)
        }
        .buttonStyle(.plain)
        .help("Entwickelt von JRN.digital")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 2)
        .padding(.top, -4)
    }
}
