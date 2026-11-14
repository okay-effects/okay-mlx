import Foundation

/// A JSON-with-comments document's objects located by key path, so one value can be replaced in place: the rest of
/// the file — its comments, order and layout — stays as the person wrote it.
enum JSONC {
    final class Node {
        let start: Int
        var end: Int
        var members: [(key: String, value: Node)] = []
        let isObject: Bool
        init(start: Int, end: Int, isObject: Bool) { self.start = start; self.end = end; self.isObject = isObject }
        func member(_ key: String) -> Node? { members.first { $0.key == key }?.value }
    }

    struct Malformed: Error {}

    /// The document's root value; offsets are UTF-8 byte offsets.
    static func parse(_ text: String) throws -> Node {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skip()
        let root = try parser.value()
        parser.skip()
        guard parser.at == parser.bytes.count else { throw Malformed() }
        return root
    }

    /// The node at a key path, if every step is an object member.
    static func find(_ root: Node, _ path: [String]) -> Node? {
        path.reduce(Optional(root)) { node, key in node?.member(key) }
    }

    /// `text` with the UTF-8 byte range replaced.
    static func replacing(_ text: String, _ start: Int, _ end: Int, with insert: String) -> String {
        let bytes = Array(text.utf8)
        return String(decoding: bytes[..<start] + Array(insert.utf8) + bytes[end...], as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        mutating func skip() {
            while at < bytes.count {
                let c = bytes[at]
                if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { at += 1 }
                else if c == 0x2F, at + 1 < bytes.count, bytes[at + 1] == 0x2F {
                    while at < bytes.count && bytes[at] != 0x0A { at += 1 }
                } else if c == 0x2F, at + 1 < bytes.count, bytes[at + 1] == 0x2A {
                    at += 2
                    while at + 1 < bytes.count && !(bytes[at] == 0x2A && bytes[at + 1] == 0x2F) { at += 1 }
                    at = min(bytes.count, at + 2)
                } else { return }
            }
        }

        mutating func string() throws -> String {
            guard at < bytes.count, bytes[at] == 0x22 else { throw Malformed() }
            let start = at
            at += 1
            while at < bytes.count && bytes[at] != 0x22 {
                at += bytes[at] == 0x5C ? 2 : 1
            }
            guard at < bytes.count else { throw Malformed() }
            at += 1
            let raw = String(decoding: bytes[start..<at], as: UTF8.self)
            return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
        }

        mutating func value() throws -> Node {
            guard at < bytes.count else { throw Malformed() }
            let start = at
            switch bytes[at] {
            case 0x7B: // {
                let node = Node(start: start, end: start, isObject: true)
                at += 1
                skip()
                while at < bytes.count && bytes[at] != 0x7D {
                    let key = try string()
                    skip()
                    guard at < bytes.count, bytes[at] == 0x3A else { throw Malformed() }
                    at += 1
                    skip()
                    node.members.append((key, try value()))
                    skip()
                    if at < bytes.count && bytes[at] == 0x2C { at += 1; skip() }
                }
                guard at < bytes.count else { throw Malformed() }
                at += 1
                node.end = at
                return node
            case 0x5B: // [
                at += 1
                skip()
                while at < bytes.count && bytes[at] != 0x5D {
                    _ = try value()
                    skip()
                    if at < bytes.count && bytes[at] == 0x2C { at += 1; skip() }
                }
                guard at < bytes.count else { throw Malformed() }
                at += 1
                return Node(start: start, end: at, isObject: false)
            case 0x22:
                _ = try string()
                return Node(start: start, end: at, isObject: false)
            default:
                while at < bytes.count, !",}] \n\r\t/".utf8.contains(bytes[at]) { at += 1 }
                guard at > start else { throw Malformed() }
                return Node(start: start, end: at, isObject: false)
            }
        }
    }
}

/// opencode's provider "okay-mlx" — the models OpenChamber and the opencode CLI offer — kept equal to the models the
/// server has: their names, tool calls, and their context so opencode compacts a session before it overflows.
struct OpenCode: Sendable {
    static let provider = "okay-mlx"
    let home: URL

    /// The global config opencode reads: opencode.jsonc (opencode 2 reads only it when both exist), else .json.
    var config: URL {
        let directory = home.appending(path: ".config/opencode")
        let jsonc = directory.appending(path: "opencode.jsonc")
        let json = directory.appending(path: "opencode.json")
        return FileManager.default.fileExists(atPath: jsonc.path) || !FileManager.default.fileExists(atPath: json.path)
            ? jsonc : json
    }

    struct State: Sendable {
        var exists = false
        var listed: [String] = []
        var baseURL: String?
        var readable = true
    }

    func state() -> State {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return State() }
        guard let root = try? JSONC.parse(text) else { return State(exists: true, readable: false) }
        var state = State(exists: true)
        let provider = JSONC.find(root, ["provider", Self.provider])
        state.listed = provider?.member("models")?.members.map(\.key) ?? []
        if let url = provider?.member("options")?.member("baseURL") {
            let bytes = Array(text.utf8)[url.start..<url.end]
            state.baseURL = try? JSONDecoder().decode(String.self, from: Data(bytes))
        }
        return state
    }

    /// The provider's entry for these models (each with its context, if known).
    func block(_ models: [(id: String, title: String, context: Int?)], endpoint: String, indent: String) -> String {
        func quoted(_ s: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        let inner = indent + "  "
        let entries = models.map { model -> String in
            var fields = ["\"name\": \(quoted(model.title + " (okay-mlx)"))", "\"tool_call\": true"]
            if let context = model.context {
                fields.append("\"limit\": { \"context\": \(context), \"output\": \(min(32768, context / 4)) }")
            }
            return "\(inner)  \(quoted(model.id)): { \(fields.joined(separator: ", ")) }"
        }
        return """
        {
        \(inner)"npm": "@ai-sdk/openai-compatible",
        \(inner)"name": "okay-mlx (local MLX)",
        \(inner)"options": { "baseURL": \(quoted(endpoint + "/v1")), "apiKey": "local" },
        \(inner)"models": {
        \(entries.joined(separator: ",\n"))
        \(inner)}
        \(indent)}
        """
    }

    /// The config written with the provider's entry for `models`; a backup of the person's file is kept once.
    func sync(_ models: [(id: String, title: String, context: Int?)], endpoint: String) throws {
        let files = FileManager.default
        let url = config
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n"
        let root = try JSONC.parse(text)
        guard root.isObject else { throw JSONC.Malformed() }
        let updated: String
        if let existing = JSONC.find(root, ["provider", Self.provider]) {
            updated = JSONC.replacing(text, existing.start, existing.end,
                                      with: block(models, endpoint: endpoint, indent: "    "))
        } else if let providers = root.member("provider"), providers.isObject {
            let comma = providers.members.isEmpty ? "" : ","
            let entry = "\n    \"\(Self.provider)\": " + block(models, endpoint: endpoint, indent: "    ") + comma
            updated = JSONC.replacing(text, providers.start + 1, providers.start + 1, with: entry)
        } else {
            let comma = root.members.isEmpty ? "\n" : ",\n"
            let entry = "\n  \"provider\": {\n    \"\(Self.provider)\": " +
                block(models, endpoint: endpoint, indent: "    ") + "\n  }" + comma
            updated = JSONC.replacing(text, root.start + 1, root.start + 1, with: entry)
        }
        _ = try JSONC.parse(updated)
        let backup = url.appendingPathExtension("okay-mlx.bak")
        if files.fileExists(atPath: url.path) && !files.fileExists(atPath: backup.path) {
            try files.copyItem(at: url, to: backup)
        }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// OpenChamber's web service (a LaunchAgent): whether it runs, where, restarting it so its opencode reads the config.
struct OpenChamber: Sendable {
    static let label = "dev.openchamber.web"
    let home: URL

    struct State: Sendable {
        var installed = false
        var running = false
        var url = URL(string: "http://localhost:3000")!
    }

    var plist: URL { home.appending(path: "Library/LaunchAgents/\(Self.label).plist") }
    private var target: String { "gui/\(getuid())/\(Self.label)" }

    func state() -> State {
        var state = State()
        state.installed = FileManager.default.fileExists(atPath: plist.path)
        if let data = try? Data(contentsOf: plist),
           let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = config["ProgramArguments"] as? [String],
           let flag = args.firstIndex(where: { $0 == "--port" || $0 == "-p" }), args.indices.contains(flag + 1),
           let port = Int(args[flag + 1]) {
            state.url = URL(string: "http://localhost:\(port)")!
        }
        let printed = launchctl(["print", target])
        state.running = printed.code == 0 && printed.output.contains("pid = ")
        return state
    }

    func restart() throws {
        let result = launchctl(["kickstart", "-k", target])
        guard result.code == 0 else { throw InstallFailure("launchctl kickstart (\(result.code))\n\(result.output)") }
    }

    private func launchctl(_ args: [String]) -> (code: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// OpenChamber's own API (spec §3.4), as the panel uses it: the models its opencode offers now, its default model
/// for new sessions, and a pairing link for the iPhone app. Signed in with the UI password OpenChamber keeps in
/// ~/.config/openchamber/ui-password.txt (local, never sent elsewhere).
struct ChamberAPI: Sendable {
    let base: URL
    let home: URL

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }

    /// A signed-in session (its cookie kept in the ephemeral session's storage).
    private func signedIn() async throws -> URLSession {
        let session = self.session
        let file = home.appending(path: ".config/openchamber/ui-password.txt")
        guard let password = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else { return session }
        var request = URLRequest(url: base.appending(path: "auth/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallFailure(String(localized: "OpenChamber did not accept its UI password."))
        }
        return session
    }

    private func json(_ session: URLSession, _ method: String, _ path: String, _ body: [String: Any]? = nil)
        async throws -> Any {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallFailure("OpenChamber \(path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    struct State: Sendable {
        /// The okay-mlx models OpenChamber's opencode offers now.
        var models: [String] = []
        /// Its default model for new sessions ("provider/model"), if set.
        var defaultModel: String?
    }

    func state() async throws -> State {
        let session = try await signedIn()
        let models = try await json(session, "GET", "api/model") as? [String: Any]
        let ids = (models?["data"] as? [[String: Any]] ?? []).compactMap { model -> String? in
            model["providerID"] as? String == OpenCode.provider ? model["modelID"] as? String : nil
        }
        let settings = try await json(session, "GET", "api/config/settings") as? [String: Any]
        return State(models: ids, defaultModel: settings?["defaultModel"] as? String)
    }

    /// The default model of new sessions: an okay-mlx model, or none (OpenCode's own choice).
    func setDefault(_ model: String?) async throws {
        let session = try await signedIn()
        _ = try await json(session, "PUT", "api/config/settings",
                           ["defaultModel": model.map { "\(OpenCode.provider)/\($0)" } ?? ""])
    }

    struct Pairing: Sendable, Identifiable {
        let url: String
        let expires: Date?
        let fingerprint: String?
        var id: String { url }
    }

    /// A single-use pairing link for another OpenChamber client (the iPhone app), the relay included so it works
    /// away from this network — what `openchamber connect-url --relay` prints, run with OpenChamber's own node.
    func pair() async throws -> Pairing {
        let launcher = home.appending(path: ".config/openchamber/bin/OpenChamber")
        guard let script = try? String(contentsOf: launcher, encoding: .utf8),
              let line = script.split(separator: "\n").first(where: { $0.hasPrefix("exec ") }) else {
            throw InstallFailure(String(localized: "OpenChamber's launcher was not found."))
        }
        let quoted = line.split(separator: "'", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        guard quoted.count >= 2 else { throw InstallFailure(String(localized: "OpenChamber's launcher was not found.")) }
        let port = base.port ?? 3000
        let output = try await Task.detached { () throws -> Data in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: quoted[0])
            task.arguments = [quoted[1], "connect-url", "--relay", "--json", "--port", String(port)]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return data
        }.value
        guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              let url = object["connectUrl"] as? String else {
            throw InstallFailure(String(localized: "OpenChamber did not make a pairing link."))
        }
        let expires = (object["expiresAt"] as? String).flatMap { ISO8601DateFormatter.withFractions.date(from: $0) }
        return Pairing(url: url, expires: expires, fingerprint: object["fingerprint"] as? String)
    }
}

extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
