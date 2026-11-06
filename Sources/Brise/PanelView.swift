import BriseCore
import Charts
import SwiftUI

struct PanelView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            TemperatureCard()
            FansCard()
            SystemCard()
            ProcessesCard()
            ActionsCard()
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "wind").font(.title3).foregroundStyle(.tint)
            Text("Brise").font(.title3.bold())
            Spacer()
            if monitor.boostActive {
                Text("BOOST").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.red.opacity(0.2), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Tr/min dans la barre", isOn: Binding(
                get: { monitor.showRPMInMenuBar }, set: { monitor.showRPMInMenuBar = $0 }))
                .toggleStyle(.checkbox).font(.caption)
            Spacer()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private func tempColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    switch t {
    case ..<60: return .green
    case ..<80: return .yellow
    case ..<92: return .orange
    default: return .red
    }
}

private struct TemperatureCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var showAll = false

    var body: some View {
        Card(title: "Températures", icon: "thermometer.medium") {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                bigValue("CPU", monitor.cpuTemp)
                bigValue("GPU", monitor.gpuTemp)
                Spacer()
            }
            if monitor.history.count > 2 {
                Chart(monitor.history) { point in
                    AreaMark(x: .value("t", point.date),
                             yStart: .value("min", yDomain.lowerBound),
                             yEnd: .value("°C", point.value))
                        .foregroundStyle(tempColor(monitor.cpuTemp).opacity(0.18).gradient)
                    LineMark(x: .value("t", point.date), y: .value("°C", point.value))
                        .foregroundStyle(tempColor(monitor.cpuTemp))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .chartYScale(domain: yDomain)
                .chartPlotStyle { $0.clipped() }
                .frame(height: 60)
            }
            DisclosureGroup("Tous les capteurs (\(monitor.sensors.count))", isExpanded: $showAll) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(monitor.sensors.sorted { $0.value > $1.value }) { s in
                            HStack {
                                Text(s.name).lineLimit(1)
                                Spacer()
                                Text("\(Int(s.value.rounded()))°").monospacedDigit().foregroundStyle(tempColor(s.value))
                            }
                            .font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            .font(.caption)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = monitor.history.map(\.value)
        let lo = (values.min() ?? 30) - 3, hi = (values.max() ?? 90) + 3
        return lo...max(hi, lo + 10)
    }

    private func bigValue(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tempColor(value))
                .contentTransition(.numericText())
        }
    }
}

private struct FansCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Card(title: "Ventilateurs", icon: "fan") {
            ForEach(monitor.fans) { fan in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(monitor.fans.count == 2 ? (fan.id == 0 ? "Gauche" : "Droite") : "Ventilo \(fan.id + 1)")
                        Spacer()
                        Text("\(Int(fan.current)) tr/min").monospacedDigit()
                    }
                    .font(.callout)
                    ProgressView(value: fan.level).tint(fan.forced ? .orange : .accentColor)
                }
            }
            if monitor.helperInstalled {
                Picker("Mode", selection: $monitor.fanMode) {
                    ForEach(FanMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if monitor.fanMode == .custom {
                    Slider(value: $monitor.customLevel, in: 0...1) { editing in
                        if !editing { monitor.applyCustomLevel() }
                    }
                    if let fan = monitor.fans.first {
                        Text("Cible : \(monitor.customRPM(for: fan)) tr/min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SwitchRow("Boost auto au-delà de \(Int(monitor.boostThreshold))°C", isOn: $monitor.autoBoost)
                if monitor.autoBoost {
                    Slider(value: $monitor.boostThreshold, in: 70...100, step: 1)
                }
            } else {
                Button {
                    monitor.installHelper()
                } label: {
                    Label("Activer le contrôle des ventilos", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text("Demande ton mot de passe une seule fois.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SystemCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Card(title: "Système", icon: "cpu") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Processeur", value: monitor.cpuLoad.map { "\(Int($0 * 100)) %" }, fraction: monitor.cpuLoad)
                row("Mémoire",
                    value: monitor.memory.map { "\(Format.bytes(Double($0.used))) / \(Format.bytes(Double($0.total)))" },
                    fraction: monitor.memory?.fraction)
                GridRow {
                    Text("Réseau").foregroundStyle(.secondary)
                    Text(monitor.network.map { "↓ \(Format.rate($0.down))   ↑ \(Format.rate($0.up))" } ?? "—")
                        .monospacedDigit()
                        .gridCellColumns(2)
                }
                if let b = monitor.battery {
                    GridRow {
                        Text("Batterie").foregroundStyle(.secondary)
                        Text(batteryText(b)).gridCellColumns(2)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, value: String?, fraction: Double?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ProgressView(value: fraction ?? 0).frame(width: 70)
            Text(value ?? "—").monospacedDigit().lineLimit(1)
        }
    }

    private func batteryText(_ b: BatteryInfo) -> String {
        var text = "\(b.percent) %"
        if b.charging { text += " ⚡︎" } else if b.pluggedIn { text += " (secteur)" }
        if let h = b.health { text += " · santé \(Int(h * 100)) %" }
        if let c = b.cycles { text += " · \(c) cycles" }
        return text
    }
}

private struct ProcessesCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var hovered: Int32?

    var body: some View {
        Card(title: "Qui chauffe ?", icon: "flame") {
            ForEach(monitor.topProcesses) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f %%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        monitor.terminate(p)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovered == p.pid ? 1 : 0)
                    .help("Quitter \(p.name)")
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? p.pid : (hovered == p.pid ? nil : hovered) }
            }
        }
    }
}

private struct ActionsCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Card(title: "Raccourcis", icon: "bolt") {
            SwitchRow("Garder le Mac éveillé", isOn: $monitor.keepAwake)
            if monitor.helperInstalled {
                SwitchRow("Mode économie d'énergie", isOn: Binding(
                    get: { monitor.lowPowerMode }, set: { monitor.setLowPowerMode($0) }))
            }
            SwitchRow("Lancer au démarrage", isOn: Binding(
                get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
            if monitor.helperInstalled {
                Button {
                    monitor.purgeMemory()
                } label: {
                    Label("Libérer la mémoire inactive", systemImage: "memorychip")
                }
            }
        }
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .font(.callout)
    }
}
