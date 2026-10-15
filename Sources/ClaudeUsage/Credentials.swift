import Foundation
import CryptoKit

// Credentials come from the same place Claude Code keeps them: a generic
// password item in the login Keychain whose service name is
//   "Claude Code-credentials"               for ~/.claude
//   "Claude Code-credentials-<sha256[0:8]>" for any other CLAUDE_CONFIG_DIR
// The password is the JSON Claude Code writes (claudeAiOauth.accessToken …).
//
// Access tokens are short-lived and Claude Code only refreshes them while it is
// running, so this app refreshes expired tokens itself with the stored
// refreshToken and writes the result back in the same format, exactly like the
// CLI does. Both reads and writes go through /usr/bin/security, the same
// binary Claude Code uses, so no extra Keychain ACL prompt appears.

struct OAuthCreds {
    var root: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var subscriptionType: String?

    init?(json root: [String: Any]) {
        guard let o = root["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        self.root = root
        accessToken = token
        refreshToken = o["refreshToken"] as? String
        if let ms = o["expiresAt"] as? Double { expiresAt = Date(timeIntervalSince1970: ms / 1000) }
        scopes = o["scopes"] as? [String] ?? []
        subscriptionType = o["subscriptionType"] as? String
    }

    var isFresh: Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > 120
    }
    var canReadUsageAPI: Bool { scopes.isEmpty || scopes.contains("user:profile") }
}

enum CredSource: Equatable {
    case keychain(service: String)
    case tokenFile(path: String)
}

struct Credential {
    var token: String
    var source: CredSource
    var oauth: OAuthCreds?
}

enum CredError: LocalizedError {
    case notFound(String)
    case expired
    case refreshFailed(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "No login found for \(p). Run `claude` with that profile and sign in."
        case .expired: return "Token expired. Run `claude` with this profile (or enable auto-refresh in settings)."
        case .refreshFailed(let m): return "Token refresh failed: \(m)"
        case .keychain(let m): return "Keychain: \(m)"
        }
    }
}

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    static func run(_ path: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self))
    }
}

enum CredentialStore {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoints = [
        "https://platform.claude.com/v1/oauth/token",
        "https://console.anthropic.com/v1/oauth/token",
    ]

    /// Refresh tokens the server has rejected with invalid_grant. Retrying them
    /// every tick is pointless; wait until the Keychain item changes (re-login).
    private static var deadRefreshTokens = Set<String>()
    private static let deadLock = NSLock()

    static func keychainService(for configDir: String) -> String {
        let home = NSHomeDirectory()
        let norm = (configDir as NSString).standardizingPath
        if norm == home + "/.claude" { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(norm.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    // MARK: Keychain I/O (via /usr/bin/security, like Claude Code)

    static func readKeychain(service: String) throws -> OAuthCreds? {
        let r = try Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        if r.status == 44 { return nil } // errSecItemNotFound
        guard r.status == 0 else { throw CredError.keychain(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredError.keychain("unexpected item format")
        }
        return OAuthCreds(json: root)
    }

    static func writeKeychain(service: String, root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let user = NSUserName()
        let r = try Shell.run("/usr/bin/security",
                              ["add-generic-password", "-U", "-a", user, "-s", service, "-w", json])
        guard r.status == 0 else {
            Log.write("keychain write failed (\(r.status)): \(r.err)")
            throw CredError.keychain(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func readTokenFile(configDir: String) -> String? {
        let path = configDir + "/token"
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: Refresh

    static func refresh(_ creds: OAuthCreds) async throws -> OAuthCreds {
        guard let rt = creds.refreshToken else { throw CredError.refreshFailed("no refresh token stored") }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        let payload = try JSONSerialization.data(withJSONObject: body)

        var lastErr = "no endpoint reachable"
        for ep in tokenEndpoints {
            var req = URLRequest(url: URL(string: ep)!)
            req.httpMethod = "POST"
            req.httpBody = payload
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(UsageClient.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { lastErr = error.localizedDescription; Log.write("refresh: \(ep) network error: \(lastErr)"); continue }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            Log.write("refresh: \(ep) -> HTTP \(code)")
            if code != 200 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After") ?? "-"
                let ctype = http?.value(forHTTPHeaderField: "content-type") ?? "-"
                let body = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                Log.write("refresh: retry-after=\(retry) content-type=\(ctype) body=\(body)")
            }
            if code == 404 || code == 405 || code == 429 || code >= 500 { lastErr = "HTTP \(code) at \(ep)"; continue }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CredError.refreshFailed("HTTP \(code), non-JSON reply")
            }
            guard code == 200, let access = j["access_token"] as? String else {
                let msg = (j["error_description"] as? String) ?? (j["error"] as? String) ?? "HTTP \(code)"
                Log.write("refresh: rejected: \(msg)")
                throw CredError.refreshFailed(msg)
            }
            var root = creds.root
            var o = root["claudeAiOauth"] as? [String: Any] ?? [:]
            o["accessToken"] = access
            if let nrt = j["refresh_token"] as? String { o["refreshToken"] = nrt }
            let ttl = (j["expires_in"] as? Double) ?? 3600
            o["expiresAt"] = Int64((Date().timeIntervalSince1970 + ttl) * 1000)
            if let scope = j["scope"] as? String, !scope.isEmpty {
                o["scopes"] = scope.split(separator: " ").map(String.init)
            }
            root["claudeAiOauth"] = o
            guard let out = OAuthCreds(json: root) else { throw CredError.refreshFailed("malformed reply") }
            return out
        }
        throw CredError.refreshFailed(lastErr)
    }

    // MARK: Entry point

    /// Resolve a usable bearer token for the profile. Keychain first (refreshing
    /// if expired and allowed), then the legacy `<configDir>/token` file.
    static func credential(for profile: Profile, allowRefresh: Bool) async throws -> Credential {
        let service = keychainService(for: profile.configDir)
        if var creds = try readKeychain(service: service) {
            if creds.isFresh {
                return Credential(token: creds.accessToken, source: .keychain(service: service), oauth: creds)
            }
            guard allowRefresh else { throw CredError.expired }
            if let rt = creds.refreshToken {
                deadLock.lock(); let dead = deadRefreshTokens.contains(rt); deadLock.unlock()
                if dead { throw CredError.refreshFailed("refresh token expired — run `claude` with this profile and /login") }
            }
            Log.write("cred[\(profile.id)]: token expired, refreshing")
            do {
                let fresh = try await refresh(creds)
                try writeKeychain(service: service, root: fresh.root)
                Log.write("cred[\(profile.id)]: refreshed and written back")
                creds = fresh
            } catch {
                Log.write("cred[\(profile.id)]: refresh failed: \(error.localizedDescription)")
                if case CredError.refreshFailed(let m) = error, m.localizedCaseInsensitiveContains("expired"),
                   let rt = creds.refreshToken {
                    deadLock.lock(); deadRefreshTokens.insert(rt); deadLock.unlock()
                }
                // Maybe the CLI refreshed concurrently and rotated the token: re-read once.
                if let again = try readKeychain(service: service), again.isFresh {
                    creds = again
                } else {
                    throw error
                }
            }
            return Credential(token: creds.accessToken, source: .keychain(service: service), oauth: creds)
        }
        if let t = readTokenFile(configDir: profile.configDir) {
            return Credential(token: t, source: .tokenFile(path: profile.configDir + "/token"), oauth: nil)
        }
        throw CredError.notFound(profile.displayDir)
    }
}
