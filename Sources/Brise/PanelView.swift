import SwiftUI

enum Page: String, Identifiable {
    case temperatures, fans, system, battery, controls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperatures: "Températures"
        case .fans: "Ventilateurs"
        case .system: "Système"
        case .battery: "Batterie"
        case .controls: "Contrôles"
        }
    }
}

/// Root of the menu bar window: a home screen of tiles, each opening a detail page.
struct PanelView: View {
    @Environment(Monitor.self) private var monitor
    @State var page: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let page {
                DetailHeader(title: page.title) { withAnimation(.snappy) { self.page = nil } }
                Group {
                    switch page {
                    case .temperatures: TemperatureCard(expanded: true)
                    case .fans: FansCard(); AutomationsCard()
                    case .system: SystemCard(); ProcessesCard()
                    case .battery: BatteryCard()
                    case .controls: ControlsCard()
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HomeView(open: { p in withAnimation(.snappy) { page = p } })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            StatusLine()
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Home

private struct HomeView: View {
    @Environment(Monitor.self) private var monitor
    let open: (Page) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            CommandBarView(compact: true)
            LazyVGrid(columns: columns, spacing: 10) {
                Tile(icon: "thermometer.medium", title: "Températures",
                     value: monitor.cpuTemp.map { "\(Int($0.rounded()))°" } ?? "—",
                     detail: monitor.gpuTemp.map { "GPU \(Int($0.rounded()))°" } ?? "CPU",
                     tint: tempColor(monitor.cpuTemp)) { open(.temperatures) }

                Tile(icon: monitor.fansForced ? "fan.fill" : "fan", title: "Ventilateurs",
                     value: monitor.fans.first.map { "\(Int($0.current))" } ?? "—",
                     detail: fanDetail, tint: monitor.fansForced ? .orange : .blue,
                     active: monitor.fansForced) { open(.fans) }

                Tile(icon: "power", title: "Capot fermé",
                     value: monitor.lidClosedAwake ? "Allumé" : "Veille",
                     detail: monitor.lidClosedAwake ? "Le Mac continue de tourner" : "Comportement normal",
                     tint: .green, active: monitor.lidClosedAwake, isToggle: true) {
                    if monitor.helperInstalled { monitor.setLidClosedAwake(!monitor.lidClosedAwake) }
                    else { monitor.installHelper(); if monitor.helperInstalled { monitor.setLidClosedAwake(true) } }
                }
                .help("Empêche la mise en veille même capot fermé : un agent IA, un rendu ou un téléchargement continue.")

                Tile(icon: monitor.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer", title: "Éveillé",
                     value: monitor.keepAwake ? "Actif" : "Off",
                     detail: awakeDetail, tint: .brown, active: monitor.keepAwake, isToggle: true) {
                    monitor.setKeepAwake(!monitor.keepAwake)
                }
                .contextMenu {
                    ForEach([30, 60, 120, 240], id: \.self) { m in
                        Button("Pendant \(CommandCatalog.duration(m))") { monitor.setKeepAwake(true, minutes: m) }
                    }
                    Button("Jusqu'à ce que je l'arrête") { monitor.setKeepAwake(true) }
                }

                Tile(icon: batteryIcon, title: "Batterie",
                     value: monitor.battery.map { "\($0.percent) %" } ?? "—",
                     detail: batteryDetail, tint: .green) { open(.battery) }

                Tile(icon: "slider.horizontal.3", title: "Contrôles",
                     value: "\(Int(monitor.volume)) %", detail: "Volume · écran · disques",
                     tint: .purple) { open(.controls) }

                Tile(icon: "cpu", title: "Système",
                     value: monitor.cpuLoad.map { "\(Int($0 * 100)) %" } ?? "—",
                     detail: monitor.memory.map { "RAM \(Format.bytes(Double($0.used)))" } ?? "",
                     tint: .indigo) { open(.system) }

                Tile(icon: "command", title: "Commande",
                     value: CommandPanel.shared.shortcutLabel, detail: "Barre de commande partout",
                     tint: .gray) { CommandPanel.shared.show() }
            }
            presets
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "wind").font(.title3).foregroundStyle(.tint)
            Text("Brise").font(.title3.bold())
            Spacer()
            if let reason = monitor.fanOverride {
                Label(reason, systemImage: "bolt.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(Preset.allCases) { preset in
                Button { monitor.apply(preset) } label: {
                    Label(preset.label, systemImage: preset.icon)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(monitor.activePreset == preset ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fanDetail: String {
        if let reason = monitor.fanOverride { return "À fond · \(reason)" }
        return "tr/min · \(monitor.fanMode.label)"
    }

    private var awakeDetail: String {
        guard monitor.keepAwake else { return "Clic droit : durée" }
        guard let until = monitor.keepAwakeUntil else { return "Jusqu'à arrêt" }
        return "Jusqu'à \(until.formatted(date: .omitted, time: .shortened))"
    }

    private var batteryIcon: String {
        guard let b = monitor.battery else { return "battery.100" }
        if b.charging { return "battery.100.bolt" }
        return b.percent > 75 ? "battery.100" : b.percent > 50 ? "battery.75" : b.percent > 25 ? "battery.50" : "battery.25"
    }

    private var batteryDetail: String {
        if let limit = monitor.chargeLimit, limit < 100 { return "Limite \(limit) %" }
        if let h = monitor.battery?.health { return "Santé \(Int(h * 100)) %" }
        return ""
    }
}

/// A Control-Center-style square. Toggles light up when active; others open a page.
private struct Tile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    var tint: Color = .accentColor
    var active = false
    var isToggle = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(active ? tint : tint.opacity(0.15), in: Circle())
                        .foregroundStyle(active ? .white : tint)
                    Spacer()
                    Image(systemName: isToggle ? "power" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .opacity(isToggle ? 0 : 1)
                }
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(active ? tint.opacity(0.16) : Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(active ? tint.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

private struct DetailHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Label("Accueil", systemImage: "chevron.left").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Color.clear.frame(width: 60, height: 1)
        }
    }
}

/// Error or confirmation line + quit, shown under every page.
private struct StatusLine: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let toast = monitor.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(3))
                        if monitor.toast == toast { monitor.toast = nil }
                    }
            }
            HStack {
                Spacer()
                Button("Quitter Brise") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
    }
}
