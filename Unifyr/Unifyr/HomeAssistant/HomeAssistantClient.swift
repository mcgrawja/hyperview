//
//  HomeAssistantClient.swift
//  Unifyr
//
//  A tiny read-only Home Assistant REST client. This is the reliable path to the
//  BMW: instead of Unifyr wrestling with MyBMW's OAuth (captcha on first login,
//  refresh tokens, an API that BMW changes without notice), Home Assistant's
//  `bmw_connected_drive` integration owns all of that, and we just read the clean
//  entity state it publishes over HA's stable REST API.
//
//  Auth is a Home Assistant "long-lived access token" in the `Authorization:
//  Bearer` header (created under the HA user profile). Like the WebDAV client,
//  everything here is `nonisolated` — networking and JSON decoding run off the
//  main actor — and the TLS delegate accepts a self-signed certificate as a
//  fallback, because a self-hosted HA behind Tailscale often terminates TLS with
//  one (see HASessionDelegate).
//

import Foundation

// MARK: - Entity

/// One Home Assistant entity from `GET /api/states`. We keep the handful of
/// attributes the BMW card needs; the raw attribute bag is not retained.
nonisolated struct HAEntity: Identifiable, Hashable, Sendable {
    let entityID: String
    /// The primary state string, e.g. "412", "locked", "not_home", "unavailable".
    let state: String
    let friendlyName: String?
    let deviceClass: String?
    let unit: String?
    /// HA integrations stamp their source here; the BMW one sets a "…BMW…" /
    /// "…MyBMW…" attribution, which is how we recognise a car's entities without
    /// hard-coding entity names.
    let attribution: String?
    let latitude: Double?
    let longitude: Double?

    var id: String { entityID }

    /// The entity domain — the bit before the first dot ("sensor", "lock",
    /// "device_tracker", "binary_sensor", …).
    var domain: String {
        guard let dot = entityID.firstIndex(of: ".") else { return entityID }
        return String(entityID[..<dot])
    }

    var displayName: String { friendlyName ?? entityID }

    /// True when the state carries no real reading and should be hidden.
    var isUsable: Bool {
        let s = state.lowercased()
        return !s.isEmpty && s != "unavailable" && s != "unknown" && s != "none"
    }

    /// State plus its unit, e.g. "412 km" — for display of a numeric sensor.
    var valueWithUnit: String {
        guard let unit, !unit.isEmpty else { return state }
        return "\(state) \(unit)"
    }
}

// MARK: - Errors

nonisolated enum HAError: LocalizedError {
    case badURL
    case cannotResolveHost
    case unreachable
    case unauthorized
    case http(Int)
    case notHomeAssistant

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That Home Assistant address isn't a valid URL."
        case .cannotResolveHost:
            return "Couldn't find Home Assistant. If it's on your Tailscale network, connect to Tailscale first, then try again."
        case .unreachable:
            return "Home Assistant didn't respond. Check that it's online and reachable at this address."
        case .unauthorized:
            return "The access token was rejected. Create a long-lived access token in Home Assistant (Profile › Security) and paste it here."
        case .http(let code):
            return "Home Assistant returned an error (HTTP \(code))."
        case .notHomeAssistant:
            return "That address didn't answer as Home Assistant. Check the URL — it should be the base address, e.g. https://home.example.ts.net:8123."
        }
    }
}

// MARK: - Client

nonisolated struct HomeAssistantClient: Sendable {
    let baseURL: URL
    let token: String

    private var authHeader: String { "Bearer \(token)" }

    private func endpoint(_ components: String...) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    /// Connectivity + auth self-test: `GET /api/` returns 200 with a small JSON
    /// body when the token is valid. Distinguishes no-tailnet / server-down /
    /// bad-token the way the WebDAV probe does.
    func probe() async throws {
        let response = try await get(endpoint("api"))
        switch response.status {
        case 200...299: return
        case 401, 403: throw HAError.unauthorized
        case 404: throw HAError.notHomeAssistant
        default: throw HAError.http(response.status)
        }
    }

    /// Fetch just the named entities (`GET /api/states/<id>`, concurrently) —
    /// the dashboard card path, so a few pinned rows don't pull the whole
    /// home's state set. Entities the server no longer knows are skipped.
    func states(ids: [String]) async throws -> [HAEntity] {
        try await withThrowingTaskGroup(of: HAEntity?.self) { group in
            for id in ids {
                group.addTask {
                    let response = try await self.get(self.endpoint("api", "states", id))
                    switch response.status {
                    case 200...299: break
                    case 401, 403: throw HAError.unauthorized
                    case 404: return nil            // entity gone — not fatal
                    default: throw HAError.http(response.status)
                    }
                    return try? JSONDecoder().decode(HAEntity.self, from: response.data)
                }
            }
            var results: [HAEntity] = []
            for try await entity in group {
                if let entity { results.append(entity) }
            }
            return results
        }
    }

    /// Fetch all entity states (`GET /api/states`).
    func states() async throws -> [HAEntity] {
        let response = try await get(endpoint("api", "states"))
        switch response.status {
        case 200...299: break
        case 401, 403: throw HAError.unauthorized
        case 404: throw HAError.notHomeAssistant
        default: throw HAError.http(response.status)
        }
        do {
            return try JSONDecoder().decode([HAEntity].self, from: response.data)
        } catch {
            // A 200 that isn't the states array means we hit something other than
            // a Home Assistant API (a reverse proxy login page, say).
            throw HAError.notHomeAssistant
        }
    }

    // MARK: Plumbing

    private struct Response { let status: Int; let data: Data }

    private func get(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw HAError.notHomeAssistant }
        return Response(status: http.statusCode, data: data)
    }

    /// Same DNS-vs-refused split the WebDAV client uses: a MagicDNS name that
    /// won't resolve means "off the tailnet", not "server down".
    private static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return HAError.cannotResolveHost
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            return HAError.unreachable
        default:
            return error
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": "Unifyr-HomeAssistant/1"]
        return URLSession(configuration: config, delegate: HASessionDelegate(), delegateQueue: nil)
    }()
}

// MARK: - Decoding

// nonisolated: the conformance must be usable from off-main task groups
// (states(ids:)) — the file's MainActor default would otherwise isolate it.
nonisolated extension HAEntity: Decodable {
    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
    }

    private enum AttrKeys: String, CodingKey {
        case friendlyName = "friendly_name"
        case deviceClass = "device_class"
        case unit = "unit_of_measurement"
        case attribution
        case latitude
        case longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = try c.decode(String.self, forKey: .state)

        // Attributes are a heterogeneous bag; pull only what we use, and swallow
        // per-key type mismatches so one odd attribute can't fail the whole decode.
        if let a = try? c.nestedContainer(keyedBy: AttrKeys.self, forKey: .attributes) {
            friendlyName = try? a.decodeIfPresent(String.self, forKey: .friendlyName)
            deviceClass = try? a.decodeIfPresent(String.self, forKey: .deviceClass)
            unit = try? a.decodeIfPresent(String.self, forKey: .unit)
            attribution = try? a.decodeIfPresent(String.self, forKey: .attribution)
            latitude = try? a.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try? a.decodeIfPresent(Double.self, forKey: .longitude)
        } else {
            friendlyName = nil; deviceClass = nil; unit = nil
            attribution = nil; latitude = nil; longitude = nil
        }
    }
}

// MARK: - TLS

/// Validate the certificate chain normally first (full protection for a real
/// Let's Encrypt cert behind Tailscale HTTPS), and only accept the presented
/// certificate when standard evaluation fails — the self-signed self-hosted case
/// the user opted into by adding this server. The token never passes through
/// here; it rides the Authorization header. Mirrors WebDAVSessionDelegate.
private nonisolated final class HASessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
