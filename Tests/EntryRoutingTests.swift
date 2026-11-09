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
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain); RenderState.onOpenInterface = nil }
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); count += 1 }
        let prefs = EntryPreferences()
        let delegate = TossDelegate(startup: StartupController(preferences: prefs, service: EntryLogin()))
        RenderState.permissions = true; RenderState.pairing = false
        RenderState.connection = .init(state: .notChecked, reason: "not_checked")
        var opened: [String] = []
        RenderState.onOpenInterface = { opened.append($0) }
        for paired in [false,true] { for first in [false,true] { for seen in [false,true] {
            RenderState.paired = paired; prefs.loginChoiceMade = !first
            UserDefaults.standard.setVolatileDomain([OnboardingPolicy.seenKey:seen,TossDelegate.reopenSettingsKey:false],forName:UserDefaults.argumentDomain)
            opened = []; delegate.renderInitialEntry()
            check(opened == (!paired ? ["setup"] : first ? [seen ? "settings" : "setup"] : []), "Launch chooses setup from actual pairing, including stale seen flag")
            opened = []; _ = delegate.applicationShouldHandleReopen(app,hasVisibleWindows:false)
            check(opened == [paired ? "settings" : "setup"], "Dock reopens setup until paired")
            opened = []; delegate.renderInitialEntry(afterInstall:true)
            check(opened == ["setup"], "Installer explicitly opens its setup window")
        } } }
        RenderState.paired = false
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
