import Foundation

struct Service: Sendable {
    static let label = "io.github.okay-effects.okay-mlx"
    static let defaultModel = "mlx-community/Qwen3.5-4B-MLX-4bit"

    let home: URL
    let label: String
    let domain = "gui/\(getuid())"

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, label: String = Self.label) {
        self.home = home
        self.label = label
    }

    var target: String { "\(domain)/\(label)" }
    var binary: URL { home.appending(path: ".okay-mlx/bin/okay-mlx") }
    var plist: URL { home.appending(path: "Library/LaunchAgents/\(label).plist") }
    var defaultLog: URL { home.appending(path: ".okay-mlx/serve.log") }

    struct Status: Sendable {
        var installed = false
        var binaryExists = false
        var loaded = false
        var enabled: Bool?
        var pid: String?
        var port = 8090
        var startupModel = Service.defaultModel
        var log: URL?
        var logText = ""
        var apiReady = false
        var models: [String] = []
        var cachedModels: [String] = []
        var modelCache: URL = ModelCache.root(
            home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment
        )
        var endpoint: String { "http://127.0.0.1:\(port)" }
        var autostart: Bool { installed && enabled == true }
    }

    enum Action: Sendable {
        case start, stop, restart, enableAutostart, disableAutostart
    }

    func status() async throws -> Status {
        var status = try await Task.detached { try localStatus() }.value
        if status.pid != nil {
            status.apiReady = (try? await get(status.endpoint + "/health", as: Health.self))?.status == "ok"
            if status.apiReady {
                let result = try? await get(status.endpoint + "/v1/models", as: ModelList.self)
                status.models = result?.data.map(\.id) ?? []
            }
        }
        return status
    }

    func perform(_ action: Action) async throws {
        try await Task.detached { try apply(action) }.value
    }

    private func localStatus() throws -> Status {
        let files = FileManager.default
        let job = try launchctl("print", target)
        let disabled = try launchctl("print-disabled", domain)
        var status = Status()
        status.binaryExists = files.isExecutableFile(atPath: binary.path)
        status.installed = files.fileExists(atPath: plist.path)
        status.loaded = job.code == 0
        status.pid = job.output.split(separator: "\n").compactMap {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("pid = ") ? String(line.dropFirst(6)) : nil
        }.first
        if disabled.code == 0 {
            let isDisabled = disabled.output.split(separator: "\n").contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line == "\"\(label)\" => disabled" || line == "\"\(label)\" => true"
            }
            status.enabled = !isDisabled
        }
        var log = defaultLog
        var environment = ProcessInfo.processInfo.environment
        if status.installed {
            let data = try Data(contentsOf: plist)
            guard let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { throw Failure(message: String(localized: "Invalid LaunchAgent file.\n\(plist.path)")) }
            if let args = config["ProgramArguments"] as? [String], let serve = args.firstIndex(of: "serve"),
               args.indices.contains(serve + 1), let port = Int(args[serve + 1]), (1...65535).contains(port) {
                status.port = port
            }
            if let env = config["EnvironmentVariables"] as? [String: String], let model = env["MLX_MODEL"] {
                status.startupModel = model
            }
            if let env = config["EnvironmentVariables"] as? [String: String] {
                environment.merge(env) { _, configured in configured }
            }
            if let path = config["StandardErrorPath"] as? String { log = URL(fileURLWithPath: path) }
            if config["RunAtLoad"] as? Bool != true && config["KeepAlive"] as? Bool != true {
                status.enabled = false
            }
        }
        status.log = log
        status.logText = try tail(log)
        status.modelCache = ModelCache.root(home: home, environment: environment)
        status.cachedModels = ModelCache.models(at: status.modelCache)
        return status
    }

    private func apply(_ action: Action) throws {
        switch action {
        case .start, .enableAutostart:
            try installIfNeeded()
            try checked("enable", target)
            if try launchctl("print", target).code == 0 {
                if action == .start { try checked("kickstart", target) }
            } else {
                try checked("bootstrap", domain, plist.path)
            }
        case .stop:
            try unload()
        case .restart:
            try checked("kickstart", "-k", target)
        case .disableAutostart:
            try checked("disable", target)
            try unload()
        }
    }

    private func unload() throws {
        guard try launchctl("print", target).code == 0 else { return }
        let result = try launchctl("bootout", target)
        if result.code != 0, try launchctl("print", target).code == 0 {
            throw Failure(message: result.output)
        }
        for _ in 0..<40 {
            if try launchctl("print", target).code != 0 { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure(message: String(localized: "launchd is still stopping the service."))
    }

    private func installIfNeeded() throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: plist.path) else { return }
        guard files.isExecutableFile(atPath: binary.path) else {
            throw Failure(message: String(localized: "The okay-mlx executable was not found.\n\(binary.path)"))
        }
        let config: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path, "serve", "8090"],
            "EnvironmentVariables": ["MLX_MODEL": Self.defaultModel],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": defaultLog.path,
            "StandardErrorPath": defaultLog.path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try files.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plist, options: .withoutOverwriting)
    }

    private func tail(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        let limit = 64 * 1024
        try file.seek(toOffset: end > limit ? end - UInt64(limit) : 0)
        let data = try file.read(upToCount: limit) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        if end > limit, let newline = text.firstIndex(of: "\n") { return String(text[text.index(after: newline)...]) }
        return text
    }

    private func checked(_ args: String...) throws {
        let result = try launchctl(args)
        guard result.code == 0 else {
            throw Failure(message: "launchctl \(args[0]) (\(result.code))\n\(result.output)")
        }
    }

    private func launchctl(_ args: String...) throws -> (code: Int32, output: String) { try launchctl(args) }

    private func launchctl(_ args: [String]) throws -> (code: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    private struct Health: Decodable { let status: String }
    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private func get<T: Decodable>(_ url: String, as type: T.Type) async throws -> T {
        let request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
