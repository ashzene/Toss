import AppKit

@MainActor private final class EntryPreferences: StartupPreferenceStoring {
    var desiredEnabled = false
    var loginChoiceMade = true
    func clearOwnedPreferences() { fatalError("Entry must not clear preferences") }
}
@MainActor private final class EntryLogin: StartupLoginManaging {
    var status: StartupLoginStatus { .notRegistered }
    func register() throws { fatalError("Entry must not register login") }
    func unregister() async throws { fatalError("Entry must not unregister login") }
}
@main enum EntryRoutingTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain); RenderState.onOpenInterface = nil; RenderState.pairedDevices = nil }
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); count += 1 }
        let prefs = EntryPreferences()
        let delegate = TossDelegate(startup: StartupController(preferences: prefs, service: EntryLogin()))
        RenderState.permissions = true; RenderState.pairing = false
        RenderState.connection = .init(state: .notChecked, reason: "not_checked")
        var opened: [String] = []
        RenderState.onOpenInterface = { opened.append($0) }
        for classes: Set<DeviceClass> in [[], [.iPhone], [.iPad], [.iPhone, .iPad]] {
            var files: [String: Data] = [:]
            var pins: [String: [String: String]] = [:]
            for kind in classes {
                let pin = ["device_class": kind.rawValue, "model": kind.rawValue + "15,1", "device_hash": "fixture-" + kind.rawValue]
                pins[kind.rawValue] = pin
                files["/fixture/devices/" + kind.rawValue + "/target.json"] = try! JSONSerialization.data(withJSONObject: pin)
                files["/fixture/devices/" + kind.rawValue + "/strict-remote-pairing.plist"] = Data()
            }
            files["/fixture/target.json"] = try! JSONSerialization.data(withJSONObject: ["schema_version": 2, "devices": pins])
            var devices = PairedDevicesState()
            devices.restore(root: "/fixture", read: { files[$0] }, exists: { files[$0] != nil })
            check(devices.classes == classes, "Fixture restores the actual dual-device index")
            RenderState.pairedDevices = devices
            let paired = !classes.isEmpty
            for first in [false,true] { for seen in [false,true] {
            prefs.loginChoiceMade = !first
            UserDefaults.standard.setVolatileDomain([OnboardingPolicy.seenKey:seen,TossDelegate.reopenSettingsKey:false],forName:UserDefaults.argumentDomain)
            opened = []; delegate.renderInitialEntry()
            check(opened == (!paired ? ["setup"] : first ? [seen ? "settings" : "setup"] : []), "Launch chooses setup from actual pairing, including stale seen flag")
            opened = []; _ = delegate.applicationShouldHandleReopen(app,hasVisibleWindows:false)
            check(opened == [paired ? "settings" : "setup"], "Dock reopens setup until paired")
            opened = []; delegate.renderInitialEntry(afterInstall:true)
            check(opened == ["setup"], "Installer explicitly opens its setup window")
        } } }
        RenderState.pairedDevices = PairedDevicesState()
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let status = delegate.renderStatusEntry(item:item)
        for _ in 0..<3 {
            opened = []; item.button?.performClick(nil)
            check(opened == ["setup"], "Actual status button action opens setup while unpaired")
        }
        opened = []; status.showPanel()
        check(opened == ["setup"], "Connection Status entry uses the same unpaired gate")
        check(!prefs.desiredEnabled && prefs.loginChoiceMade == false, "Entry does not change startup choices")
        print("Entry routing: \(count) checks passed through production launch, Dock, status-button and installer routes; no device, login or persistent preference changes.")
    }
}
