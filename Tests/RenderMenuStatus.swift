import AppKit

// Offline visual QA of the actual native views. No TossDelegate, worker,
// network, hotkey, clipboard, settings, or installation code is linked.
@main
@MainActor
struct RenderMenuStatus {
    static func main() throws {
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for dark in [false, true] {
            for (name, status, phase) in [
                ("connected", TossConnectionStatus(state: .ready, reason: "ready"), TossTransferPhase.idle),
                ("uploading", TossConnectionStatus(state: .ready, reason: "ready"), .uploading),
                ("failed", TossConnectionStatus(state: .failed, reason: "no_authenticated_remote_wifi_connection"), .failed),
                ("done", TossConnectionStatus(state: .ready, reason: "ready"), .completed)
            ] {
                let panel = TossStatusPanel()
                panel.loadViewIfNeeded()
                panel.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                panel.update(.init(connection: status, phase: phase, paired: true, enabled: true))
                let height = panel.preferredContentSize.height
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 334, height: height + 64),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = panel.view.appearance
                window.backgroundColor = .windowBackgroundColor
                let host = window.contentView!
                host.wantsLayer = true
                window.appearance?.performAsCurrentDrawingAppearance {
                    host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                panel.view.frame = NSRect(x: 12, y: 12, width: 310, height: height)
                host.addSubview(panel.view)
                let icon = TossMenuIcon(frame: NSRect(x: 210, y: height + 28, width: 22, height: 22))
                host.addSubview(icon)
                icon.setUploading(phase.animates)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Bitmap unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
                try data.write(to: destination.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
        print("Rendered 8 native status panels.")
    }
}
