import Foundation

public enum PairingError: Error, Equatable {
  /// Neither the direct endpoint nor the relay answered.
  case unreachable
  /// The desktop refused the scanned code: it was used, rotated or revoked.
  case rejected
}

/// Turns a scanned offer into a saved host: connects by whichever path answers, installs a relay
/// credential when the offer has a relay, and swaps the scanned code for a token only this phone holds.
/// Mirrors `pre-profile-pairing-coordinator.ts` in stablyai/orca.
public enum PairingFlow {
  public static func pair(
    _ offer: PairingOffer, name: String, dialer: any WebSocketDialer = URLSessionWebSocketDialer(),
    director: any RelayDirector = HTTPRelayDirector(), timeout: Duration = .seconds(25)
  ) async throws -> PairedHost {
    var configuration = OrcaConnection.Configuration(offer: offer)
    configuration.authRejectionLimit = 1
    let connection = OrcaConnection(configuration: configuration, dialer: dialer, director: director)
    await connection.start()
    defer {
      Task { await connection.close() }
    }

    let status: JSONValue
    do {
      status = try await connection.request("status.get", [:], timeout: timeout)
    } catch ConnectionError.authenticationRejected {
      throw PairingError.rejected
    } catch is RPCError {
      status = [:]
    } catch {
      throw await connection.state == .authFailed ? PairingError.rejected : PairingError.unreachable
    }
    var host = PairedHost(name: status["machineName"]?.stringValue ?? Self.fallbackName(offer, name), offer: offer)

    if let relay = offer.relay {
      // The token never leaves the phone; the host stores only its hash.
      let token = RelayCrypto.newToken()
      let pending = RelayCredentialBundle.Pending(token: token, hash: RelayCrypto.hash(token), reqId: RelayCrypto.newRequestId("install"))
      do {
        _ = try await connection.request(
          "pairing.provisionRelay", ["reqId": .string(pending.reqId), "newResumeTokenHash": .string(pending.hash)])
        let endpoints = try await connection.request("pairing.getEndpoints", ["installReqId": .string(pending.reqId)])
        if let installed = endpoints["installStatus"]?["result"], endpoints["installStatus"]?["state"]?.stringValue == "committed" {
          host.relay = RelayEndpoint(endpoints["relay"]) ?? RelayEndpoint(offer: relay)
          host.relayCredentials = RelayCredentialBundle(installed: pending, result: installed)
        }
      } catch {
        // A desktop that will not serve the relay still pairs for the LAN.
      }
    }

    let capabilities = status["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if capabilities.contains(HostCapability.ticketExchange) {
      // Once this phone signs in with its own token, the code shown on the desktop stops working.
      let deviceToken = NaCl.randomBytes(24).map { String(format: "%02x", $0) }.joined()
      if (try? await connection.request("pairing.exchangeTicket", ["deviceToken": .string(deviceToken)])) != nil {
        host.deviceToken = deviceToken
      }
    }
    return host
  }

  private static func fallbackName(_ offer: PairingOffer, _ name: String) -> String {
    URL(string: offer.endpoint)?.host ?? name
  }
}
