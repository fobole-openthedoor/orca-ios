import Foundation
import Security

/// A desktop this phone has paired with. The token and pinned key are credentials: they live in the Keychain only.
public struct PairedHost: Sendable, Equatable, Codable, Identifiable {
  public var id: UUID
  public var name: String
  /// The name this phone gives the desktop (Edit host); nil shows the name the desktop reports.
  public var personalName: String?
  public var endpoint: String
  public var deviceToken: String
  public var publicKeyB64: String
  public var pairedAt: Date
  /// The Orca store identified by the paired desktop after authentication.
  public var installationId: String?
  /// Set when the desktop serves this phone through Orca's relay as well.
  public var relay: RelayEndpoint?
  public var relayCredentials: RelayCredentialBundle?

  public init(id: UUID = UUID(), name: String, offer: PairingOffer, pairedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.endpoint = offer.endpoint
    self.deviceToken = offer.deviceToken
    self.publicKeyB64 = offer.publicKeyB64
    self.pairedAt = pairedAt
  }

  public var connectionConfiguration: OrcaConnection.Configuration {
    var configuration = OrcaConnection.Configuration(endpoint: endpoint, deviceToken: deviceToken, hostPublicKeyB64: publicKeyB64)
    if let relay, let relayCredentials {
      configuration.relay = relay
      configuration.relayCredential = .resume(relayCredentials)
    }
    return configuration
  }

  public var hasRelay: Bool {
    relay != nil && relayCredentials != nil
  }
}

/// Where the encoded host list is kept.
public protocol SecretStorage: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
}

public struct KeychainError: Error, Equatable {
  public let status: OSStatus
}

/// One generic-password item, readable after first unlock so a background reconnect can still authenticate.
public struct KeychainStorage: SecretStorage {
  private let service: String
  private let account: String

  public init(service: String = "com.thm.orcaios", account: String = "paired-hosts") {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public func read() throws -> Data? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError(status: status)
    }
    return item as? Data
  }

  public func write(_ data: Data) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw KeychainError(status: status)
    }
  }
}

/// The paired hosts, in pairing order.
public actor PairedHostStore {
  private let storage: any SecretStorage
  private var cached: [PairedHost]?

  public init(storage: any SecretStorage = KeychainStorage()) {
    self.storage = storage
  }

  public func hosts() throws -> [PairedHost] {
    if let cached {
      return cached
    }
    let hosts = try storage.read().map { try JSONDecoder().decode([PairedHost].self, from: $0) } ?? []
    cached = hosts
    return hosts
  }

  /// Adds a host, replacing an earlier pairing with the same desktop key.
  @discardableResult
  public func add(_ host: PairedHost) throws -> [PairedHost] {
    var hosts = try hosts().filter { $0.publicKeyB64 != host.publicKeyB64 }
    hosts.append(host)
    try save(hosts)
    return hosts
  }

  @discardableResult
  public func update(_ host: PairedHost) throws -> [PairedHost] {
    try update(host.id) { $0 = host }
  }

  /// Applies a field update to the latest saved record so overlapping writes preserve each other's data.
  @discardableResult
  public func update(_ id: PairedHost.ID, change: @Sendable (inout PairedHost) -> Void) throws -> [PairedHost] {
    var hosts = try hosts()
    guard let index = hosts.firstIndex(where: { $0.id == id }) else { return hosts }
    let previous = hosts[index]
    change(&hosts[index])
    guard hosts[index] != previous else { return hosts }
    try save(hosts)
    return hosts
  }

  @discardableResult
  public func remove(_ id: PairedHost.ID) throws -> [PairedHost] {
    let hosts = try hosts().filter { $0.id != id }
    try save(hosts)
    return hosts
  }

  private func save(_ hosts: [PairedHost]) throws {
    try storage.write(try JSONEncoder().encode(hosts))
    cached = hosts
  }
}
