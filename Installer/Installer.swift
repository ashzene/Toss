import AppKit

@MainActor final class InstallSource: NSImageView {
    var source: URL!
    weak var destinationView: NSView?
    var onDrop: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window, let host = superview else { return }
        let ghost=NSImageView(frame:frame);ghost.image=image;ghost.imageScaling=imageScaling
        ghost.alphaValue=0.7;host.addSubview(ghost)
        defer { ghost.removeFromSuperview() }
        var moved=false
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            let point=host.convert(next.locationInWindow,from:nil)
            if next.type == .leftMouseDragged {
                moved=true
                ghost.setFrameOrigin(NSPoint(x:point.x-frame.width/2,y:point.y-frame.height/2))
            } else {
                if moved, let destinationView,
                   destinationView.bounds.contains(destinationView.convert(next.locationInWindow,from:nil)) {
                    onDrop?()
                }
                break
            }
        }
    }
}
@MainActor final class InstallDestination:NSImageView {
    var source:URL!
    var onDrop:(()->Void)?
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        guard let paths=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self]) as? [URL],
              paths.count==1,paths[0].standardizedFileURL==source.standardizedFileURL else {return []}
        return .copy
    }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard draggingEntered(sender) == .copy else{return false}
        onDrop?();return true
    }
}
@MainActor final class Installer:NSObject, NSApplicationDelegate {
    var window:NSWindow!
    let note=NSTextField(wrappingLabelWithString:"")
    let sourceView=InstallSource()
    let destinationView=InstallDestination()
    var busy=false
    #if INSTALLER_QA
    let qa = true
    #else
    let qa = false
    #endif
    var source:URL { Bundle.main.resourceURL!.appendingPathComponent("Toss.app") }
    var destination:URL {
        qa ? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("QA-Installed/Toss.app") : URL(fileURLWithPath:"/Applications/Toss.app")
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:440),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Toss " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "");window.isReleasedWhenClosed=false
        window.backgroundColor=NSColor(srgbRed:0.98,green:0.976,blue:0.961,alpha:1)
        window.isMovableByWindowBackground=true
        let root=window.contentView!
        let background=NSImageView(frame:NSRect(x:0,y:-20,width:720,height:460))
        background.image=NSImage(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("background.tiff"))
        background.imageScaling = .scaleAxesIndependently;root.addSubview(background)
        func label(_ text:String,_ x:CGFloat,_ y:CGFloat) {
            let v=NSTextField(labelWithString:text);v.font = .systemFont(ofSize:13)
            v.textColor = .black;v.alignment = .center
            v.frame=NSRect(x:x-90,y:440-y-92,width:180,height:22);root.addSubview(v)
        }
        sourceView.image=NSImage(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Toss.icns"))
        sourceView.imageScaling = .scaleProportionallyUpOrDown
        sourceView.frame=NSRect(x:122,y:130,width:128,height:128);sourceView.source=source
        sourceView.setAccessibilityLabel("Toss — drag to install");root.addSubview(sourceView)
        destinationView.image=NSWorkspace.shared.icon(forFile:"/Applications")
        destinationView.imageScaling = .scaleProportionallyUpOrDown
        destinationView.frame=NSRect(x:470,y:130,width:128,height:128);destinationView.source=source
        destinationView.registerForDraggedTypes([.fileURL]);destinationView.onDrop={ [weak self] in self?.install() }
        destinationView.setAccessibilityLabel("Applications — drop here");root.addSubview(destinationView)
        sourceView.destinationView=destinationView;sourceView.onDrop={ [weak self] in self?.install() }
        label("Toss",186,246);label("Applications",534,246)
        let guide=NSButton(frame:NSRect(x:578,y:44,width:128,height:128))
        guide.image=NSImage(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Guide.icns"))
        guide.imagePosition = .imageOnly;guide.imageScaling = .scaleProportionallyUpOrDown
        guide.isBordered=false;guide.target=self;guide.action=#selector(showGuide)
        guide.setAccessibilityLabel("User Guide");root.addSubview(guide);label("User Guide",642,332)
        note.stringValue="";note.frame=NSRect(x:260,y:130,width:200,height:48)
        note.alignment = .center;note.font = .systemFont(ofSize:13);note.textColor = .black;root.addSubview(note)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    var guideWindow:NSWindow?
    @objc func showGuide(){
        let win=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        win.title="User Guide";win.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:win.contentView!.bounds);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true
        let text=NSTextView(frame:scroll.bounds);text.isEditable=false;text.isVerticallyResizable=true;text.autoresizingMask=[.width]
        text.textContainer?.widthTracksTextView=true
        text.string=(try? String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("User Guide.txt"),encoding:.utf8)) ?? ""
        scroll.documentView=text;win.contentView!.addSubview(scroll);guideWindow=win;win.center();win.makeKeyAndOrderFront(nil)
    }
    var payloadID: String { Bundle.main.object(forInfoDictionaryKey: "TossPayloadIdentifier") as! String }
    var payloadHash: String { Bundle.main.object(forInfoDictionaryKey: "TossPayloadHash") as! String }
    func install() {
        guard !busy else { return }; busy = true
        window.standardWindowButton(.closeButton)?.isEnabled = false
        note.stringValue = "正在安装… / Installing…"
        Task {
            let fm = FileManager.default
            let source = self.source, destination = self.destination
            let identifier = payloadID, hash = payloadHash
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".Toss-install-" + UUID().uuidString + ".app")
            defer { try? fm.removeItem(at: stage) }
            do {
                if qa { try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
                try await Task.detached {
                    try InstallFiles.verify(source, identifier: identifier, hash: hash)
                    try FileManager.default.copyItem(at: source, to: stage)
                    try InstallFiles.verify(stage, identifier: identifier, hash: hash)
                }.value
                if fm.fileExists(atPath: destination.path), Bundle(url: destination)?.bundleIdentifier != identifier {
                    throw InstallFailure(message: "Applications 里已有另一个同名文件。 / A different file exists at the destination.")
                }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                for app in running { app.terminate() }
                for _ in 0..<50 {
                    if running.allSatisfy(\.isTerminated) { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard running.allSatisfy(\.isTerminated) else {
                    throw InstallFailure(message: "请先退出正在运行的 Toss，再拖一次。 / Quit Toss and drag again.")
                }
                try InstallFiles.commit(stage: stage, destination: destination)
                let legacy = destination.deletingLastPathComponent().appendingPathComponent("Tossuspended.app")
                if !qa, Bundle(url: legacy)?.bundleIdentifier == identifier {
                    _ = try fm.trashItem(at: legacy, resultingItemURL: nil)
                }
                note.stringValue = "安装完成，正在打开设置… / Opening setup…"
                let launch = NSWorkspace.OpenConfiguration(); launch.arguments = ["--show-setup"]
                _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: launch)
                busy = false
                NSApp.terminate(nil)
            } catch {
                note.stringValue = "安装未完成：\(error.localizedDescription)"; busy = false
                window.standardWindowButton(.closeButton)?.isEnabled = true
            }
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {!busy}
}
#if !INSTALLER_TESTS
@main enum Main {
    @MainActor static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=Installer();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}

#endif
