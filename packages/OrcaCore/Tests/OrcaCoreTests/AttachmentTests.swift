import Foundation
import Testing

@testable import OrcaCore

@Suite struct AttachmentTests {
  static func uploadHost() -> FakeHost {
    FakeHost { request, socket in
      switch request["method"]?.stringValue {
      case "clipboard.startImageUpload", "agentSessionAttachment.uploadStart":
        socket.succeed(request, ["uploadId": "up-1"])
      case "clipboard.commitImageUpload":
        socket.succeed(request, "/tmp/orca/pasted.png")
      case "agentSessionAttachment.uploadCommit":
        socket.succeed(request, ["path": "/store/agent-session-attachments/u/notes.txt", "name": "notes.txt", "byteLength": 0])
      default:
        socket.succeed(request, .null)
      }
    }
  }

  static func api(_ host: FakeHost) async -> HostAPI {
    let connection = OrcaConnection(configuration: host.configuration(), dialer: host)
    await connection.start()
    return HostAPI(connection: connection, clientId: "phone-1")
  }

  @Test func uploadsImagesInBase64CharacterOffsets() async throws {
    let host = Self.uploadHost()
    let api = await Self.api(host)
    // 600 KiB of bytes is 800 KiB of base64: two chunks.
    let data = Data((0..<600 * 1024).map { UInt8(truncatingIfNeeded: $0) })
    let path = try await api.uploadImage(data, fileName: "pasted.png", connectionId: nil)
    #expect(path == "/tmp/orca/pasted.png")

    let start = try #require(host.seenRequests.first { $0["method"] == "clipboard.startImageUpload" })
    #expect(start["params"]?["expectedBase64Length"] == 819_200)
    #expect(start["params"]?["connectionId"] == .null)
    let appends = host.seenRequests.filter { $0["method"] == "clipboard.appendImageUploadChunk" }
    #expect(appends.map { $0["params"]?["offset"] } == [0, 524_288])
    let joined = appends.compactMap { $0["params"]?["contentBase64"]?.stringValue }.joined()
    #expect(Data(base64Encoded: joined) == data)
    // Each chunk decodes on its own, as the host appends them one by one.
    #expect(appends.allSatisfy { Data(base64Encoded: $0["params"]?["contentBase64"]?.stringValue ?? "!") != nil })
    await api.connection.close()
  }

  @Test func uploadsFilesInByteOffsetsAndAppendsEvenWhenEmpty() async throws {
    let host = Self.uploadHost()
    let api = await Self.api(host)
    _ = try await api.uploadFile(Data(count: 500 * 1024), name: "notes.txt", sessionId: "session-1")
    var appends = host.seenRequests.filter { $0["method"] == "agentSessionAttachment.uploadAppend" }
    #expect(appends.map { $0["params"]?["offset"] } == [0, 393_216])

    _ = try await api.uploadFile(Data(), name: "empty.txt", sessionId: "session-1")
    appends = host.seenRequests.filter { $0["method"] == "agentSessionAttachment.uploadAppend" }
    #expect(appends.count == 3)
    #expect(appends.last?["params"]?["contentBase64"] == "")
    await api.connection.close()
  }

  @Test func abortsAnUploadTheHostRefusesPartWay() async throws {
    let host = FakeHost { request, socket in
      if request["method"] == "clipboard.startImageUpload" {
        socket.succeed(request, ["uploadId": "up-9"])
      } else if request["method"] == "clipboard.appendImageUploadChunk" {
        socket.reply(["id": request["id"] ?? .null, "ok": false, "error": ["code": "too_large", "message": "no"]])
      } else {
        socket.succeed(request, .null)
      }
    }
    let api = await Self.api(host)
    await #expect(throws: RPCError.self) {
      try await api.uploadImage(Data([1, 2, 3]), fileName: nil, connectionId: "ssh-1")
    }
    _ = try await api.connection.request("flush")
    #expect(host.seenRequests.contains { $0["method"] == "clipboard.abortImageUpload" && $0["params"]?["uploadId"] == "up-9" })
    await api.connection.close()
  }

  @Test func buildsMessageBodies() {
    #expect(ChatMessageBody.fileReference("/a/b.pdf") == "@/a/b.pdf")
    #expect(ChatMessageBody.fileReference("/a/with space.txt") == #"@"/a/with space.txt""#)
    #expect(ChatMessageBody.fileReference(#"/a/say "hi".txt"#) == #"@'/a/say "hi".txt'"#)
    #expect(ChatMessageBody.fileReference(#"/a/it's "x".txt"#) == #"@"/a/it's \"x\".txt""#)

    #expect(ChatMessageBody.text("look  \n", filePaths: ["/a.pdf", "/b c.txt"]) == "look\n@/a.pdf @\"/b c.txt\"")
    #expect(ChatMessageBody.text("  ", filePaths: ["/a.pdf"]) == "@/a.pdf")

    #expect(ChatMessageBody.send(text: " ", filePaths: [], imagePaths: []) == nil)
    #expect(
      ChatMessageBody.send(text: "see", filePaths: [], imagePaths: ["/i.png"])
        == ["kind": "message", "role": "user", "blocks": [["type": "text", "text": "see"], ["type": "image-ref", "path": "/i.png"]]])
  }
}
