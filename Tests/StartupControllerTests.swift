import Foundation
import CoreFoundation

// Policy tests use in-memory preferences and a fake service. Persistence tests
// use only a random synthetic CFPreferences domain, including a child process.
// The script gives that domain a private temporary plist path, so the same real
// CFPreferences API can persist without writing the user's Preferences folder.
// No helper preference domain, login-item API, AppKit, network or device access.
@MainActor
private final class FakeStartupPreferences: StartupPreferenceStoring {
    var desiredEnabled = false
    var loginChoiceMade = false
    var clearCount = 0
    var unrelatedValue = "preserve"
    func clearOwnedPreferences() { clearCount += 1; desiredEnabled = false; loginChoiceMade = false }
}

private struct PrivateSyntheticError: Error, LocalizedError {
    var errorDescription: String? { "SENSITIVE-SYNTHETIC-ERROR" }
}

@MainActor
private final class FakeStartupLogin: StartupLoginManaging {
    var status: StartupLoginStatus = .notRegistered
    var registerCount = 0
    var unregisterCount = 0
    var statusAfterRegister: StartupLoginStatus? = .enabled
    var statusAfterUnregister: StartupLoginStatus? = .notRegistered
    var throwRegister = false
    var throwUnregister = false
    var onUnregister: (() -> Void)?
    func register() throws {
        registerCount += 1
        if let next = statusAfterRegister { status = next }
        if throwRegister { throw PrivateSyntheticError() }
    }
    func unregister() async throws {
        unregisterCount += 1
        onUnregister?()
        await Task.yield()
        if let next = statusAfterUnregister { status = next }
        if throwUnregister { throw PrivateSyntheticError() }
    }
}

@main
struct StartupControllerTests {
    @MainActor static var assertions = 0

    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--probe-preferences" {
            let domain = CommandLine.arguments[2]
            guard validSyntheticDomain(domain), Bundle.main.bundleIdentifier == domain else { exit(64) }
            let store = HelperStartupPreferences(domain: storageDomain(for: domain))
            guard store.desiredEnabled == (CommandLine.arguments[3] == "true"),
                  store.loginChoiceMade == (CommandLine.arguments[4] == "true") else { exit(2) }
            return
        }
        // Toggle decision: anything on, starting or waiting turns off; otherwise
        // start when a target runs, else keep the choice and wait for one.
        expect(StartupPolicy.enableAction(enabled: false, enabling: false, desired: false, targetRunning: true) == .start,
               "Turn On with a target running starts")
        expect(StartupPolicy.enableAction(enabled: false, enabling: false, desired: false, targetRunning: false) == .waitForTarget,
               "Turn On with no target running waits instead of failing")
        for (enabled, enabling, desired) in [(true, false, false), (false, true, false), (false, false, true), (true, true, true)] {
            for running in [true, false] {
                expect(StartupPolicy.enableAction(enabled: enabled, enabling: enabling, desired: desired,
                                                  targetRunning: running) == .disable,
                       "On, enabling or waiting always turns off")
            }
        }
        let prefs = FakeStartupPreferences()
        let login = FakeStartupLogin()
        let controller = StartupController(preferences: prefs, service: login)
        expect(!controller.desiredEnabled, "No preference means no auto-resume")
        expect(login.registerCount == 0 && login.unregisterCount == 0, "Initialization has no side effects")
        expect(controller.loginStatus == .notRegistered, "Status comes from service")
        expect(controller.loginStatusText.contains("Launch at Login: Off"), "Unregistered feedback")
        expect(!controller.loginEnabled && !controller.loginIsRegistered, "Unregistered is neither eligible nor registered")

        controller.rememberEnabled(true)
        expect(controller.desiredEnabled, "Explicit Enable remembers intent")
        expect(login.registerCount == 0, "Saving intent alone does not register")
        let reopened = StartupController(preferences: prefs, service: login)
        expect(reopened.desiredEnabled, "A new controller preserves enabled intent")
        expect(login.registerCount == 0, "Restoration construction does not register")
        expect(controller.registerAtUserEnable().contains("Launch at Login: On"), "User Enable registers")
        expect(login.registerCount == 1, "Exactly one registration")
        expect(prefs.loginChoiceMade, "First Enable records the one-time default choice")
        expect(controller.loginEnabled && controller.loginIsRegistered, "Enabled is eligible and registered")
        _ = controller.registerAtUserEnable()
        expect(login.registerCount == 1, "Already enabled registration is a no-op")

        controller.rememberEnabled(false)
        expect(!reopened.desiredEnabled, "Explicit Disable clears resume intent")
        expect(login.unregisterCount == 0, "Disable need not disable login launch")
        expect(controller.loginStatus == .enabled, "Login setting stays independent")
        controller.rememberEnabled(true)
        try await controller.setLoginEnabled(false)
        expect(controller.desiredEnabled, "Turning login launch off preserves resume intent")
        expect(login.unregisterCount == 1 && controller.loginStatus == .notRegistered, "Unregister confirmed")
        expect(prefs.loginChoiceMade, "Explicit login opt-out is remembered")
        let afterOptOut = login.registerCount
        expect(reopened.registerAtUserEnable().contains("Launch at Login: Off"), "Later Enable respects saved login opt-out")
        expect(login.registerCount == afterOptOut, "Reopening or Enable does not re-register after opt-out")
        try await controller.setLoginEnabled(false)
        expect(login.unregisterCount == 1, "Already unregistered is a no-op")

        login.status = .requiresApproval
        expect(!controller.loginEnabled && controller.loginIsRegistered, "Pending approval is registered but not enabled")
        expect(controller.loginStatusText.contains("Login Items"), "Approval feedback is actionable")
        expect(controller.registerAtUserEnable().contains("Login Items"), "Revoked approval is reported")
        expect(login.registerCount == 1, "Revoked consent never loops registration")
        await expectThrows(.approvalRequired) { try await controller.setLoginEnabled(true) }
        expect(login.registerCount == 1, "Settings action respects required approval")

        login.status = .notRegistered
        login.statusAfterRegister = .requiresApproval
        await expectThrows(.approvalRequired) { try await controller.setLoginEnabled(true) }
        expect(login.registerCount == 2, "New pending approval registration attempted once")
        login.status = .notRegistered
        login.statusAfterRegister = nil
        login.throwRegister = true
        // A separate synthetic first-choice state exercises initial failure.
        prefs.loginChoiceMade = false
        let errorText = controller.registerAtUserEnable()
        expect(errorText.contains("Couldn't turn on"), "Registration failure gets fixed feedback")
        expect(!errorText.contains("SENSITIVE"), "Raw registration errors are not exposed")
        expect(controller.desiredEnabled, "Login failure does not erase user intent")
        expect(prefs.loginChoiceMade, "Initial failure still consumes the default attempt")
        let failedAttempts = login.registerCount
        _ = controller.registerAtUserEnable()
        expect(login.registerCount == failedAttempts, "Later Enable does not silently retry failed registration")
        await expectThrows(.registrationFailed) { try await controller.setLoginEnabled(true) }

        login.statusAfterRegister = .enabled
        try await controller.setLoginEnabled(true)
        expect(controller.loginStatus == .enabled, "Concurrent enabled status resolves thrown redundant registration")
        login.throwRegister = false
        login.status = .notRegistered
        login.statusAfterRegister = .notRegistered
        await expectThrows(.registrationFailed) { try await controller.setLoginEnabled(true) }
        expect(controller.loginStatusText.contains("Launch at Login: Off"), "No false success when registration status did not change")

        login.status = .unknown
        let attempts = login.registerCount
        await expectThrows(.registrationFailed) { try await controller.setLoginEnabled(true) }
        expect(login.registerCount == attempts, "Unknown system state does not register")
        expect(controller.loginStatusText.contains("unavailable"), "Unknown status feedback")
        expect(!controller.loginEnabled && !controller.loginIsRegistered, "Unknown state never claims eligibility")
        login.status = .notFound
        login.statusAfterRegister = .enabled
        try await controller.setLoginEnabled(true)
        expect(controller.loginStatus == .enabled, "Explicit registration can repair absent record")

        login.onUnregister = {
            expect(controller.registerAtUserEnable().contains("updating"), "Registration cannot race an outstanding unregister")
        }
        let beforeBusy = login.registerCount
        try await controller.setLoginEnabled(false)
        expect(login.registerCount == beforeBusy, "Busy registration never reaches service")
        login.onUnregister = nil
        try await controller.setLoginEnabled(true)
        expect(controller.loginEnabled, "Mutation guard resets after async unregister")

        login.statusAfterUnregister = nil
        login.throwUnregister = true
        login.onUnregister = { expect(!controller.desiredEnabled, "Uninstall disables restoration before awaiting unregister") }
        await expectThrows(.unregistrationFailed) { try await controller.unregisterAndClearOwnedPreferences() }
        expect(!controller.desiredEnabled, "Failed uninstall leaves restore disabled")
        expect(prefs.clearCount == 0, "Failed unregister does not claim complete cleanup")
        expect(prefs.unrelatedValue == "preserve", "Unrelated preferences survive failure")

        login.throwUnregister = false
        await expectThrows(.unregistrationFailed) { try await controller.unregisterAndClearOwnedPreferences() }
        expect(prefs.clearCount == 0, "Successful call without confirmed state is rejected")
        login.statusAfterUnregister = .notRegistered
        login.throwUnregister = true
        try await controller.unregisterAndClearOwnedPreferences()
        expect(prefs.clearCount == 1, "Concurrent unregistration is accepted and owned key cleared")
        expect(!prefs.loginChoiceMade, "Uninstall clears the owned login choice key")
        expect(prefs.unrelatedValue == "preserve", "Cleanup never wipes unrelated preferences")
        let before = login.unregisterCount
        try await controller.unregisterAndClearOwnedPreferences()
        expect(login.unregisterCount == before, "Repeated cleanup does not invoke unregister again")
        expect(prefs.clearCount == 2, "Owned key cleanup is idempotent")
        expect(StartupController.preferencesDomain == "io.github.ashzene.toss", "Explicit helper-only preference domain")
        expect(StartupController.desiredEnabledKey.hasPrefix("startup."), "Owned preference key is namespaced")
        expect(StartupController.loginChoiceMadeKey.hasPrefix("startup."), "Login-choice key is namespaced")
        for desired in [false, true] {
            for choiceMade in [false, true] {
                for status: StartupLoginStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
                    prefs.desiredEnabled = desired
                    prefs.loginChoiceMade = choiceMade
                    login.status = status
                    let expected = !desired && !choiceMade && (status == .notRegistered || status == .notFound)
                    expect(controller.shouldShowInitialSettings == expected,
                           "Only an untouched first launch with an absent/unregistered login item shows settings")
                }
            }
        }
        try await testUninstallStatuses()
        let pureAssertions = assertions
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preference-domain" else {
            preconditionFailure("Run via test-startup-controller.sh with an isolated synthetic domain")
        }
        try testRealPersistence(domain: CommandLine.arguments[2])
        print("Startup controller: \(assertions) assertions passed (\(pureAssertions) pure policy + \(assertions - pureAssertions) synthetic-domain persistence); no helper-domain, login-item API, UI or device access.")
    }

    @MainActor private static func testUninstallStatuses() async throws {
        // Fresh install: neither onboarding nor login registration ever ran.
        for status: StartupLoginStatus in [.notRegistered, .notFound] {
            let prefs = FakeStartupPreferences()
            let login = FakeStartupLogin()
            login.status = status
            login.throwUnregister = true // An absent item must never call the API.
            let controller = StartupController(preferences: prefs, service: login)
            try await controller.unregisterAndClearOwnedPreferences()
            expect(login.unregisterCount == 0, "Never-registered uninstall skips the system API")
            expect(prefs.clearCount == 1, "Never-registered uninstall completes owned cleanup")
            expect(!prefs.desiredEnabled && !prefs.loginChoiceMade, "Fresh-install cleanup leaves no startup intent")
        }
        // Normal removal and a concurrent removal after a thrown API call both
        // succeed only when the resulting system state confirms absence.
        for initial: StartupLoginStatus in [.enabled, .requiresApproval] {
            for final: StartupLoginStatus in [.notRegistered, .notFound] {
                for throwsError in [false, true] {
                    let prefs = FakeStartupPreferences()
                    prefs.desiredEnabled = true
                    prefs.loginChoiceMade = true
                    let login = FakeStartupLogin()
                    login.status = initial
                    login.statusAfterUnregister = final
                    login.throwUnregister = throwsError
                    let controller = StartupController(preferences: prefs, service: login)
                    login.onUnregister = { expect(!prefs.desiredEnabled, "Restoration stops before system removal") }
                    try await controller.unregisterAndClearOwnedPreferences()
                    expect(login.unregisterCount == 1, "Registered uninstall calls system removal exactly once")
                    expect(prefs.clearCount == 1, "Confirmed absence permits owned cleanup")
                    expect(!prefs.loginChoiceMade && prefs.unrelatedValue == "preserve", "Only owned preferences are cleared")
                    try await controller.unregisterAndClearOwnedPreferences()
                    expect(login.unregisterCount == 1 && prefs.clearCount == 2, "Repeated uninstall remains idempotent")
                }
            }
        }
        // A real error, or an API returning without confirmed removal, must
        // still stop uninstall and retain the login-choice preference.
        for final: StartupLoginStatus in [.enabled, .requiresApproval, .unknown] {
            for throwsError in [false, true] {
                let prefs = FakeStartupPreferences()
                prefs.desiredEnabled = true
                prefs.loginChoiceMade = true
                let login = FakeStartupLogin()
                login.status = .enabled
                login.statusAfterUnregister = final
                login.throwUnregister = throwsError
                let controller = StartupController(preferences: prefs, service: login)
                await expectThrows(.unregistrationFailed) { try await controller.unregisterAndClearOwnedPreferences() }
                expect(login.unregisterCount == 1 && prefs.clearCount == 0, "Unconfirmed removal never clears preferences")
                expect(!prefs.desiredEnabled && prefs.loginChoiceMade, "Failed uninstall stops restoration but keeps the choice")
                expect(prefs.unrelatedValue == "preserve", "Failure preserves unrelated settings")
                // Failure must also release the mutation guard for a retry.
                login.statusAfterUnregister = .notFound
                try await controller.unregisterAndClearOwnedPreferences()
                expect(login.unregisterCount == 2 && prefs.clearCount == 1, "Retry after failure can finish removal")
            }
        }
    }

    private static func validSyntheticDomain(_ domain: String) -> Bool {
        let prefix = "io.github.ashzene.toss.startup-test."
        return domain.hasPrefix(prefix) && UUID(uuidString: String(domain.dropFirst(prefix.count))) != nil
    }

    private static func storageDomain(for domain: String) -> String {
        precondition(validSyntheticDomain(domain))
        guard let folder = ProcessInfo.processInfo.environment["TOSS_TEST_PREFERENCES_DIRECTORY"] else {
            return domain // Preserve the standalone, own-bundle-domain fixture.
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
        let fixtureDirectory = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        precondition(directory.lastPathComponent == "Preferences" &&
                     directory.deletingLastPathComponent() == fixtureDirectory)
        return directory.appendingPathComponent(domain).path
    }

    @MainActor private static func testRealPersistence(domain: String) throws {
        precondition(validSyntheticDomain(domain) && domain != StartupController.preferencesDomain)
        expect(Bundle.main.bundleIdentifier == domain, "Real Foundation fixture keeps its OWN synthetic bundle ID")
        let storage = storageDomain(for: domain)
        let applicationID = storage as CFString
        let unrelatedKey = "synthetic.unrelated"
        func get(_ key: String) -> CFPropertyList? {
            CFPreferencesCopyValue(key as CFString, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        func set(_ key: String, _ value: CFPropertyList?) {
            CFPreferencesSetValue(key as CFString, value, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            precondition(CFPreferencesSynchronize(applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        }
        defer {
            for key in [StartupController.desiredEnabledKey, StartupController.loginChoiceMadeKey, unrelatedKey] {
                set(key, nil)
            }
        }
        func childSees(_ enabled: Bool, _ choice: Bool) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--probe-preferences", domain, String(enabled), String(choice)]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            expect(process.terminationReason == .exit && process.terminationStatus == 0,
                   "A fresh process reads the synchronized values from the same own-bundle domain")
        }
        expect(get(StartupController.desiredEnabledKey) == nil, "Fresh synthetic domain has no restore key")
        expect(get(StartupController.loginChoiceMadeKey) == nil, "Fresh synthetic domain has no login-choice key")
        let store = HelperStartupPreferences(domain: storage)
        expect(!store.desiredEnabled && !store.loginChoiceMade, "Missing real preferences default to false")
        set(unrelatedKey, "preserve" as CFString)
        store.desiredEnabled = true
        expect(store.desiredEnabled && !store.loginChoiceMade, "First persisted key is independent")
        expect(get(StartupController.desiredEnabledKey).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true,
               "Boolean is stored as CFBoolean rather than a string")
        store.loginChoiceMade = true
        let reopened = HelperStartupPreferences(domain: storage)
        expect(reopened.desiredEnabled && reopened.loginChoiceMade, "A new adapter reads both persisted keys")
        try childSees(true, true)
        store.desiredEnabled = false
        expect(!reopened.desiredEnabled && reopened.loginChoiceMade, "Persisted Disable preserves login choice")
        try childSees(false, true)
        store.loginChoiceMade = false
        try childSees(false, false)

        // Wrong-typed values must never silently authorize startup behavior.
        for key in [StartupController.desiredEnabledKey, StartupController.loginChoiceMadeKey] {
            for value: CFPropertyList in ["true" as CFString, 1 as NSNumber, ["true"] as NSArray] {
                set(key, value)
                expect(key == StartupController.desiredEnabledKey ? !store.desiredEnabled : !store.loginChoiceMade,
                       "Non-Boolean preferences fail closed")
            }
        }
        store.desiredEnabled = true
        store.loginChoiceMade = true
        store.clearOwnedPreferences()
        expect(get(StartupController.desiredEnabledKey) == nil, "Cleanup removes restore key")
        expect(get(StartupController.loginChoiceMadeKey) == nil, "Cleanup removes login-choice key")
        expect((get(unrelatedKey) as? String) == "preserve", "Cleanup preserves unrelated domain keys")
        expect(!reopened.desiredEnabled && !reopened.loginChoiceMade, "Cleanup is visible to another adapter")
        try childSees(false, false)
        store.clearOwnedPreferences()
        expect((get(unrelatedKey) as? String) == "preserve", "Repeated cleanup still preserves unrelated keys")
    }

    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    @MainActor private static func expectThrows(_ expected: StartupControllerError,
                                               _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch let error as StartupControllerError { expect(error == expected, "Fixed expected error") }
        catch { preconditionFailure("Raw error escaped: \(type(of: error))") }
    }
}
