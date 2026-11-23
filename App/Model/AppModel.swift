import Foundation
import Observation
import OrcaCore

/// The paired desktops and a live session for each. Screens read it; UIKit's observation tracking redraws them.
@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()

  private(set) var hosts: [PairedHost] = []
  private(set) var sessions: [PairedHost.ID: HostSession] = [:]
  /// False until the Keychain has been read, so Feed can show its title instead of a flash of the pairing guide.
  private(set) var loaded = false
  /// Set when the Keychain could not be read (a locked phone right after a restart).
  private(set) var credentialsUnavailable = false

  @ObservationIgnored private let store = PairedHostStore()
  /// One identity for this install, as the official app's device id.
  @ObservationIgnored let clientId: String = {
    let key = "orca.clientId"
    if let existing = UserDefaults.standard.string(forKey: key) { return existing }
    let id = UUID().uuidString.lowercased()
    UserDefaults.standard.set(id, forKey: key)
    return id
  }()

  private init() {}

  func load() async {
    guard !loaded else { return }
    do {
      hosts = try await store.hosts()
      credentialsUnavailable = false
    } catch {
      credentialsUnavailable = true
    }
    loaded = true
    for host in hosts { startSession(for: host) }
  }

  /// Hosts in the official Desktops order: the most recently paired first.
  var orderedHosts: [PairedHost] {
    hosts.sorted { $0.pairedAt > $1.pairedAt }
  }

  func session(for id: PairedHost.ID) -> HostSession? { sessions[id] }

  /// Pairs with the desktop that showed `offer`; re-pairing the same desktop replaces its old entry.
  func pair(_ offer: PairingOffer) async throws -> PairedHost {
    let host = try await PairingFlow.pair(offer, name: String(localized: "Desktop"))
    let replaced = hosts.first { $0.publicKeyB64 == host.publicKeyB64 }
    if let replaced {
      sessions[replaced.id]?.stop()
      sessions[replaced.id] = nil
      hosts = try await store.remove(replaced.id)
      PersistedConnectionLog.shared.discard(hostId: replaced.id.uuidString)
    }
    hosts = try await store.add(host)
    startSession(for: host)
    return host
  }

  func remove(_ id: PairedHost.ID) async throws {
    sessions[id]?.stop()
    sessions[id] = nil
    hosts = try await store.remove(id)
    // A removed host's history goes with it, as the official discardConnectionLogs.
    PersistedConnectionLog.shared.discard(hostId: id.uuidString)
  }

  /// Edit host: saves the phone's name and address for a desktop; its session redials a new address.
  func update(_ host: PairedHost) async throws {
    hosts = try await store.update(host)
    sessions[host.id]?.update(host)
  }

  /// The app came forward or the network changed: every desktop redials and reads its list again.
  func nudgeAll() {
    for session in sessions.values { session.nudge() }
  }

  private func startSession(for host: PairedHost) {
    guard sessions[host.id] == nil else { return }
    let store = store
    let session = HostSession(host: host, clientId: clientId) { relay, credentials in
      Task {
        guard var saved = try? await store.hosts().first(where: { $0.id == host.id }) else { return }
        saved.relay = relay
        saved.relayCredentials = credentials
        _ = try? await store.update(saved)
      }
    }
    sessions[host.id] = session
    session.start()
  }
}
