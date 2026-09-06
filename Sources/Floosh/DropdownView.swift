import SwiftUI

/// Inhalt des Menüleisten-Fensters: System-Karte und drei Gruppen-Karten in
/// Liquid Glass — als Liste oder als 2×2-Raster.
struct DropdownView: View {
    @Bindable var engine: StatsEngine
    var fans: FanService = .shared
    var updates: UpdateChecker = .shared
    var panel: PanelSettings = .shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let size = engine.cardSize
        let grid = engine.layout == .grid
        CompatGlassContainer(spacing: size.outerSpacing) {
            VStack(spacing: size.outerSpacing) {
                header

                if let release = updates.available {
                    updateBanner(release)
                }

                if grid {
                    gridRow {
                        SystemCard(engine: engine, fans: fans)
                    } trailing: {
                        GroupCard(engine: engine, group: .internalDrives)
                    }
                    gridRow {
                        GroupCard(engine: engine, group: .externalDrives)
                    } trailing: {
                        GroupCard(engine: engine, group: .network)
                    }
                } else {
                    SystemCard(engine: engine, fans: fans)
                    ForEach(SpeedGroup.allCases) { group in
                        GroupCard(engine: engine, group: group)
                    }
                }

                footer
            }
            .padding(size.outerPadding)
        }
        .frame(width: engine.dropdownWidth)
    }

    /// Zwei Karten nebeneinander mit gleicher Höhe: `fixedSize` gibt der
    /// Zeile ihre Idealhöhe (die höhere Karte), die Karten füllen sie auf.
    private func gridRow<A: View, B: View>(@ViewBuilder leading: () -> A,
                                           @ViewBuilder trailing: () -> B) -> some View {
        HStack(alignment: .top, spacing: engine.cardSize.outerSpacing) {
            leading()
            trailing()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            FlooshWordmark(height: 24)
            Spacer()
            Button {
                panel.enabled.toggle()
            } label: {
                Image(systemName: panel.enabled ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .featureGated(.desktopPanel)
            .help(panel.enabled ? "Desktop-Panel ausblenden" : "Desktop-Panel anzeigen")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help("Einstellungen …")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help("floosh beenden")
        }
        .padding(.horizontal, 2)
    }

    /// Schmale Zeile, sobald auf GitHub eine neuere Version liegt.
    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("floosh \(release.version) ist verfügbar")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            Button("Laden") { updates.openDownload(release) }
                .compatGlassButton()
                .controlSize(.small)
                .help("DMG von GitHub laden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .cardGlass(tint: Color.accentColor.opacity(0.12), cornerRadius: 14)
    }

    /// Dezente Credit-Zeile: die JRN.digital-Wortmarke, klickbar zur Website.
    private var footer: some View {
        Link(destination: URL(string: "https://jrn.digital")!) {
            JRNLogo(height: 9)
                .opacity(0.75)
        }
        .buttonStyle(.plain)
        .help("Entwickelt von JRN.digital")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 2)
        .padding(.top, -4)
    }
}
