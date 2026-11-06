import BriseCore
import Charts
import SwiftUI

// MARK: - Shared pieces

struct Card<Content: View>: View {
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
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SwitchRow: View {
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

func tempColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    switch t {
    case ..<60: return .green
    case ..<80: return .yellow
    case ..<92: return .orange
    default: return .red
    }
}

/// Shown wherever a feature needs the root helper.
struct AdminButton: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { monitor.installHelper() } label: {
                Label(monitor.helperOutdated ? tr("Update admin mode", "Mettre à jour le mode admin") : tr("Turn on admin mode", "Activer le mode admin"),
                      systemImage: "lock.open").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Text(tr("Fans, lid closed, charge limit. Asks for your password once.", "Ventilos, capot fermé, limite de charge. Mot de passe demandé une seule fois."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Temperatures

struct TemperatureCard: View {
    @Environment(Monitor.self) private var monitor
    var expanded = false
    @State private var showAll = true

    var body: some View {
        Card(title: tr("Temperatures", "Températures"), icon: "thermometer.medium") {
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
                .frame(height: expanded ? 90 : 60)
            }
            DisclosureGroup(tr("All sensors (\(monitor.sensors.count))", "Tous les capteurs (\(monitor.sensors.count))"), isExpanded: $showAll) {
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
                .frame(maxHeight: 220)
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

// MARK: - Fans

struct FansCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Card(title: tr("Fans", "Ventilateurs"), icon: "fan") {
            ForEach(monitor.fans) { fan in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(monitor.fans.count == 2 ? (fan.id == 0 ? tr("Left", "Gauche") : tr("Right", "Droite")) : tr("Fan \(fan.id + 1)", "Ventilo \(fan.id + 1)"))
                        Spacer()
                        Text(tr("\(Int(fan.current)) rpm", "\(Int(fan.current)) tr/min")).monospacedDigit()
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
                        Text(tr("Target: \(monitor.customRPM(for: fan)) rpm", "Cible : \(monitor.customRPM(for: fan)) tr/min"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SwitchRow(tr("Auto boost above \(Int(monitor.boostThreshold))°C", "Boost auto au-delà de \(Int(monitor.boostThreshold))°C"), isOn: $monitor.autoBoost)
                if monitor.autoBoost {
                    Slider(value: $monitor.boostThreshold, in: 70...100, step: 1)
                }
                SwitchRow(tr("Show rpm in the menu bar", "Tr/min dans la barre des menus"), isOn: $monitor.showRPMInMenuBar)
            } else {
                AdminButton()
            }
        }
    }
}

struct AutomationsCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Card(title: tr("Full blast automatically when…", "À fond automatiquement quand…"), icon: "wand.and.stars") {
            if monitor.heavyApps.isEmpty {
                Text(tr("No render app found.", "Aucune app de rendu détectée.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.heavyApps) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon { Image(nsImage: icon) }
                    Text(app.name)
                    if monitor.runningHeavyApp == app.name {
                        Text(tr("open", "ouvert")).font(.caption2.bold()).foregroundStyle(.orange)
                    }
                    Spacer()
                    Toggle(app.name, isOn: Binding(
                        get: { monitor.isAppEnabled(app) }, set: { monitor.setApp(app, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                .font(.callout)
            }
            Text(tr("Fans go back to their usual mode when the app quits.", "Les ventilos repassent dans leur mode habituel quand l'app se ferme."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - System

struct SystemCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Card(title: tr("System", "Système"), icon: "cpu") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(tr("CPU", "Processeur"), value: monitor.cpuLoad.map { "\(Int($0 * 100)) %" }, fraction: monitor.cpuLoad)
                row(tr("Memory", "Mémoire"),
                    value: monitor.memory.map { "\(Format.bytes(Double($0.used))) / \(Format.bytes(Double($0.total)))" },
                    fraction: monitor.memory?.fraction)
                GridRow {
                    Text(tr("Network", "Réseau")).foregroundStyle(.secondary)
                    Text(monitor.network.map { "↓ \(Format.rate($0.down))   ↑ \(Format.rate($0.up))" } ?? "—")
                        .monospacedDigit()
                        .gridCellColumns(2)
                }
            }
            .font(.callout)
            if monitor.helperInstalled {
                Button { monitor.purgeMemory() } label: {
                    Label(tr("Free inactive memory", "Libérer la mémoire inactive"), systemImage: "memorychip")
                }
                .controlSize(.small)
            }
        }
    }

    private func row(_ label: String, value: String?, fraction: Double?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ProgressView(value: fraction ?? 0).frame(width: 70)
            Text(value ?? "—").monospacedDigit().lineLimit(1)
        }
    }
}

struct ProcessesCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var hovered: Int32?

    var body: some View {
        Card(title: tr("What's heating?", "Qui chauffe ?"), icon: "flame") {
            ForEach(monitor.topProcesses) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f %%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    Button { monitor.terminate(p) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(hovered == p.pid ? 1 : 0)
                        .help(tr("Quit \(p.name)", "Quitter \(p.name)"))
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? p.pid : (hovered == p.pid ? nil : hovered) }
            }
        }
    }
}

// MARK: - Battery

struct BatteryCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var limitDraft: Double = 80

    var body: some View {
        Card(title: tr("Battery", "Batterie"), icon: "battery.75") {
            if let b = monitor.battery {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(b.percent) %").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(b.charging ? tr("charging", "en charge") : b.pluggedIn ? tr("plugged in", "sur secteur") : tr("on battery", "sur batterie"))
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let h = b.health { info(tr("Health", "Santé"), "\(Int(h * 100)) %", h < 0.8 ? .orange : .primary) }
                    if let c = b.cycles { info("Cycles", "\(c)", .primary) }
                    if let t = monitor.batteryTemp { info(tr("Temperature", "Température"), "\(Int(t.rounded()))°", tempColor(t)) }
                }
                .font(.callout)
            }
        }
        Card(title: tr("Charge limit", "Limite de charge"), icon: "bolt.badge.checkmark") {
            if monitor.chargeLimit == nil {
                Text(tr("This Mac doesn't support a charge limit.", "Ce Mac ne permet pas de limiter la charge.")).font(.caption).foregroundStyle(.secondary)
            } else if monitor.helperInstalled {
                SwitchRow(tr("Stop charging at \(Int(limitDraft)) %", "Arrêter la charge à \(Int(limitDraft)) %"), isOn: Binding(
                    get: { (monitor.chargeLimit ?? 100) < 100 },
                    set: { monitor.setChargeLimit($0 ? Int(limitDraft) : 100) }))
                Slider(value: $limitDraft, in: 50...95, step: 5) { editing in
                    if !editing, (monitor.chargeLimit ?? 100) < 100 { monitor.setChargeLimit(Int(limitDraft)) }
                }
                Text(tr("Sitting at 100 % wears the battery out. 80 % is the sweet spot if your Mac lives on the charger.", "Rester branché à 100 % use la batterie. 80 % est le bon compromis si ton Mac vit sur secteur."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                AdminButton()
            }
        }
        .onAppear {
            if let limit = monitor.chargeLimit, limit < 100 { limitDraft = Double(limit) }
        }
    }

    private func info(_ label: String, _ value: String, _ color: Color) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
    }
}

// MARK: - Controls

struct ControlsCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var confirmTrash = false

    var body: some View {
        Card(title: tr("Sound & display", "Son & écran"), icon: "speaker.wave.2") {
            sliderRow("speaker.wave.2.fill", value: Binding(
                get: { monitor.volume / 100 }, set: { monitor.setVolume($0 * 100) }))
            if let b = monitor.brightness {
                sliderRow("sun.max.fill", value: Binding(
                    get: { b }, set: { monitor.setBrightness($0) }))
            }
            SwitchRow(tr("Dark mode", "Mode sombre"), isOn: Binding(
                get: { monitor.darkMode }, set: { monitor.setDarkMode($0) }))
            if monitor.helperInstalled {
                SwitchRow(tr("Low Power Mode", "Économie d'énergie"), isOn: Binding(
                    get: { monitor.lowPowerMode }, set: { monitor.setLowPowerMode($0) }))
            }
        }
        Card(title: "Actions", icon: "bolt") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                action(tr("Lock", "Verrouiller"), "lock.fill") { MacControls.lockScreen() }
                action(tr("Display off", "Écran noir"), "display") { MacControls.sleepDisplay() }
                action(tr("Eject", "Éjecter"), "eject.fill") { monitor.ejectDisks() }
                action(tr("Trash", "Corbeille"), "trash.fill") { confirmTrash = true }
            }
        }
        .confirmationDialog(tr("Empty the Trash?", "Vider la corbeille ?"), isPresented: $confirmTrash) {
            Button(tr("Empty permanently", "Vider définitivement"), role: .destructive) { monitor.emptyTrash() }
        } message: {
            Text(tr("Files will be deleted for good.", "Les fichiers seront supprimés pour de bon."))
        }
        Card(title: "Brise", icon: "wind") {
            SwitchRow(tr("Launch at login", "Lancer au démarrage"), isOn: Binding(
                get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
        }
        .onAppear { monitor.refreshControls() }
    }

    private func sliderRow(_ icon: String, value: Binding<Double>) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
        }
    }

    private func action(_ title: String, _ icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
