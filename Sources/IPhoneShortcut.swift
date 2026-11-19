import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Network
import OSLog
import SystemConfiguration

private let iPhoneShortcutLog = Logger(subsystem: "io.github.ashzene.toss", category: "iPhoneShortcut")

struct IPhoneShortcutSettings: Codable, Equatable {
    static let key = "Toss.iPhoneShortcut"
    let deviceHash: String
    let secret: String
    let destination: String
    private let disabled: Bool?
    private var automaticImportPending: Bool?

    var isEnabled: Bool { disabled != true }
    var needsAutomaticImport: Bool { isEnabled && automaticImportPending == true }

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.secret.utf8.count == 64 else { return nil }
        return settings
    }

    init(deviceHash: String, destination: String, previous: Self?, disabled: Bool = false,
         automaticImport: Bool = false) {
        self.deviceHash = deviceHash
        self.destination = destination
        self.disabled = disabled ? true : nil
        let reusable = previous.flatMap { !disabled && $0.isEnabled && $0.deviceHash == deviceHash ? $0 : nil }
        self.secret = reusable?.secret
            ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        automaticImportPending = !disabled && (automaticImport || reusable?.needsAutomaticImport == true) ? true : nil
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }

    static func markImportPrepared(secret: String, in defaults: UserDefaults = .standard) throws {
        guard var settings = load(from: defaults), settings.secret == secret, settings.needsAutomaticImport else { return }
        settings.automaticImportPending = nil
        try settings.save(to: defaults)
    }
}

@MainActor
final class IPhoneShortcutImport {
    nonisolated static let name = "Toss iPhone"
    static let setupQuestion = "粘贴 Toss 复制的配置 / Paste setup from Toss"
    static var bundledFile: URL? { Bundle.main.url(forResource: name, withExtension: "shortcut") }

    struct FormElement {
        let role: String
        var labels: [String] = []
    }

    enum FormAction: Equatable {
        case openSetup(Int)
        case fillSetup(Int)
    }

    // Match the Shortcuts app's language, which can differ from Toss's language.
    private static let formLabels: (previewButtons: Set<String>, setupTitles: Set<String>, duplicateMessages: Set<String>,
                                    replaceButtons: Set<String>, keepBothButtons: Set<String>) = {
        var buttons: Set<String> = ["Add Shortcut…", "添加快捷指令…", "加入捷徑⋯"]
        var titles: Set<String> = ["%@ Setup", "%@设置", "%@設定"]
        let duplicateKey = "You already have a shortcut named “%@”."
        var duplicateMessages: Set<String> = [duplicateKey, "你已经有名为“%@”的快捷指令。", "你已擁有一個名為「%@」的捷徑。"]
        var replaceButtons: Set<String> = ["Replace", "替换", "取代"]
        var keepBothButtons: Set<String> = ["Keep Both", "保留两者", "兩者皆保留"]
        let framework = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/WorkflowUI.framework")
        if let bundle = Bundle(url: framework) {
            buttons.insert(bundle.localizedString(forKey: "ADD_SHORTCUT_BUTTON_WITH_IMPORT", value: "Add Shortcut…", table: nil))
            titles.insert(bundle.localizedString(forKey: "%@ Setup", value: nil, table: nil))
            if let file = bundle.url(forResource: "Localizable", withExtension: "loctable"),
               let data = try? Data(contentsOf: file),
               let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                for case let language as [String: Any] in table.values {
                    if let button = language["ADD_SHORTCUT_BUTTON_WITH_IMPORT"] as? String { buttons.insert(button) }
                    if let title = language["%@ Setup"] as? String { titles.insert(title) }
                    if let message = language[duplicateKey] as? String { duplicateMessages.insert(message) }
                    if let replace = language["Replace"] as? String { replaceButtons.insert(replace) }
                    if let keep = language["Keep Both"] as? String { keepBothButtons.insert(keep) }
                }
            }
        }
        func withShortcutName(_ format: String) -> String {
            format.replacingOccurrences(of: "%1$@", with: name).replacingOccurrences(of: "%@", with: name)
        }
        return (Set(buttons.filter { $0.hasSuffix("…") || $0.hasSuffix("⋯") || $0.hasSuffix("...") }),
                Set(titles.map(withShortcutName)), Set(duplicateMessages.map(withShortcutName)), replaceButtons, keepBothButtons)
    }()

    private var autofill: Task<Void, Never>?

    func cancel() {
        autofill?.cancel()
        autofill = nil
    }

    func open(_ file: URL, setup: String, isCurrent: @escaping () -> Bool,
              onAdded: @escaping () -> Void, onFailure: @escaping () -> Void) {
        cancel()
        let application = URL(fileURLWithPath: "/System/Applications/Shortcuts.app", isDirectory: true)
        autofill = Task {
            let existingIDs = await Self.installedIDs()
            guard !Task.isCancelled, isCurrent() else { return }
            if let existingIDs, AXIsProcessTrusted(),
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.shortcuts").first {
                let ax = AXUIElementCreateApplication(running.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.25)
                if let window = Self.element(ax, kAXFocusedWindowAttribute),
                   let (action, field) = Self.findForm(in: window, canOpenSetup: false),
                   case .fillSetup = action,
                   Self.setupMatches(setup, field: field) {
                    iPhoneShortcutLog.notice("Resumed the open iPhone shortcut setup in Shortcuts.")
                    await Self.authorizeAfterAdding(to: existingIDs, shortcuts: running, window: window,
                                                   isCurrent: isCurrent, onAdded: onAdded)
                    return
                }
            }
            let shortcuts: NSRunningApplication
            do {
                shortcuts = try await NSWorkspace.shared.open([file], withApplicationAt: application,
                                                               configuration: NSWorkspace.OpenConfiguration())
            } catch {
                if !Task.isCancelled, isCurrent() { onFailure() }
                return
            }
            iPhoneShortcutLog.notice("Opened the iPhone shortcut setup in Shortcuts.")

            // Advance the preview to the import form, leaving the final Add Shortcut button for the user.
            let ax = AXUIElementCreateApplication(shortcuts.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            let deadline = ContinuousClock.now + .seconds(90)
            var canOpenSetup = true
            while !Task.isCancelled, isCurrent(), !shortcuts.isTerminated, ContinuousClock.now < deadline {
                if shortcuts.isActive, AXIsProcessTrusted(),
                   let window = Self.element(ax, kAXFocusedWindowAttribute),
                   let (action, control) = Self.findForm(in: window, canOpenSetup: canOpenSetup) {
                    switch action {
                    case .openSetup:
                        if AXUIElementPerformAction(control, kAXPressAction as CFString) == .success { canOpenSetup = false }
                    case .fillSetup:
                        if Self.fillSetup(setup, field: control) {
                            if let existingIDs {
                                await Self.authorizeAfterAdding(to: existingIDs, shortcuts: shortcuts, window: window,
                                                               isCurrent: isCurrent, onAdded: onAdded)
                            }
                            return
                        }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
    }

    private static func authorizeAfterAdding(to existingIDs: Set<UUID>, shortcuts: NSRunningApplication, window: AXUIElement,
                                             isCurrent: () -> Bool, onAdded: () -> Void) async {
        let ax = AXUIElementCreateApplication(shortcuts.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var libraryDeadline: ContinuousClock.Instant?
        while !Task.isCancelled, isCurrent(), !shortcuts.isTerminated {
            if findForm(in: window, canOpenSetup: false) != nil || hasDuplicateConfirmation(in: ax) {
                // Start the library timeout once the import and replacement prompts close.
                libraryDeadline = nil
            } else {
                let now = ContinuousClock.now
                let deadline = libraryDeadline ?? now + .seconds(10)
                libraryDeadline = deadline
                guard now < deadline else { return }
                if let ids = await installedIDs() {
                    guard !Task.isCancelled, isCurrent(), !shortcuts.isTerminated else { return }
                    let added = ids.subtracting(existingIDs)
                    if !added.isEmpty {
                        guard added.count == 1, let id = added.first else { return }
                        onAdded()
                        requestAuthorization(for: id)
                        return
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
        }
    }

    nonisolated static func tossShortcutIDs(in listing: String) -> Set<UUID> {
        let prefix = name + " ("
        return Set(listing.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(prefix), line.hasSuffix(")") else { return nil }
            return UUID(uuidString: String(line.dropFirst(prefix.count).dropLast()))
        })
    }

    private nonisolated static func installedIDs() async -> Set<UUID>? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list", "--show-identifiers"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            do { try process.run() } catch { return nil }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else { return nil }
            return tossShortcutIDs(in: listing)
        }.value
    }

    private static func requestAuthorization(for shortcutID: UUID) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutID.uuidString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(IPhoneShortcutHandshake.authorizationSuffix.utf8))
            try input.fileHandleForWriting.close()
            try process.run()
            iPhoneShortcutLog.notice("Started the first-run authorization check.")
        } catch {
            iPhoneShortcutLog.error("Could not start the first-run authorization check.")
        }
    }

    static func formAction(role: String, elements: [FormElement], canOpenSetup: Bool) -> FormAction? {
        let labels = elements.filter { $0.role == kAXStaticTextRole || $0.role == "AXHeading" }.flatMap(\.labels)
        if role == kAXSheetRole {
            guard labels.contains(setupQuestion), labels.contains(where: formLabels.setupTitles.contains) else { return nil }
            let fields = elements.indices.filter { elements[$0].role == kAXTextAreaRole || elements[$0].role == kAXTextFieldRole }
            guard fields.count == 1, let field = fields.first else { return nil }
            return .fillSetup(field)
        }
        guard role == kAXWindowRole, canOpenSetup, labels.contains(name) else { return nil }
        let buttons = elements.indices.filter {
            elements[$0].role == kAXButtonRole && elements[$0].labels.contains(where: formLabels.previewButtons.contains)
        }
        guard buttons.count == 1, let button = buttons.first else { return nil }
        return .openSetup(button)
    }

    static func isDuplicateConfirmation(_ elements: [FormElement]) -> Bool {
        let message = elements.contains { element in
            (element.role == kAXStaticTextRole || element.role == "AXHeading") &&
                element.labels.contains(where: formLabels.duplicateMessages.contains)
        }
        let buttons = Set(elements.filter { $0.role == kAXButtonRole }.flatMap(\.labels))
        return message && !buttons.isDisjoint(with: formLabels.replaceButtons) && !buttons.isDisjoint(with: formLabels.keepBothButtons)
    }

    private static func hasDuplicateConfirmation(in app: AXUIElement) -> Bool {
        guard let window = element(app, kAXFocusedWindowAttribute), let nodes = formElements(in: window) else { return false }
        return isDuplicateConfirmation(nodes.map(\.1))
    }

    private static func findForm(in window: AXUIElement, canOpenSetup: Bool) -> (FormAction, AXUIElement)? {
        guard let windowRole = attribute(window, kAXRoleAttribute) as? String else { return nil }
        var form = window
        if windowRole == kAXWindowRole {
            let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let sheets = children.filter { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
            guard sheets.count <= 1 else { return nil }
            if let sheet = sheets.first { form = sheet }
        }
        guard let role = attribute(form, kAXRoleAttribute) as? String,
              role == kAXSheetRole || (role == kAXWindowRole && canOpenSetup) else { return nil }
        if role == kAXWindowRole, let title = attribute(form, kAXTitleAttribute) as? String,
           !title.isEmpty, title != name { return nil }
        guard let nodes = formElements(in: form),
              let action = formAction(role: role, elements: nodes.map(\.1), canOpenSetup: canOpenSetup) else { return nil }
        switch action {
        case .openSetup(let index), .fillSetup(let index): return (action, nodes[index].0)
        }
    }

    private static func formElements(in root: AXUIElement) -> [(AXUIElement, FormElement)]? {
        var pending = [root]
        var nodes: [(AXUIElement, FormElement)] = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            if let nodeRole = attribute(node, kAXRoleAttribute) as? String {
                let labelRole = nodeRole == kAXStaticTextRole || nodeRole == "AXHeading" || nodeRole == kAXButtonRole
                let labels = labelRole ? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { attribute(node, $0) as? String } : []
                nodes.append((node, FormElement(role: nodeRole, labels: labels)))
            }
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard visited + pending.count + children.count <= 120 else { return nil }
            pending.append(contentsOf: children)
        }
        return nodes
    }

    private static func fillSetup(_ setup: String, field: AXUIElement) -> Bool {
        if setupMatches(setup, field: field) { return true }
        let current = attribute(field, kAXValueAttribute) as? String
        guard current?.isEmpty != false else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, setup as CFString) == .success else { return false }
        return setupMatches(setup, field: field)
    }

    private static func setupMatches(_ setup: String, field: AXUIElement) -> Bool {
        let current = attribute(field, kAXValueAttribute) as? String
        return current == setup || current == setup + "\n"
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

struct IPhoneShortcutHandshake {
    static let port: UInt16 = 54963
    static let challengePath = "/toss/iphone/challenge"
    static let authorizationSuffix = "/authorize"
    static let authorizationPath = challengePath + authorizationSuffix
    static let capturePath = "/toss/iphone/capture/"
    private static let lifetime: TimeInterval = 25
    enum Purpose: Equatable { case capture, authorization }
    private struct Challenge {
        let expiresAt: TimeInterval
        let purpose: Purpose
    }
    private let secret: String
    private var challenges: [String: Challenge] = [:]

    init(secret: String) { self.secret = secret }

    static var localAddress: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = name + ".local"
        parts.port = Int(port)
        return parts.url?.absoluteString
    }

    mutating func challenge(at now: TimeInterval, purpose: Purpose = .capture) -> String? {
        challenges = challenges.filter { $0.value.expiresAt > now }
        guard challenges.count < 32 else { return nil }
        let nonce = UUID().uuidString.lowercased()
        challenges[nonce] = Challenge(expiresAt: now + Self.lifetime, purpose: purpose)
        return nonce
    }

    mutating func authorize(path: String, at now: TimeInterval) -> Purpose? {
        guard path.hasPrefix(Self.capturePath) else { return nil }
        let parts = path.dropFirst(Self.capturePath.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 36, parts[1].utf8.count == 64 else {
            iPhoneShortcutLog.notice("Capture request has an invalid challenge or proof format.")
            return nil
        }
        guard let challenge = challenges[String(parts[0])], now < challenge.expiresAt else {
            iPhoneShortcutLog.notice("Capture challenge expired or was already used.")
            return nil
        }

        guard parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            iPhoneShortcutLog.notice("Capture proof is not hexadecimal.")
            return nil
        }
        let incoming = parts[1].lowercased().utf8
        let message = "Toss iPhone \(parts[0]) \(secret)"
        func difference(for text: String) -> UInt8 {
            let digest = SHA256.hash(data: Data(text.utf8))
            let proof = digest.map { String(format: "%02x", $0) }.joined()
            return zip(proof.utf8, incoming).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        }
        // Shortcuts on iPhone can include one trailing LF when it hashes the pasted setup.
        // Both spellings still cover the same single-use challenge and the full pairing secret.
        guard min(difference(for: message), difference(for: message + "\n")) == 0 else {
            iPhoneShortcutLog.notice("Capture proof did not match the current pairing.")
            return nil
        }
        challenges.removeValue(forKey: String(parts[0]))
        return challenge.purpose
    }
}

@MainActor
final class IPhoneShortcutReceiver {
    enum Admission {
        case accepted
        case unavailable(String)
    }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var secret: String?
    private var handshake: IPhoneShortcutHandshake?
    private var connections: [UUID: NWConnection] = [:]
    private var trigger: (() -> Admission)?
    private static let headerEnd = Data([13, 10, 13, 10])
    private static let headerLimit = 4_096

    init(port: NWEndpoint.Port = NWEndpoint.Port(rawValue: IPhoneShortcutHandshake.port)!) {
        self.port = port
    }

    func start(secret: String, onFailure: @escaping () -> Void, trigger: @escaping () -> Admission) throws {
        self.trigger = trigger
        if self.secret == secret, listener != nil { return }
        stop()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        self.secret = secret
        self.handshake = IPhoneShortcutHandshake(secret: secret)
        self.trigger = trigger
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                if case .failed = state {
                    self.stop()
                    onFailure()
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.begin(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        secret = nil
        handshake = nil
        trigger = nil
    }

    private func begin(_ connection: NWConnection) {
        guard connections.count < 12 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.connections[id] != nil else { return }
            iPhoneShortcutLog.notice("Phone connection timed out.")
            self.close(id)
        }
        receive(id, buffered: Data())
    }

    private func receive(_ id: UUID, buffered: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit - buffered.count) {
            [weak self] bytes, _, finished, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var request = buffered
                if let bytes { request.append(bytes) }
                if let end = request.range(of: Self.headerEnd), error == nil {
                    self.handle(id, header: request.prefix(upTo: end.lowerBound))
                } else if finished || error != nil || request.count >= Self.headerLimit {
                    if !request.isEmpty { iPhoneShortcutLog.notice("Phone connection ended before completing its HTTP headers.") }
                    self.close(id)
                } else {
                    self.receive(id, buffered: request)
                }
            }
        }
    }

    private func handle(_ id: UUID, header: Data) {
        guard let text = String(data: header, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else { close(id); return }
        let fields = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(fields[2]) else {
            iPhoneShortcutLog.notice("Phone sent an unsupported HTTP request line.")
            close(id)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let path = String(fields[1])
        if fields[0] == "GET", path == IPhoneShortcutHandshake.challengePath || path == IPhoneShortcutHandshake.authorizationPath {
            let purpose: IPhoneShortcutHandshake.Purpose = path == IPhoneShortcutHandshake.authorizationPath ? .authorization : .capture
            if let challenge = handshake?.challenge(at: now, purpose: purpose) { respond(id, status: "200 OK", body: challenge) }
            else { respond(id, status: "429 Too Many Requests") }
        } else if fields[0] == "POST", path.hasPrefix(IPhoneShortcutHandshake.capturePath) {
            guard let purpose = handshake?.authorize(path: path, at: now), let trigger else {
                respond(id, status: "403 Forbidden")
                return
            }
            if purpose == .authorization {
                iPhoneShortcutLog.notice("First-run authorization check succeeded.")
                respond(id, status: "204 No Content")
                return
            }
            switch trigger() {
            case .accepted: respond(id, status: "204 No Content")
            case .unavailable(let message): respond(id, status: "409 Conflict", body: message)
            }
        } else { respond(id, status: "404 Not Found") }
    }

    private func respond(_ id: UUID, status: String, body: String = "") {
        guard let connection = connections[id] else { return }
        iPhoneShortcutLog.notice("Phone trigger reply: \(status, privacy: .public)")
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
