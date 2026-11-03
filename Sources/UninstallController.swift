import Foundation
import Darwin

enum UninstallPolicy {
    // Keep Accessibility permission so reinstalling Toss works immediately.
    static let resetPermissions = false
    static let domain = "io.github.ashzene.toss"
    static let permissionServices = ["Accessibility", "PostEvent", "ListenEvent"]
    // Exactly the non-app operands of both legacy uninstall scripts. The app
    // operand is handled separately by recycling Bundle.main.bundleURL.
    static let relativePaths = [
        "Library/Application Support/Toss",
        "Library/Caches/Toss"
    ]
}

@MainActor
protocol UninstallPreferenceClearing {
    func removeObject(forKey key: String)
    func removePersistentDomain(forName domainName: String)
    func synchronize() -> Bool
}
extension UserDefaults: UninstallPreferenceClearing {}

@MainActor
enum UninstallPreferences {
    enum CleanupError: Error { case wrongDomain, syncFailed }
    static func clearDomain(_ domain: String, in defaults: UninstallPreferenceClearing) throws {
        guard domain == UninstallPolicy.domain else { throw CleanupError.wrongDomain }
        defaults.removePersistentDomain(forName: domain)
        guard defaults.synchronize() else { throw CleanupError.syncFailed }
    }
}

// All effects are mandatory injections: constructing/testing the coordinator
// cannot discover a real home, reset TCC, unregister a login item or trash an app.
@MainActor
final class UninstallController {
    struct Actions {
        var stopCapture: () async throws -> Void
        var stopSetup: () async throws -> Void
        var unregisterLogin: () async throws -> Void
        var clearOwnedPreferences: () throws -> Void
        var removeData: (String) async throws -> Void
        var clearDomain: (String) throws -> Void
        var resetPermission: (String, String) async throws -> Void
        var recycle: (URL) async throws -> Void
        var reveal: (URL) throws -> Void
        var showManualRemoval: (String) throws -> Void
        var terminate: () -> Void
    }
    struct Result: Equatable {
        var failedSteps: [String] = []
        var recycled = false
    }
    private let actions: Actions
    private let app: URL
    private let resetPermissions: Bool
    private var started = false
    private(set) var result: Result?

    init(app: URL, resetPermissions: Bool = UninstallPolicy.resetPermissions, actions: Actions) {
        self.app = app
        self.resetPermissions = resetPermissions
        self.actions = actions
    }

    @discardableResult
    func run() async -> Result? {
        guard !started else { return result }
        started = true
        // Capture localized copy before erasing the saved language preference.
        let manualRemoval = L("Drag Toss to the Trash", "请把 Toss 拖进废纸篓")
        var outcome = Result()
        func attempt(_ step: String, _ operation: () async throws -> Void) async {
            do { try await operation() }
            catch { outcome.failedSteps.append(step) }
        }
        await attempt("stopCapture", actions.stopCapture)
        await attempt("stopSetup", actions.stopSetup)
        await attempt("unregisterLogin", actions.unregisterLogin)
        await attempt("clearOwnedPreferences") { try actions.clearOwnedPreferences() }
        for path in UninstallPolicy.relativePaths {
            await attempt("remove:\(path)") { try await actions.removeData(path) }
        }
        await attempt("clearDomain") { try actions.clearDomain(UninstallPolicy.domain) }
        if resetPermissions {
            for service in UninstallPolicy.permissionServices {
                await attempt("reset:\(service)") { try await actions.resetPermission(service, UninstallPolicy.domain) }
            }
        }
        do { try await actions.recycle(app); outcome.recycled = true }
        catch {
            outcome.failedSteps.append("recycle")
            await attempt("reveal") { try actions.reveal(app) }
            await attempt("manualRemoval") { try actions.showManualRemoval(manualRemoval) }
        }
        result = outcome
        actions.terminate()
        return outcome
    }
}

// Delete only an allowlisted root. Walk from / using directory descriptors so
// neither a symlink in an ancestor (including Library) nor one inside a root
// can redirect removal. unlinkat removes a symlink itself, never its target.
struct UninstallDataRemover {
    let home: URL
    enum RemovalError: Error { case pathNotAllowed, invalidHome, changedDirectory }

    func remove(_ relativePath: String) throws {
        guard UninstallPolicy.relativePaths.contains(relativePath) else { throw RemovalError.pathNotAllowed }
        guard home.isFileURL, home.path.hasPrefix("/"), home.path != "/",
              !home.pathComponents.contains("..") else { throw RemovalError.invalidHome }
        let components = home.pathComponents.filter { $0 != "/" } + relativePath.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return }
                throw posixError()
            }
            close(directory)
            directory = next
        }
        try removeEntry(components.last!, from: directory)
    }

    private func removeEntry(_ name: String, from parent: Int32) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        if info.st_mode & S_IFMT != S_IFDIR {
            if unlinkat(parent, name, 0) != 0 && errno != ENOENT { throw posixError() }
            return
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0 else { throw posixError() }
        guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw RemovalError.changedDirectory }
        let enumeration = dup(directory)
        guard enumeration >= 0 else { throw posixError() }
        guard let stream = fdopendir(enumeration) else { close(enumeration); throw posixError() }
        defer { closedir(stream) }
        var firstError: Error?
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { firstError = firstError ?? posixError() }
                break
            }
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard child != ".", child != ".." else { continue }
            // A failed child must not stop cleanup of its siblings.
            do { try removeEntry(child, from: directory) }
            catch { firstError = firstError ?? error }
        }
        if unlinkat(parent, name, AT_REMOVEDIR) != 0 && errno != ENOENT { firstError = firstError ?? posixError() }
        if let firstError { throw firstError }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
