import Foundation

enum UsageError: LocalizedError {
    case http(Int, String)
    case network(String)
    case noScope

    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .network(let m): return "Network: \(m)"
        case .noScope: return "Token can't read usage"
        }
    }
}

enum UsageClient {
    static let userAgent = "claude-cli/2.1.14 (external, cli)"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let probeModel = "claude-haiku-4-5-20251001"

    static func fetch(profile: Profile, allowRefresh: Bool) async throws -> Snapshot {
        if profile.provider == .codex { return try await CodexClient.fetch(profile: profile) }
        let cred = try await CredentialStore.credential(for: profile, allowRefresh: allowRefresh)
        let plan = cred.oauth?.subscriptionType

        // Primary: the usage endpoint (needs user:profile; every interactive login has it).
        if cred.oauth?.canReadUsageAPI ?? false {
            do {
                let buckets = try await fetchAPI(token: cred.token)
                return Snapshot(buckets: buckets, fetchedAt: .now, plan: plan, source: .api)
            } catch UsageError.noScope {
                // fall through to probe
            }
        }
        // Fallback: a 1-token Haiku call; limits come back in response headers.
        let buckets = try await probe(token: cred.token)
        return Snapshot(buckets: buckets, fetchedAt: .now, plan: plan, source: .probe)
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        return r
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw UsageError.network("no HTTP response") }
            return (d, h)
        } catch let e as UsageError { throw e }
        catch { throw UsageError.network(error.localizedDescription) }
    }

    private static func errorMessage(_ data: Data, _ code: Int) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
        let s = String(decoding: data.prefix(160), as: UTF8.self)
        return s.isEmpty ? "status \(code)" : s
    }

    /// GET /api/oauth/usage → {"five_hour":{"utilization":12.3,"resets_at":"…"}, "seven_day":{…}, …}
    /// `utilization` is a percentage (0–100).
    static func fetchAPI(token: String) async throws -> [Bucket] {
        let (data, resp) = try await send(request(usageURL, token: token))
        if resp.statusCode == 403 { throw UsageError.noScope }
        guard resp.statusCode == 200 else { throw UsageError.http(resp.statusCode, errorMessage(data, resp.statusCode)) }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.http(200, "unexpected body")
        }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps"]
        var buckets: [Bucket] = []
        for (key, val) in j {
            guard let d = val as? [String: Any] else { continue }
            let util: Double?
            if let n = d["utilization"] as? Double { util = n }
            else if let s = d["utilization"] as? String { util = Double(s) }
            else { util = nil }
            guard let util else { continue }
            let reset = (d["resets_at"] as? String).flatMap(parseISO)
            let status = (d["status"] as? String) ?? (d["locked_reason"] as? String)
            buckets.append(Bucket(key: key, label: Bucket.label(for: key), percent: util,
                                  resetsAt: reset, status: status))
        }
        buckets.sort { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }

        // Model/surface-scoped weekly limits (e.g. "Fable") live in `limits`:
        // {"kind":"weekly_scoped","percent":23,"severity":"normal","resets_at":…,
        //  "scope":{"model":{"display_name":"Fable"},"surface":null}}
        if let limits = j["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String, kind != "session", kind != "weekly_all",
                      let pct = l["percent"] as? Double else { continue }
                let scope = l["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                    ?? scope?["surface"] as? String
                let name = model ?? surface ?? kind.replacingOccurrences(of: "_", with: " ")
                let key = "\(kind):\(name)"
                guard !buckets.contains(where: { $0.key == key }) else { continue }
                let severity = l["severity"] as? String
                buckets.append(Bucket(key: key, label: "Weekly · \(name)", percent: pct,
                                      resetsAt: (l["resets_at"] as? String).flatMap(parseISO),
                                      status: severity == nil || severity == "normal" ? nil : severity))
            }
        }
        return buckets
    }

    /// POST /v1/messages with max_tokens=1 and read
    /// anthropic-ratelimit-unified-{5h,7d}-{utilization,reset,status}. utilization is 0–1.
    static func probe(token: String) async throws -> [Bucket] {
        var req = request(messagesURL, token: token)
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "model": probeModel, "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "hi"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else { throw UsageError.http(resp.statusCode, errorMessage(data, resp.statusCode)) }
        var buckets: [Bucket] = []
        for (key, prefix) in [("five_hour", "5h"), ("seven_day", "7d")] {
            guard let u = resp.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(prefix)-utilization"),
                  let util = Double(u) else { continue }
            let reset = resp.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(prefix)-reset")
                .flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let status = resp.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(prefix)-status")
            buckets.append(Bucket(key: key, label: Bucket.label(for: key), percent: util * 100,
                                  resetsAt: reset, status: status))
        }
        return buckets
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
