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
        let address = "http://fixture.local:54963"
        let enrollment = IPhoneShortcutEnrollment(address: address, secret: secret)
        let retryEnrollment = IPhoneShortcutEnrollment(address: address, secret: secret)
        precondition(enrollment.shortcutName != "Toss Tap" && enrollment.shortcutName != retryEnrollment.shortcutName,
                     "A new pairing must bypass existing or duplicate shortcut names")
        let stagedFilename = URL(fileURLWithPath: enrollment.filename)
        precondition(stagedFilename.pathExtension == "shortcut"
                     && stagedFilename.deletingPathExtension().lastPathComponent == enrollment.shortcutName,
                     "The iPhone names the imported shortcut from the staged file")
        let pairingLink = enrollment.link
        let components = pairingLink.flatMap { URLComponents(string: $0) }
        precondition(components?.scheme == "shortcuts" && components?.host == "run-shortcut")
        precondition(components?.queryItems == [URLQueryItem(name: "name", value: enrollment.shortcutName),
                                               URLQueryItem(name: "input", value: "text"),
                                               URLQueryItem(name: "text", value: "/setup/" + address + "|" + secret)],
                     "The QR link must deliver a complete enrollment value when decoded by Shortcuts")
        precondition(components?.percentEncodedQueryItems?.first(where: { $0.name == "text" })?.value
                     == "%2Fsetup%2Fhttp%3A%2F%2Ffixture.local%3A54963%7C" + secret,
                     "Reserved characters in the setup value must be escaped in the QR URL")
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
        precondition(migrated?.needsPhoneSetup == false, "An upgrade must preserve an existing shortcut")
        defaults.set(Data("""
            {"deviceHash":"first","destination":"chatgpt","secret":"\(secret)","automaticImportPending":true}
            """.utf8), forKey: IPhoneShortcutSettings.key)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsPhoneSetup == true,
                     "A pending setup recorded by an earlier version must still open on iPhone")
        let pending = IPhoneShortcutSettings(deviceHash: "first", destination: "chatgpt", previous: nil,
                                             pendingPhoneSetup: true)
        try pending.save(to: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsPhoneSetup == true)
        let retry = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: pending)
        precondition(retry.needsPhoneSetup && retry.secret == pending.secret)
        try retry.save(to: defaults)
        try IPhoneShortcutSettings.markPhoneVerified(secret: "stale", in: defaults)
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsPhoneSetup == true)
        try IPhoneShortcutSettings.markPhoneVerified(secret: pending.secret, in: defaults)
        let prepared = IPhoneShortcutSettings.load(from: defaults)
        precondition(prepared?.needsPhoneSetup == false && prepared?.destination == "claude"
                     && prepared?.secret == pending.secret)
        let optedOut = IPhoneShortcutSettings(deviceHash: "first", destination: "claude", previous: pending,
                                              disabled: true, pendingPhoneSetup: true)
        try optedOut.save(to: defaults)
        let savedOptOut = IPhoneShortcutSettings.load(from: defaults)
        precondition(savedOptOut?.isEnabled == false && savedOptOut?.needsPhoneSetup == false,
                     "Turning off the iPhone trigger clears a pending setup")
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
        let base = "http://127.0.0.1:\(port.rawValue)"
        try pending.save(to: defaults)
        var admitted = 0
        var macChecks = 0, remoteEvents = 0
        precondition(!IPhoneShortcutReceiver.isRemotePeer(.ipv4(.loopback)))
        precondition(!IPhoneShortcutReceiver.isRemotePeer(.ipv6(.loopback)))
        precondition(!IPhoneShortcutReceiver.isRemotePeer(NWEndpoint.Host("::ffff:127.0.0.1")))
        precondition(IPhoneShortcutReceiver.isRemotePeer(NWEndpoint.Host("192.0.2.47")))
        try receiver.start(secret: pending.secret, onFailure: { preconditionFailure("Receiver did not start") },
                           onLocalAuthorization: { macChecks += 1 }, onProofMismatch: { remoteEvents += 1 },
                           onRemoteVerified: { _ in
            remoteEvents += 1
            try! IPhoneShortcutSettings.markPhoneVerified(secret: pending.secret, in: defaults)
        }) {
            admitted += 1
            return .accepted
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let session = URLSession(configuration: .ephemeral)
        func response(_ path: String, method: String) async throws -> (HTTPURLResponse, Data) {
            var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 3)
            request.httpMethod = method
            if method == "POST" { request.httpBody = Data("{}".utf8) }
            let (data, response) = try await session.data(for: request)
            return (response as! HTTPURLResponse, data)
        }
        func request(_ path: String, method: String = "GET") async throws -> (Int, String) {
            let (headers, body) = try await response(path, method: method)
            return (headers.statusCode, String(decoding: body, as: UTF8.self))
        }
        let retiredDownload = "/toss/iphone/install/01234567-89ab-4cde-8012-3456789abcde/Toss%20Tap%20ABCDEF12.shortcut"
        for method in ["GET", "HEAD", "POST"] {
            let (headers, body) = try await response(retiredDownload, method: method)
            precondition(headers.statusCode == 404 && body.isEmpty
                         && headers.value(forHTTPHeaderField: "Content-Disposition") == nil,
                         "A former shortcut download URL must not serve a file")
        }
        precondition(admitted == 0 && macChecks == 0 && remoteEvents == 0
                     && IPhoneShortcutSettings.load(from: defaults)?.needsPhoneSetup == true,
                     "Requests to the former download URL must not authorize, verify, or trigger capture")
        let (status, nonce) = try await request(IPhoneShortcutHandshake.challengePath)
        precondition(status == 200 && UUID(uuidString: nonce) != nil)
        let validPath = capturePath(nonce, secret: pending.secret)
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
        let pasted = try await request(capturePath(pastedNonce, secret: pending.secret + "\n"), method: "POST")
        precondition(pasted.0 == 204 && admitted == 2)
        let alternateReplay = try await request(capturePath(pastedNonce, secret: pending.secret), method: "POST")
        precondition(alternateReplay.0 == 403 && admitted == 2, "A different spelling cannot reuse the challenge")
        let (authorizationStatus, authorizationNonce) = try await request(IPhoneShortcutHandshake.authorizationPath)
        precondition(authorizationStatus == 200 && UUID(uuidString: authorizationNonce) != nil)
        let invalidAuthorization = try await request(capturePath(authorizationNonce, secret: "wrong"), method: "POST")
        precondition(invalidAuthorization.0 == 403 && admitted == 2)
        let (_, phoneNonce) = try await request(IPhoneShortcutHandshake.challengePath)
        let authorization = try await request(capturePath(authorizationNonce, secret: pending.secret), method: "POST")
        precondition(authorization.0 == 204 && admitted == 2, "The authorization check must not capture")
        precondition(IPhoneShortcutSettings.load(from: defaults)?.needsPhoneSetup == true,
                     "A successful authorization from Shortcuts on the Mac must leave phone setup pending")
        let authorizationReplay = try await request(capturePath(authorizationNonce, secret: pending.secret), method: "POST")
        precondition(authorizationReplay.0 == 403 && admitted == 2)
        let phoneCapture = try await request(capturePath(phoneNonce, secret: pending.secret), method: "POST")
        precondition(phoneCapture.0 == 204 && admitted == 3, "An authorization check must not block concurrent phone captures")
        let (pairStatus, pairNonce) = try await request(IPhoneShortcutHandshake.pairingPath)
        precondition(pairStatus == 200 && UUID(uuidString: pairNonce) != nil)
        let pairReceipt = try await request(capturePath(pairNonce, secret: pending.secret), method: "POST")
        precondition(pairReceipt == (200, "TOSS_PAIRED") && admitted == 3)
        let (_, completeNonce) = try await request(IPhoneShortcutHandshake.pairingCompletePath)
        let completion = try await request(capturePath(completeNonce, secret: pending.secret), method: "POST")
        precondition(completion == (200, "TOSS_SETUP_COMPLETE") && admitted == 3)
        precondition(macChecks == 1 && remoteEvents == 0, "Local requests must not confirm a phone or display phone repair")
        receiver.stop()
        do {
            _ = try await request(IPhoneShortcutHandshake.challengePath)
            preconditionFailure("Receiver must close when turned off")
        } catch { precondition(admitted == 3) }
        print("iPhone shortcut: import identity, saved setup, pairing, retired download URL, expiry, replay prevention, and capture-free authorization passed.")
    }
}
