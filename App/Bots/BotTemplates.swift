import Foundation

/// The built-in bot templates (src/shared/bots/bot-templates.ts), bundled as BotTemplates.json by
/// scripts/generate-bot-templates.mjs. Their words show in the UI language under `bots.templates.<id>.<field>`;
/// a bot made from one keeps the English, as the desktop's do.
struct BotTemplate: Decodable, Hashable {
  struct Schedule: Decodable, Hashable {
    let id: String
    let when: String
    let what: String
  }

  let id: String
  let category: String
  let name: String
  let line: String
  let firstChat: String
  let mascot: String
  let watches: String
  let does: String
  let reports: String
  let skills: [String]
  let connectors: [String]
  let schedules: [Schedule]
  let needsSetup: String?

  /// One of its words in the UI language.
  func word(_ field: String, english: String) -> String {
    Bundle.main.localizedString(forKey: "bots.templates.\(id).\(field)", value: english, table: nil)
  }

  var shownName: String { word("name", english: name) }
  var shownLine: String { word("line", english: line) }

  /// The ids an older host knows; it takes only their seed, without packages.
  var isLegacy: Bool { ["support", "release", "followup", "feedback", "briefing"].contains(id) }

  static let catalog: (categories: [String], templates: [BotTemplate]) = {
    struct File: Decodable {
      let categories: [String]
      let templates: [BotTemplate]
    }
    guard let url = Bundle.main.url(forResource: "BotTemplates", withExtension: "json"),
      let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
    else { return ([], []) }
    return (file.categories, file.templates)
  }()

  static func categoryName(_ category: String) -> String {
    switch category {
    case "coding": String(localized: "bots.templates.category.coding", defaultValue: "Coding")
    case "releases": String(localized: "bots.templates.category.releases", defaultValue: "Releases & CI")
    case "support": String(localized: "bots.templates.category.support", defaultValue: "Support & triage")
    case "planning": String(localized: "bots.templates.category.planning", defaultValue: "Planning & docs")
    case "ops": String(localized: "bots.templates.category.ops", defaultValue: "Ops")
    case "personal": String(localized: "bots.templates.category.personal", defaultValue: "Personal assistant")
    default: category
    }
  }

  /// A skill as the pages list it: a translated name keeps its folder name beside it.
  static func skillName(_ skill: String) -> String {
    let camel = skill.split(separator: "-").enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    let name = Bundle.main.localizedString(forKey: "bots.templateSkills.\(camel)", value: skill, table: nil)
    guard name != skill else { return skill }
    return String(
      format: String(localized: "bots.templateSkills.nameWithFolder", defaultValue: "%1$@ (%2$@)"), name, skill)
  }

  static func skillLine(_ skill: String) -> String {
    Bundle.main.localizedString(forKey: "bots.templateSkills.lines.\(skill)", value: "", table: nil)
  }

  static let connectorNames = ["github": "GitHub", "slack": "Slack", "linear": "Linear", "google": "Google", "composio": "Apps"]
}
