import ApplicationServices
import CryptoKit
import Foundation
import Network

@main @MainActor
struct IPhoneShortcutTests {
    private static let secret = String(repeating: "a", count: 64)

    private static func capturePath(_ challenge: String, secret: String) -> String {
        let digest = SHA256.hash(data: Data("Toss iPhone \(challenge) \(secret)".utf8))
        let proof = digest.map { String(format: "%02x", $0) }.joined()
        return IPhoneShortcutHandshake.capturePath + challenge + "/" + proof
    }

    static func main() async throws {
        var handshake = IPhoneShortcutHandshake(secret: secret)
        let challenge = handshake.challenge(at: 10)!
        precondition(handshake.authorize(path: capturePath(challenge, secret: "other"), at: 11) == nil)
        let path = capturePath(challenge, secret: secret)
        precondition(handshake.authorize(path: path + "/extra", at: 11) == nil)
        precondition(handshake.authorize(path: path, at: 11) == .capture)
        precondition(handshake.authorize(path: path, at: 11) == nil, "A request must not capture twice")
        let stale = handshake.challenge(at: 12)!
        precondition(handshake.authorize(path: capturePath(stale, secret: secret), at: 37) == nil, "Expired challenge must not capture")
        for _ in 0..<32 { precondition(handshake.challenge(at: 38) != nil) }
        precondition(handshake.challenge(at: 38) == nil)
        precondition(handshake.challenge(at: 63) != nil, "Expired challenges release capacity")

        let original = IPhoneShortcutSettings(deviceHash: "first", destination: "chatgpt", previous: nil)
        let newDestination = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: original)
        let newPhone = IPhoneShortcutSettings(deviceHash: "second", destination: "claude", previous: newDestination)
        let disabled = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: newDestination, disabled: true)
        let reenabled = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: disabled)
        precondition(original.secret == newDestination.secret && newDestination.destination == "claude")
        precondition(original.secret != newPhone.secret)
        precondition(!disabled.isEnabled && original.secret != disabled.secret)
        precondition(reenabled.isEnabled && reenabled.secret != original.secret && reenabled.secret != disabled.secret)
        let domain = "test.toss.iphone-shortcut." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try newDestination.save(to: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults) == newDestination)
        defaults.set(Data("{\"deviceHash\":\"first\",\"destination\":\"chatgpt\",\"secret\":\"\(secret)\"}".utf8),
                     forKey: IPhoneShortcutSettings.key)
        let migrated = IPhoneShortcutSettings.load(from: defaults)
        precondition(migrated?.isEnabled == true && migrated?.secret == secret)
        precondition(migrated?.needsAutomaticImport == false, "An upgrade must preserve an existing shortcut")
        let pending = IPhoneShortcutSettings(deviceHash: "first", destination: "chatgpt", previous: nil,
                                             automaticImport: true)
        try pending.save(to: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsAutomaticImport == true)
        let retry = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: pending)
        precondition(retry.needsAutomaticImport && retry.secret == pending.secret)
        try retry.save(to: defaults)
        try IPhoneShortcutSettings.markImportPrepared(secret: "stale", in: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsAutomaticImport == true)
        try IPhoneShortcutSettings.markImportPrepared(secret: pending.secret, in: defaults)
        let prepared = IPhoneShortcutSettings.load(from: defaults)
        precondition(prepared?.needsAutomaticImport == false && prepared?.destination == "claude"
                     && prepared?.secret == pending.secret)
        try disabled.save(to: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.isEnabled == false)
        defaults.removeObject(forKey: IPhoneShortcutSettings.key)
        precondition(IPhoneShortcutSettings.load(from: defaults) == nil)

        typealias Import = IPhoneShortcutImport
        let heading = Import.FormElement(role: "AXHeading", labels: [Import.name])
        let next = Import.FormElement(role: kAXButtonRole, labels: ["添加快捷指令…"])
        let add = Import.FormElement(role: kAXButtonRole, labels: ["添加快捷指令"])
        precondition(Import.formAction(role: kAXWindowRole, elements: [heading, next], canOpenSetup: true) == .openSetup(1))
        precondition(Import.formAction(role: kAXWindowRole, elements: [heading, next], canOpenSetup: false) == nil)
        precondition(Import.formAction(role: kAXWindowRole, elements: [heading, add], canOpenSetup: true) == nil)
        let differentShortcut = Import.FormElement(role: "AXHeading", labels: ["Toss iPhone QA"])
        precondition(Import.formAction(role: kAXWindowRole, elements: [differentShortcut, next], canOpenSetup: true) == nil)
        let title = Import.FormElement(role: kAXStaticTextRole, labels: ["Toss iPhone设置"])
        let question = Import.FormElement(role: "AXHeading", labels: [Import.setupQuestion])
        let field = Import.FormElement(role: kAXTextAreaRole)
        let form = [title, question, field, add]
        precondition(Import.formAction(role: kAXSheetRole, elements: form, canOpenSetup: false) == .fillSetup(2))
        precondition(Import.formAction(role: kAXSheetRole, elements: [title, field], canOpenSetup: true) == nil)
        precondition(Import.formAction(role: kAXSheetRole, elements: form + [field], canOpenSetup: true) == nil)
        let duplicate = Import.FormElement(role: kAXStaticTextRole, labels: ["你已经有名为“Toss iPhone”的快捷指令。"])
        let replace = Import.FormElement(role: kAXButtonRole, labels: ["替换"])
        let keep = Import.FormElement(role: kAXButtonRole, labels: ["保留两者"])
        precondition(Import.isDuplicateConfirmation([duplicate, replace, keep]), "Wait for the real Shortcuts replacement alert")
        let otherDuplicate = Import.FormElement(role: kAXStaticTextRole, labels: ["你已经有名为“Other”的快捷指令。"])
        precondition(!Import.isDuplicateConfirmation([otherDuplicate, replace, keep]), "Ignore replacement alerts for unrelated shortcuts")
        let existingID = UUID(), newerID = UUID(), unrelatedID = UUID()
        let listing = "Toss iPhone (\(existingID))\nToss iPhone (\(newerID))\nToss iPhone QA (\(unrelatedID))\nToss iPhone (invalid)\n"
        precondition(Import.tossShortcutIDs(in: listing) == [existingID, newerID], "Same-name shortcuts must remain distinguishable by ID")

        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 55_000...59_000))!
        let receiver = IPhoneShortcutReceiver(port: port)
        defer { receiver.stop() }
        var admitted = 0
        var macChecks = 0, remoteEvents = 0
        precondition(!IPhoneShortcutReceiver.isRemotePeer(.ipv4(.loopback)))
        precondition(!IPhoneShortcutReceiver.isRemotePeer(.ipv6(.loopback)))
        precondition(!IPhoneShortcutReceiver.isRemotePeer(NWEndpoint.Host("::ffff:127.0.0.1")))
        precondition(IPhoneShortcutReceiver.isRemotePeer(NWEndpoint.Host("192.0.2.47")))
        try receiver.start(secret: secret, onFailure: { preconditionFailure("Receiver did not start") },
                           onLocalAuthorization: { macChecks += 1 }, onProofMismatch: { remoteEvents += 1 },
                           onRemoteVerified: { remoteEvents += 1 }) {
            admitted += 1
            return .accepted
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let base = "http://127.0.0.1:\(port.rawValue)"
        let session = URLSession(configuration: .ephemeral)
        func request(_ path: String, method: String = "GET") async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 3)
            request.httpMethod = method
            if method == "POST" { request.httpBody = Data("{}".utf8) }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let (status, nonce) = try await request(IPhoneShortcutHandshake.challengePath)
        precondition(status == 200 && UUID(uuidString: nonce) != nil)
        let validPath = capturePath(nonce, secret: secret)
        let wrong = try await request(capturePath(nonce, secret: "wrong"), method: "POST")
        precondition(wrong == (403, "TOSS_PAIRING_REQUIRED") && admitted == 0)
        let get = try await request(validPath)
        precondition(get.0 == 404 && admitted == 0)
        let accepted = try await request(validPath, method: "POST")
        precondition(accepted.0 == 204 && admitted == 1)
        let replay = try await request(validPath, method: "POST")
        precondition(replay == (403, "") && admitted == 1)
        let (pastedStatus, pastedNonce) = try await request(IPhoneShortcutHandshake.challengePath)
        precondition(pastedStatus == 200 && UUID(uuidString: pastedNonce) != nil)
        let wrongPasted = try await request(capturePath(pastedNonce, secret: "wrong\n"), method: "POST")
        precondition(wrongPasted.0 == 403 && admitted == 1)
        let pasted = try await request(capturePath(pastedNonce, secret: secret + "\n"), method: "POST")
        precondition(pasted.0 == 204 && admitted == 2)
        let alternateReplay = try await request(capturePath(pastedNonce, secret: secret), method: "POST")
        precondition(alternateReplay.0 == 403 && admitted == 2, "A different spelling cannot reuse the challenge")
        let (authorizationStatus, authorizationNonce) = try await request(IPhoneShortcutHandshake.authorizationPath)
        precondition(authorizationStatus == 200 && UUID(uuidString: authorizationNonce) != nil)
        let invalidAuthorization = try await request(capturePath(authorizationNonce, secret: "wrong"), method: "POST")
        precondition(invalidAuthorization.0 == 403 && admitted == 2)
        let (_, phoneNonce) = try await request(IPhoneShortcutHandshake.challengePath)
        let authorization = try await request(capturePath(authorizationNonce, secret: secret), method: "POST")
        precondition(authorization.0 == 204 && admitted == 2, "The authorization check must not capture")
        let authorizationReplay = try await request(capturePath(authorizationNonce, secret: secret), method: "POST")
        precondition(authorizationReplay.0 == 403 && admitted == 2)
        let phoneCapture = try await request(capturePath(phoneNonce, secret: secret), method: "POST")
        precondition(phoneCapture.0 == 204 && admitted == 3, "An authorization check must not block concurrent phone captures")
        let (pairStatus, pairNonce) = try await request(IPhoneShortcutHandshake.pairingPath)
        precondition(pairStatus == 200 && UUID(uuidString: pairNonce) != nil)
        let pairReceipt = try await request(capturePath(pairNonce, secret: secret), method: "POST")
        precondition(pairReceipt == (200, "TOSS_PAIRED") && admitted == 3)
        let (_, completeNonce) = try await request(IPhoneShortcutHandshake.pairingCompletePath)
        let completion = try await request(capturePath(completeNonce, secret: secret), method: "POST")
        precondition(completion == (200, "TOSS_SETUP_COMPLETE") && admitted == 3)
        precondition(macChecks == 1 && remoteEvents == 0, "Local requests must not confirm a phone or display phone repair")
        receiver.stop()
        do {
            _ = try await request(IPhoneShortcutHandshake.challengePath)
            preconditionFailure("Receiver must close when turned off")
        } catch { precondition(admitted == 3) }
        print("iPhone shortcut: import identity, saved setup, pairing, expiry, replay prevention, and capture-free authorization passed.")
    }
}
