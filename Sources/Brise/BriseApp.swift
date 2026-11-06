import AppKit
import SwiftUI

@main
struct BriseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.fansForced ? "fan.fill" : monitor.lidClosedAwake ? "power.circle.fill" : "thermometer.medium")
                Text(monitor.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    /// `Brise --preview` also shows the panel in a regular window (handy for screenshots).
    /// `--page fans` opens a detail page in the preview window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            CommandPanel.shared.registerHotKey()
            if Monitor.shared.touchBarWidget { TouchBarController.shared.install() }
            if CommandLine.arguments.contains("--touchbar") { TouchBarController.shared.showBar() }
        }
        let args = CommandLine.arguments
        guard args.contains("--preview") else { return }
        MainActor.assumeIsolated {
            let page = args.firstIndex(of: "--page").flatMap { $0 + 1 < args.count ? Page(rawValue: args[$0 + 1]) : nil }
            let host = NSHostingView(rootView: PanelView(page: page).environment(Monitor.shared))
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Brise"
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window

            // `--snapshot <file.png>`: render the panel to a PNG after a few readings.
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    host.setFrameSize(host.fittingSize)
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Monitor.shared.restoreDefaultsOnQuit()
            TouchBarController.shared.uninstall()
        }
        return .terminateNow
    }
}
