import Foundation
import CoreFoundation
import ServiceManagement

// Startup intent belongs to this helper, while login-item approval belongs to
// macOS. Never treat a saved preference as proof of system approval or AX access.
enum StartupLoginStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    // A never-registered main app can report notFound before onboarding.
    var isAbsent: Bool { self == .notRegistered || self == .notFound }

    var text: String {
        switch self {
        case .notRegistered: return L("Launch at Login: Off", "登录时打开：关")
        case .enabled: return L("Launch at Login: On", "登录时打开：开")
        case .requiresApproval: return L("Allow it in General → Login Items.", "需要在 通用 → 登录项 里允许。")
        case .notFound: return L("Login item not found.", "找不到登录项。")
        case .unknown: return L("Status unavailable.", "状态未知。")
        }
    }
}

enum StartupControllerError: LocalizedError, Equatable {
    case approvalRequired, registrationFailed, unregistrationFailed, operationInProgress

    var errorDescription: String? {
        switch self {
        case .approvalRequired: return StartupLoginStatus.requiresApproval.text
        case .registrationFailed:
            return L("Couldn't turn on. Shortcuts still work.", "没能打开，快捷键照常能用。")
        case .unregistrationFailed:
            return L("Couldn't confirm removal. Check Login Items.", "没能确认已移除，请看登录项。")
        case .operationInProgress:
            return L("Login items are updating. Try again soon.", "登录项正在更新，稍后再试。")
        }
    }
}

// Injectable boundaries keep offline tests from touching real login items or
// the user's preference domain. They also keep this file free of AppKit/UI.
@MainActor
protocol StartupPreferenceStoring: AnyObject {
    var desiredEnabled: Bool { get set }
    var loginChoiceMade: Bool { get set }
    func clearOwnedPreferences()
}

@MainActor
protocol StartupLoginManaging: AnyObject {
    var status: StartupLoginStatus { get }
    func register() throws
    func unregister() async throws
}

@MainActor
final class HelperStartupPreferences: StartupPreferenceStoring {
    // Explicit domain also works for the app's early, UI-free uninstall entry.
    // Do not remove the whole defaults domain: other helper preferences may be
    // introduced later and are not owned by this controller.
    // UserDefaults(suiteName: ownBundleIdentifier) is invalid in a real app and
    // can return nil. CFPreferences accepts an explicit application domain in
    // both the app and its early UI-free command entry, without force unwraps.
    private let domain: CFString
    init(domain: String) { self.domain = domain as CFString }

    private func read(_ key: String) -> Bool {
        guard let value = CFPreferencesCopyValue(key as CFString, domain,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFEqual(value, kCFBooleanTrue)
    }

    private func write(_ value: Bool, key: String) {
        CFPreferencesSetValue(key as CFString, value ? kCFBooleanTrue : kCFBooleanFalse,
                              domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // User Enable/Disable and the uninstall CLI must survive an immediate
        // process exit. This writes only this explicit user/application domain.
        _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    var desiredEnabled: Bool {
        get { read(StartupController.desiredEnabledKey) }
        set { write(newValue, key: StartupController.desiredEnabledKey) }
    }
    var loginChoiceMade: Bool {
        get { read(StartupController.loginChoiceMadeKey) }
        set { write(newValue, key: StartupController.loginChoiceMadeKey) }
    }
    func clearOwnedPreferences() {
        for key in [StartupController.desiredEnabledKey, StartupController.loginChoiceMadeKey] {
            CFPreferencesSetValue(key as CFString, nil, domain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

@MainActor
private final class SystemStartupLogin: StartupLoginManaging {
    var status: StartupLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

// What the Turn On / Turn Off toggle does. With neither ChatGPT / Codex nor
// Claude running there is nothing to prepare yet, so Turn On keeps the choice
// and waits: the restore path enables shortcuts as soon as one of them opens
// (2026-10-22: Turn On used to fail silently and forget the choice).
enum StartupPolicy {
    enum EnableAction: Equatable { case disable, start, waitForTarget }

    static func enableAction(enabled: Bool, enabling: Bool, desired: Bool, targetRunning: Bool) -> EnableAction {
        if enabled || enabling || desired { return .disable }
        return targetRunning ? .start : .waitForTarget
    }
}

@MainActor
final class StartupController {
    static let preferencesDomain = "io.github.ashzene.toss"
    static let desiredEnabledKey = "startup.desiredEnabled.v1"
    static let loginChoiceMadeKey = "startup.loginChoiceMade.v1"
    private let preferences: StartupPreferenceStoring
    private let service: StartupLoginManaging
    private var changingLoginRegistration = false

    convenience init() {
        self.init(preferences: HelperStartupPreferences(domain: Self.preferencesDomain), service: SystemStartupLogin())
    }

    init(preferences: StartupPreferenceStoring, service: StartupLoginManaging) {
        self.preferences = preferences
        self.service = service
        // Construction and preference reads never register, request permission,
        // launch a process, connect to a device, or interact with another app.
    }

    var desiredEnabled: Bool { preferences.desiredEnabled }
    // True once the first Enable happened (auto or by hand); before that the
    // app may enable itself after pairing without asking for another click.
    var firstEnableDone: Bool { preferences.loginChoiceMade }
    var loginStatus: StartupLoginStatus { service.status }
    var loginStatusText: String { loginStatus.text }
    // Only enabled confirms eligibility to run. Approval-pending registration
    // may be shown separately, never as a successfully enabled login item.
    var loginEnabled: Bool { loginStatus == .enabled }
    var loginIsRegistered: Bool {
        let status = loginStatus
        return status == .enabled || status == .requiresApproval
    }
    // A first install may report notFound until its login item is registered.
    // Unknown/registered states stay quiet; saved intent/choice always wins.
    var shouldShowInitialSettings: Bool {
        guard !preferences.desiredEnabled, !preferences.loginChoiceMade else { return false }
        let status = loginStatus
        return status == .notRegistered || status == .notFound
    }

    // Call true after an explicit Enable succeeds. Call false on explicit
    // Disable, including cancellation of pending automatic restoration.
    // Quit / sleep / temporary failures clean up runtime state without calling
    // this method, so they do not silently erase the user's restoration intent.
    func rememberEnabled(_ value: Bool) { preferences.desiredEnabled = value }

    // Call only AFTER the user's explicit Enable succeeds, never on auto-resume.
    // The first successful Enable attempts the default login registration once.
    // Thereafter only the explicit login checkbox may change that registration,
    // including retries after errors / pending approval. This preserves both an
    // in-app opt-out and a later system-settings revocation across Enable clicks.
    // Login failure must not undo an already working hotkey listener.
    @discardableResult
    func registerAtUserEnable() -> String {
        if changingLoginRegistration {
            return StartupControllerError.operationInProgress.localizedDescription
        }
        if preferences.loginChoiceMade { return loginStatusText }
        preferences.loginChoiceMade = true
        do {
            try registerLogin()
            return loginStatusText
        } catch let error as StartupControllerError {
            return error.errorDescription ?? StartupControllerError.registrationFailed.localizedDescription
        } catch {
            return StartupControllerError.registrationFailed.localizedDescription
        }
    }

    // System login-item setting and resume intent are intentionally independent.
    // Turning login launch off does not alter the current listener or what the
    // user chose for a future manual launch; Disable is handled above.
    func setLoginEnabled(_ value: Bool) async throws {
        // Record the explicit choice even when the system rejects the change;
        // later Enable clicks must not silently override the user's selection.
        preferences.loginChoiceMade = true
        if value {
            try registerLogin()
        } else {
            try await unregisterLogin()
        }
    }

    private func registerLogin() throws {
        guard !changingLoginRegistration else { throw StartupControllerError.operationInProgress }
        changingLoginRegistration = true
        defer { changingLoginRegistration = false }
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw StartupControllerError.approvalRequired
        case .unknown: throw StartupControllerError.registrationFailed
        case .notRegistered, .notFound: break
        }
        do { try service.register() }
        catch {
            // A concurrent system setting change can make the call redundant.
            if service.status == .enabled { return }
            if service.status == .requiresApproval { throw StartupControllerError.approvalRequired }
            throw StartupControllerError.registrationFailed
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw StartupControllerError.approvalRequired
        default: throw StartupControllerError.registrationFailed
        }
    }

    private func unregisterLogin() async throws {
        guard !changingLoginRegistration else { throw StartupControllerError.operationInProgress }
        changingLoginRegistration = true
        defer { changingLoginRegistration = false }
        if service.status.isAbsent { return }
        do { try await service.unregister() }
        catch {
            if service.status.isAbsent { return }
            throw StartupControllerError.unregistrationFailed
        }
        guard service.status.isAbsent else {
            throw StartupControllerError.unregistrationFailed
        }
    }

    // The caller must stop a running helper before using the uninstall entry.
    // Disable restoration first, even when system unregistration fails. Only a
    // confirmed unregistration allows the installer to delete the app bundle.
    func unregisterAndClearOwnedPreferences() async throws {
        rememberEnabled(false)
        try await unregisterLogin()
        preferences.clearOwnedPreferences()
    }

    // Invoke before NSApplication creation or startup restoration. No UI is
    // constructed here; main-app unregister does not terminate this process.
    static func unregisterAndClear() async throws {
        try await StartupController().unregisterAndClearOwnedPreferences()
    }
}
