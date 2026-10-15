import Foundation

// OpenAI Codex CLI (ChatGPT login). Tokens live in ~/.codex/auth.json:
//   {"auth_mode":"chatgpt","tokens":{"access_token":…,"refresh_token":…,"account_id":…},"last_refresh":…}
// The access token is a ~10-day JWT that the CLI refreshes itself whenever it
// runs, so this app never refreshes it — when it has expired we just say so.
// Usage comes from GET https://chatgpt.com/backend-api/wham/usage:
//   {"plan_type":"pro","email":…,"rate_limit":{"primary_window":{"used_percent":59,
//    "limit_window_seconds":604800,"reset_at":1792473323},"secondary_window":null},
//    "credits":{"balance":"62500.0"}, …}

enum CodexError: LocalizedError {
    case noAuth(String)
    case expired
    case apiKeyMode

    var errorDescription: String? {
        switch self {
        case .noAuth(let p): return "No Codex login at \(p). Run `codex` and sign in."
        case .expired: return "Codex login expired. Run `codex` once to refresh it."
        case .apiKeyMode: return "Codex is using an API key; usage limits only exist for ChatGPT logins."
        }
    }
}

enum CodexClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let userAgent = "codex_cli_rs/0.153.4"

    struct Auth { let accessToken: String; let accountID: String?; let expiresAt: Date? }

    static func readAuth(configDir: String) throws -> Auth {
        let path = configDir + "/auth.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.noAuth((path as NSString).abbreviatingWithTildeInPath)
        }
        guard let tokens = j["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            if (j["OPENAI_API_KEY"] as? String)?.isEmpty == false { throw CodexError.apiKeyMode }
            throw CodexError.noAuth((path as NSString).abbreviatingWithTildeInPath)
        }
        return Auth(accessToken: access, accountID: tokens["account_id"] as? String, expiresAt: jwtExpiry(access))
    }

    /// `exp` claim of a JWT, if decodable.
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = j["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func fetch(profile: Profile) async throws -> Snapshot {
        let auth = try readAuth(configDir: profile.configDir)
        if let exp = auth.expiresAt, exp < .now { throw CodexError.expired }

        var req = URLRequest(url: usageURL)
        req.timeoutInterval = 20
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let acc = auth.accountID { req.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw UsageError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw CodexError.expired }
        guard code == 200 else {
            let body = String(decoding: data.prefix(160), as: UTF8.self)
            throw UsageError.http(code, body.isEmpty ? "status \(code)" : body)
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.http(200, "unexpected body")
        }

        var buckets: [Bucket] = []
        let rl = j["rate_limit"] as? [String: Any] ?? [:]
        let limited = (rl["limit_reached"] as? Bool) == true || (rl["allowed"] as? Bool) == false
        for (name, key) in [("primary_window", "codex_primary"), ("secondary_window", "codex_secondary")] {
            guard let w = rl[name] as? [String: Any], let b = bucket(from: w, key: key, limited: limited) else { continue }
            buckets.append(b)
        }
        if let extra = j["additional_rate_limits"] as? [[String: Any]] {
            for (i, e) in extra.enumerated() {
                let w = (e["rate_limit"] as? [String: Any])?["primary_window"] as? [String: Any] ?? e["primary_window"] as? [String: Any] ?? e
                let name = (e["name"] as? String) ?? (e["limit_name"] as? String) ?? "Extra \(i + 1)"
                if let b = bucket(from: w, key: "codex_extra_\(i)", limited: false, labelOverride: name) { buckets.append(b) }
            }
        }
        // Make the first bucket the headline (ring) so single-window plans still get a gauge.
        if !buckets.isEmpty, !buckets.contains(where: { $0.isSession }) {
            buckets[0] = Bucket(key: "five_hour", label: buckets[0].label, percent: buckets[0].percent,
                                resetsAt: buckets[0].resetsAt, status: buckets[0].status)
        }

        var extra: String?
        if let c = j["credits"] as? [String: Any] {
            if (c["unlimited"] as? Bool) == true { extra = "credits: unlimited" }
            else if let bal = (c["balance"] as? String).flatMap(Double.init) ?? c["balance"] as? Double {
                let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
                extra = "credits: \(f.string(from: NSNumber(value: bal)) ?? "\(Int(bal))")"
            }
        }

        return Snapshot(buckets: buckets, fetchedAt: .now, plan: j["plan_type"] as? String, source: .api,
                        account: j["email"] as? String, extra: extra)
    }

    private static func bucket(from w: [String: Any], key: String, limited: Bool, labelOverride: String? = nil) -> Bucket? {
        let pct: Double
        if let p = w["used_percent"] as? Double { pct = p }
        else if let p = (w["used_percent"] as? String).flatMap(Double.init) { pct = p }
        else { return nil }
        let window = w["limit_window_seconds"] as? Double ?? 0
        let label: String
        if let labelOverride { label = labelOverride }
        else if window > 0 && window <= 6 * 3600 { label = "\(Int((window / 3600).rounded()))-hour session" }
        else if window >= 6 * 86400 { label = "Weekly" }
        else if window > 0 { label = "\(Int((window / 3600).rounded()))h window" }
        else { label = key == "codex_primary" ? "Primary limit" : "Secondary limit" }
        var reset: Date?
        if let at = w["reset_at"] as? Double { reset = Date(timeIntervalSince1970: at) }
        else if let after = w["reset_after_seconds"] as? Double { reset = Date().addingTimeInterval(after) }
        return Bucket(key: key, label: label, percent: pct, resetsAt: reset, status: limited ? "limit reached" : nil)
    }
}
