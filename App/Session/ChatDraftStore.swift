import OrcaCore
import UIKit

/// What someone typed into a chat and hasn't sent, per session (mobile-native-chat-draft-inputs.ts): leaving
/// the chat, or the app, keeps it. The text is kept on disk so it survives a relaunch; attachments are kept
/// while the app runs.
@MainActor
enum ChatDraftStore {
  struct Draft {
    var text: String
    var attachments: [OutgoingAttachment]
  }

  private static var attachments: [String: [OutgoingAttachment]] = [:]

  private static func key(_ sessionId: String) -> String { "orca.chatDraft.\(sessionId)" }

  static func load(_ sessionId: String) -> Draft {
    Draft(text: UserDefaults.standard.string(forKey: key(sessionId)) ?? "", attachments: attachments[sessionId] ?? [])
  }

  static func save(_ sessionId: String, text: String, attachments saved: [OutgoingAttachment]) {
    if text.isEmpty {
      UserDefaults.standard.removeObject(forKey: key(sessionId))
    } else {
      UserDefaults.standard.set(text, forKey: key(sessionId))
    }
    attachments[sessionId] = saved.isEmpty ? nil : saved
  }
}
