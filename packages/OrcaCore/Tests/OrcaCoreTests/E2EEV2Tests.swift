import Foundation
import Testing

@testable import OrcaCore

/// The desktop's half of the handshake, built from the same primitives, so a session can be driven end to end.
final class FakeDesktop {
  let keyPair: NaCl.KeyPair
  let nonce = NaCl.randomBytes(32)
  var schedule: E2EEV2KeySchedule?
  var inbound: UInt64 = 0
  var outbound: UInt64 = 0

  init(keyPair: NaCl.KeyPair = NaCl.generateKeyPair()) {
    self.keyPair = keyPair
  }

  var publicKeyB64: String {
    Base64.encode(keyPair.publicKey)
  }

  func ready(forHello helloText: String, publicKey: [UInt8]? = nil) throws -> String {
    let hello = try #require(try JSONSerialization.jsonObject(with: Data(helloText.utf8)) as? [String: Any])
    let clientPublicKey = try #require(Base64.decodeCanonical(hello["clientPublicKeyB64"] as! String, length: 32))
    let clientNonce = try #require(Base64.decodeCanonical(hello["clientNonceB64"] as! String, length: 32))
    let context = try #require(E2EEV2Context.parse(hello["context"]))
    let parsedHello = E2EEV2Hello(clientPublicKey: clientPublicKey, clientNonce: clientNonce, context: context)
    let ready = E2EEV2Ready(desktopPublicKey: keyPair.publicKey, desktopNonce: nonce)
    schedule = E2EEV2KeySchedule.derive(
      sharedSecret: try #require(NaCl.boxBeforeNM(secretKey: keyPair.secretKey, peerPublicKey: clientPublicKey)),
      transcript: E2EEV2Transcript.encode(hello: parsedHello, ready: ready),
      clientNonce: clientNonce,
      desktopNonce: nonce
    )
    let object: [String: Any] = [
      "type": "e2ee_ready",
      "v": 2,
      "desktopPublicKeyB64": Base64.encode(publicKey ?? keyPair.publicKey),
      "clientNonceB64": hello["clientNonceB64"]!,
      "desktopNonceB64": Base64.encode(nonce),
      "selection": ["framing": 2, "payloadKinds": ["text", "binary"]],
      "context": hello["context"]!,
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  func openText(_ frameB64: String) -> String? {
    guard
      let schedule,
      let frame = Base64.decodeCanonical(frameB64),
      let plaintext = E2EEV2Frame.open(
        frame: frame, key: schedule.mobileToDesktopKey, sessionId: schedule.sessionId,
        direction: .mobileToDesktop, kind: .text, expectedCounter: inbound)
    else {
      return nil
    }
    inbound += 1
    return String(decoding: plaintext, as: UTF8.self)
  }

  func seal(_ payload: [UInt8], kind: E2EEV2Frame.PayloadKind) -> [UInt8] {
    let frame = E2EEV2Frame.seal(
      payload: payload, key: schedule!.desktopToMobileKey, sessionId: schedule!.sessionId,
      direction: .desktopToMobile, kind: kind, counter: outbound)
    outbound += 1
    return frame
  }

  func sealText(_ text: String) -> String {
    Base64.encode(seal(Array(text.utf8), kind: .text))
  }
}

@Suite struct E2EEV2Tests {
  // The fixture and expected values of `mobile-e2ee-v2-fixtures.ts` in stablyai/orca.
  @Test func transcriptAndKeyScheduleMatchOrcaVector() {
    let hello = E2EEV2Hello(
      clientPublicKey: [UInt8](repeating: 1, count: 32),
      clientNonce: [UInt8](repeating: 2, count: 32),
      context: E2EEV2Context(transport: .relay, relayHostId: "AbCdEf0123_-xyZ9")
    )
    let ready = E2EEV2Ready(
      desktopPublicKey: [UInt8](repeating: 3, count: 32),
      desktopNonce: [UInt8](repeating: 4, count: 32)
    )
    let transcript = E2EEV2Transcript.encode(hello: hello, ready: ready)
    #expect(transcript.count == 1347)

    let schedule = E2EEV2KeySchedule.derive(
      sharedSecret: [UInt8](repeating: 5, count: 32),
      transcript: transcript,
      clientNonce: hello.clientNonce,
      desktopNonce: ready.desktopNonce
    )
    #expect(hex(schedule.transcriptHash) == "ca6385f8bbf64a223fdd59587bfb67e2373891ce9e6d85ab41df8b7a20a168e3")
    #expect(hex(schedule.mobileToDesktopKey) == "df17ff534df77fd3a30999f4e6200c8fcedefbb15d369301ca62c3cdfea9559a")
    #expect(hex(schedule.desktopToMobileKey) == "71365fcf8212a6d63caf909ee28de3c8f689682ef298a374136055e0ab1cde4a")
    #expect(hex(schedule.sessionId) == "339ae1f2bdff63481857d2813c2f19dd1f5aa4824705d5e5daeb25dae7b9196e")
  }

  @Test func handshakeAuthenticatesAndCarriesOrderedFrames() throws {
    let desktop = FakeDesktop()
    let session = try E2EEV2ClientSession(desktopPublicKeyB64: desktop.publicKeyB64, transport: .direct)
    #expect(!session.isReady)
    #expect(throws: E2EEError.notReady) { try session.sealText("early") }

    #expect(session.acceptReady(try desktop.ready(forHello: session.helloText)))
    let transcriptHash = try #require(session.transcriptHashB64)

    let auth = try #require(desktop.openText(try session.sealTokenAuth(deviceToken: "token-1")))
    let authObject = try #require(try JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any])
    #expect(authObject["type"] as? String == "e2ee_auth")
    #expect(authObject["deviceToken"] as? String == "token-1")
    #expect(authObject["transcriptHashB64"] as? String == transcriptHash)

    let reply = desktop.sealText(#"{"type":"e2ee_authenticated","v":2,"transcriptHashB64":"\#(transcriptHash)"}"#)
    #expect(session.isAuthenticatedReply(try #require(session.openText(reply))))
    #expect(!session.isAuthenticatedReply(#"{"type":"e2ee_authenticated","v":2,"transcriptHashB64":"other"}"#))

    #expect(desktop.openText(try session.sealText("hello ✓")) == "hello ✓")
    #expect(session.openBinary(desktop.seal([1, 2, 3], kind: .binary)) == [1, 2, 3])
  }

  @Test func rejectsReplayedReorderedAndMiskindedFrames() throws {
    let desktop = FakeDesktop()
    let session = try E2EEV2ClientSession(desktopPublicKeyB64: desktop.publicKeyB64, transport: .direct)
    #expect(session.acceptReady(try desktop.ready(forHello: session.helloText)))

    let first = desktop.sealText("one")
    let second = desktop.sealText("two")
    #expect(session.openText(second) == nil)
    #expect(session.openText(first) == "one")
    #expect(session.openText(first) == nil)
    #expect(session.openText(second) == "two")

    // A text frame is not accepted on the binary path, and the failure burns no counter.
    let third = desktop.sealText("three")
    #expect(session.openBinary(Base64.decodeCanonical(third)!) == nil)
    #expect(session.openText(third) == "three")
  }

  @Test func refusesAReadyFromAnotherKey() throws {
    let desktop = FakeDesktop()
    let session = try E2EEV2ClientSession(desktopPublicKeyB64: desktop.publicKeyB64, transport: .direct)
    let impostor = NaCl.generateKeyPair()
    #expect(!session.acceptReady(try desktop.ready(forHello: session.helloText, publicKey: impostor.publicKey)))
    #expect(!session.isReady)
    #expect(!session.acceptReady("not json"))
    #expect(!session.acceptReady(#"{"type":"e2ee_ready"}"#))
  }
}

@Suite struct PairingCodeTests {
  static func code(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static var direct: [String: Any] { [
    "v": 2,
    "endpoint": "ws://192.168.1.20:6768",
    "deviceToken": "abc123",
    "publicKeyB64": Data(repeating: 7, count: 32).base64EncodedString(),
  ] }

  @Test func parsesBareCodesAndLinks() throws {
    let code = try Self.code(Self.direct)
    let expected = PairingOffer(
      endpoint: "ws://192.168.1.20:6768", deviceToken: "abc123",
      publicKeyB64: Data(repeating: 7, count: 32).base64EncodedString())
    #expect(PairingCode.parse(code) == expected)
    #expect(PairingCode.parse("  orca://pair#\(code)\n") == expected)
    #expect(PairingCode.parse("ORCA://Pair/?code=\(code)") == expected)
    #expect(PairingCode.parse("orca://pair?other=1&code=\(code)#ignored") == expected)
  }

  @Test func refusesOtherLinksAndMalformedOffers() throws {
    let code = try Self.code(Self.direct)
    #expect(PairingCode.parse("orca://open#\(code)") == nil)
    #expect(PairingCode.parse("orca://pair/extra#\(code)") == nil)
    #expect(PairingCode.parse("orca://pair") == nil)
    #expect(PairingCode.parse("") == nil)
    #expect(PairingCode.parse("not base64 !!") == nil)

    var wrongVersion = Self.direct
    wrongVersion["v"] = 1
    #expect(PairingCode.parse(try Self.code(wrongVersion)) == nil)

    var missingToken = Self.direct
    missingToken["deviceToken"] = ""
    #expect(PairingCode.parse(try Self.code(missingToken)) == nil)
  }

  @Test func validatesRelayRoutes() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowMs = 1_800_000_000_000
    var relay: [String: Any] = [
      "v": 1,
      "directorUrl": "https://relay.example.com",
      "cellUrl": "https://cell-1.example.com",
      "assignmentEpoch": 3,
      "relayHostId": "AbCdEf0123_-xyZ9",
      "inviteToken": String(repeating: "a", count: 43),
      "inviteExpiresAt": nowMs + 60_000,
      "e2eeFraming": 2,
    ]
    var offer = Self.direct
    offer["relay"] = relay
    #expect(PairingCode.parse(try Self.code(offer), now: now)?.relay?.relayHostId == "AbCdEf0123_-xyZ9")

    // A first assignment is epoch 1, which Foundation also reads as `true`.
    relay["assignmentEpoch"] = 1
    offer["relay"] = relay
    #expect(PairingCode.parse(try Self.code(offer), now: now)?.relay?.assignmentEpoch == 1)
    relay["assignmentEpoch"] = true
    offer["relay"] = relay
    #expect(PairingCode.parse(try Self.code(offer), now: now) == nil)
    relay["assignmentEpoch"] = 3

    relay["inviteExpiresAt"] = nowMs - 1
    offer["relay"] = relay
    #expect(PairingCode.parse(try Self.code(offer), now: now) == nil)

    relay["inviteExpiresAt"] = nowMs + 60_000
    relay["cellUrl"] = "https://cell-1.example.com/path"
    offer["relay"] = relay
    #expect(PairingCode.parse(try Self.code(offer), now: now) == nil)
  }
}

final class MemoryStorage: SecretStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?

  func read() throws -> Data? {
    lock.withLock { data }
  }

  func write(_ data: Data) throws {
    lock.withLock { self.data = data }
  }
}

@Suite struct PairedHostStoreTests {
  static func offer(key: UInt8, token: String = "t") -> PairingOffer {
    PairingOffer(
      endpoint: "ws://10.0.0.\(key):6768", deviceToken: token,
      publicKeyB64: Data(repeating: key, count: 32).base64EncodedString())
  }

  @Test func persistsAndReplacesARepairedDesktop() async throws {
    let storage = MemoryStorage()
    let store = PairedHostStore(storage: storage)
    #expect(try await store.hosts().isEmpty)

    let studio = PairedHost(name: "Studio", offer: Self.offer(key: 1))
    let laptop = PairedHost(name: "Laptop", offer: Self.offer(key: 2))
    try await store.add(studio)
    try await store.add(laptop)
    // Pairing the same desktop again replaces its old token.
    let again = PairedHost(name: "Studio", offer: Self.offer(key: 1, token: "fresh"))
    try await store.add(again)

    let reloaded = try await PairedHostStore(storage: storage).hosts()
    #expect(reloaded.map(\.name) == ["Laptop", "Studio"])
    #expect(reloaded.last?.deviceToken == "fresh")

    #expect(try await store.remove(laptop.id).map(\.id) == [again.id])
  }

  @Test func learnsIdentityWithoutOverwritingHostSettings() async throws {
    let storage = MemoryStorage()
    let store = PairedHostStore(storage: storage)
    let host = PairedHost(name: "Studio", offer: Self.offer(key: 1))
    try await store.add(host)
    #expect(try await PairedHostStore(storage: storage).hosts().first?.installationId == nil)

    try await store.update(host.id) { $0.installationId = "studio-store" }
    try await store.update(host.id) { $0.personalName = "Edited name" }
    let saved = try #require(try await PairedHostStore(storage: storage).hosts().first)
    #expect(saved.installationId == "studio-store")
    #expect(saved.personalName == "Edited name")
    #expect(saved.deviceToken == host.deviceToken)
  }
}
