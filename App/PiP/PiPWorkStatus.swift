import OrcaCore
import UIKit

/// A catalog snapshot for the compact overlay. It carries only names and confirmed work states.
struct PiPWorkStatus {
  struct Entry {
    let agent: WorkingAgent
    var line: PiPFrame.StatusLine
    let workingChildTypes: [String?]
    let session: PiPAgentTelemetry.Key?

    var id: WorkingAgent.ID { agent.id }
    var activity: WorkingAgent.Activity { agent.activity }
    var workingCount: Int { workingChildTypes.count + (agent.leadActivity == .working ? 1 : 0) }
  }

  let entries: [Entry]
  let hostCount: Int
  let allHostsObserved: Bool

  @MainActor
  init(model: AppModel) {
    var entries: [Entry] = []
    var hostCount = 0
    var observed = 0
    for host in model.orderedHosts {
      guard let session = model.session(for: host.id), session.hasLiveWorktrees else { continue }
      observed += 1
      let agents = WorkingAgent.inCatalog(session.worktrees, host: host.id)
      if !agents.isEmpty { hostCount += 1 }
      for agent in agents {
        // Keep following telemetry on waiting agents too so cumulative tokens remain visible.
        let key = agent.structuredSessionId.map { PiPAgentTelemetry.Key(host: host.id, sessionId: $0) }
        let childTypes = agent.children.filter { $0.activity == .working }.map { child in
          AgentMark.overlayType(for: child.agentType) ?? AgentMark.overlayType(for: child.owningAgentType)
        }
        let line = PiPFrame.StatusLine(
          agent: Self.title(agent), agentType: AgentMark.overlayType(for: agent.agentType),
          isWorker: agent.isWorker, host: Self.oneLine(session.name))
        entries.append(Entry(agent: agent, line: line, workingChildTypes: childTypes, session: key))
      }
    }
    // Disambiguate host subtitles across the full active roster only when the same title spans ≥ 2 hosts.
    let ambiguousTitles = WorkingAgent.crossHostDuplicateTitles(
      in: entries.map { (host: $0.agent.id.host, title: $0.line.agent) })
    let counts = Dictionary(grouping: entries, by: \.line).mapValues(\.count)
    var ordinals: [PiPFrame.StatusLine: Int] = [:]
    let labeled = entries.map { entry in
      var labeled = entry
      labeled.line.showsHostSubtitle = ambiguousTitles.contains(WorkingAgent.normalizedTitleKey(entry.line.agent))
      if counts[entry.line, default: 0] > 1 {
        ordinals[entry.line, default: 0] += 1
        labeled.line.agent = "\(ordinals[entry.line, default: 1]). \(entry.line.agent)"
      }
      return labeled
    }
    self.entries = labeled.filter { $0.activity != .working } + labeled.filter { $0.activity == .working }
    self.hostCount = hostCount
    allHostsObserved = observed > 0 && observed == model.hosts.count
  }

  func frame(
    showing visible: [Entry], page: WorkingAgentRotation.Page,
    reading: (Entry) -> AgentActivityMetrics.Reading?
  ) -> PiPFrame {
    let title: String
    let status: String
    if entries.isEmpty {
      title = allHostsObserved
        ? String(localized: "orcaios.pip.noWorkingAgents", defaultValue: "No agents working")
        : String(localized: "orcaios.pip.statusUnavailable", defaultValue: "Agent status unavailable")
      status = ""
    } else {
      title = String.localizedStringWithFormat(
        String(localized: "orcaios.pip.workingAgents", defaultValue: "%lld working"), entries.reduce(0) { $0 + $1.workingCount })
      status = String.localizedStringWithFormat(
        String(localized: "orcaios.pip.workingHosts", defaultValue: "%lld hosts"), hostCount)
    }
    let scrollState: PiPFrame.ScrollState? = entries.count > 2
      ? .init(
        activities: entries.map(\.activity),
        activeIndices: page.indices,
        pinsFirstRow: page.scrollsOnlySecondRow)
      : nil
    return PiPFrame(
      title: title, status: status, working: !entries.isEmpty, lines: [], terminal: false,
      statusRows: visible.map { entry in
        var line = entry.line
        line.activity = entry.activity
        line.leadWorking = entry.agent.leadActivity == .working
        line.childTypes = entry.workingChildTypes
        if let value = reading(entry) {
          line.totalTokens = value.totalTokens
          line.tokenCountIsPartial = value.tokenCountIsPartial
          line.toolCount = value.toolCalls.map { (value.toolCountIsPartial ? "≥" : "") + String($0) }
          line.toolRunning = value.toolIsRunning
        }
        return .init(id: entry.id, line: line)
      }, scrollState: scrollState, statusAvailable: allHostsObserved)
  }

  private static func title(_ agent: WorkingAgent) -> String {
    let name = oneLine(agent.name ?? agent.workspace)
    return name.isEmpty ? String(localized: "session.backgroundTask.agent", defaultValue: "Agent") : name
  }

  private static func oneLine(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// Shares one subscription among all visible producers of a session. The next page is warmed up while the current one is shown.
@MainActor
final class PiPAgentTelemetry {
  struct Key: Hashable {
    let host: UUID
    let sessionId: String
  }

  private final class Stream {
    let connection: OrcaConnection
    var metrics = AgentActivityMetrics()
    var task: Task<Void, Never>?

    init(connection: OrcaConnection) { self.connection = connection }
  }

  private var streams: [Key: Stream] = [:]

  func follow(_ targets: Set<Key>, model: AppModel) {
    for key in Array(streams.keys) where !targets.contains(key) || model.session(for: key.host)?.api.connection !== streams[key]?.connection {
      streams.removeValue(forKey: key)?.task?.cancel()
    }
    for key in targets where streams[key] == nil {
      guard let api = model.session(for: key.host)?.api else { continue }
      let stream = Stream(connection: api.connection)
      streams[key] = stream
      stream.task = Task { [weak stream] in
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
          let subscription = await api.chat(sessionId: key.sessionId, resumingFrom: nil)
          var retry = true
          do {
            for try await frame in subscription.events {
              guard !Task.isCancelled else { break }
              stream?.metrics.apply(frame)
              if frame["type"]?.stringValue == "end" { break }
              delay = .seconds(1)
            }
          } catch let error as RPCError {
            retry = !["method_not_found", "forbidden", "invalid_argument"].contains(error.code)
          } catch {
            // Retry if a stream ended unexpectedly. The connection itself reopens after a dropped socket.
          }
          await api.connection.unsubscribe(subscription.requestId)
          stream?.metrics = AgentActivityMetrics()
          guard retry, !Task.isCancelled, (try? await Task.sleep(for: delay)) != nil else { return }
          delay = min(delay * 2, .seconds(10))
        }
      }
    }
  }

  func reading(_ entry: PiPWorkStatus.Entry) -> AgentActivityMetrics.Reading? {
    entry.session.flatMap { streams[$0]?.metrics.reading(agentId: nil, includeChildTokenFloor: true) }
  }
}
