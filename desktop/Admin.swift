import Foundation

/// The server's /admin API: the model in memory, loading and unloading it.
struct Admin: Sendable {
    let endpoint: String

    struct Loaded: Decodable, Sendable {
        let model: String
        let adapter: String?
        let bytes: Int64
        let mixture: Bool
        let expert_slots: Int
        let since: Int64
    }

    struct Generation: Decodable, Sendable {
        let prompt_tokens: Int
        let cached_tokens: Int
        let prefill_ms: Int64
        let tokens: Int
        let decode_per_second: Double
        let at: Int64
    }

    struct Going: Decodable, Sendable, Hashable {
        let model: String
        let client: String
        let prompt_tokens: Int
        let cached_tokens: Int
        let tokens: Int
        let millis: Int64
        let per_second: Double
    }

    struct Status: Decodable, Sendable {
        let loaded: Loaded?
        let last_model: String
        let loading: String?
        let switching: Bool
        let running: Int
        let mlx_active_bytes: Int64
        let idle_seconds: Int64
        let memory_room_bytes: Int64
        let memory_pressure: Int
        let unload_after_minutes: Int
        let last_generation: Generation?
        /// The generations going on (absent from servers before 2026-11-14).
        let generations: [Going]?

        /// The room a model would have: what is free, and the loaded model's own memory (it is let go first).
        var room: Int64 {
            memory_room_bytes + max(0, min(mlx_active_bytes, loaded?.bytes ?? 0))
        }
    }

    private struct Failure: Decodable { let error: String }

    func status() async throws -> Status {
        try await call("GET", "/admin/status", nil, timeout: 3)
    }

    func load(_ model: String, reload: Bool = false) async throws {
        let _: [String: String] = try await call("POST", "/admin/load", ["model": model, "reload": reload], timeout: 600)
    }

    func unload(force: Bool = false) async throws {
        let _: [String: Bool] = try await call("POST", "/admin/unload", ["force": force], timeout: 60)
    }

    private func call<T: Decodable>(
        _ method: String, _ path: String, _ body: [String: Any]?, timeout: TimeInterval
    ) async throws -> T {
        var request = URLRequest(url: URL(string: endpoint + path)!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 && path == "/admin/status" {
                throw InstallFailure(String(localized: "This server is older than the panel: update the server."))
            }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "HTTP \(code)"
            throw InstallFailure(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
