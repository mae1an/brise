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
                Image(systemName: monitor.boostActive || monitor.fanMode != .auto ? "fan.fill" : "thermometer.medium")
                Text(monitor.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    /// `Brise --preview` also shows the panel in a regular window (handy for screenshots).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--preview") else { return }
        MainActor.assumeIsolated {
            let host = NSHostingView(rootView: PanelView().environment(Monitor.shared))
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
        MainActor.assumeIsolated { Monitor.shared.restoreAutomaticFans() }
        return .terminateNow
    }
}
