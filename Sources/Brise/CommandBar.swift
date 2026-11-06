import BriseCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Text field + live suggestions. Used inside the panel and in the floating ⌥Space bar.
struct CommandBarView: View {
    @Environment(Monitor.self) private var monitor
    var autofocus = false
    var compact = false
    var onDone: (() -> Void)?

    @State private var text = ""
    @State private var selection = 0
    @State private var result: String?
    @FocusState private var focused: Bool

    private var suggestions: [(BriseCommand, CommandInput)] { CommandCatalog.suggestions(for: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("What do you want to do? “fans max”, “volume 30”…", "Que veux-tu faire ? « ventilos à fond », « volume 30 »…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(compact ? .callout : .title3)
                    .focused($focused)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { onDone?(); return .handled }
                    .onChange(of: text) { selection = 0; result = nil }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(compact ? 8 : 12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: compact ? 8 : 12))

            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .padding(.horizontal, 6)
            } else if !text.isEmpty || !compact {
                VStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.0.id) { index, item in
                        Button { run(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.0.icon).frame(width: 18)
                                Text(item.0.title(item.1))
                                Spacer()
                                if index == selection { Text("↩").foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, compact ? 4 : 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == selection ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(compact ? .callout : .body)
                    }
                    if suggestions.isEmpty {
                        Text(tr("No matching command.", "Aucune commande ne correspond.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { if autofocus { focused = true } }
    }

    private func move(_ delta: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    private func runSelected() {
        let list = suggestions
        guard list.indices.contains(selection) else { return }
        run(list[selection])
    }

    private func run(_ item: (BriseCommand, CommandInput)) {
        let message = item.0.run(item.1, monitor)
        result = message
        text = ""
        monitor.toast = message
        if let onDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onDone() }
        }
    }
}

/// Floating Spotlight-like panel opened with a global shortcut.
@MainActor
final class CommandPanel {
    static let shared = CommandPanel()
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private(set) var shortcutLabel = tr("⌥Space", "⌥Espace")

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { CommandPanel.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x4252_5345), id: 1)   // 'BRSE'
        // ⌥Space first; if another app already owns it, fall back to ⌥⌘B.
        if RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey) != noErr {
            RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
            shortcutLabel = "⌥⌘B"
        }
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let root = CommandBarView(autofocus: true) { [weak self] in self?.close() }
            .environment(Monitor.shared)
            .padding(14)
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        panel.contentView = NSHostingView(rootView: root)
        panel.setContentSize(NSSize(width: 560, height: 330))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 280, y: f.maxY - f.height * 0.18))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}
