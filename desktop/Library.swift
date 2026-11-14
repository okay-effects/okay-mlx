import Foundation

/// A model in the Hugging Face cache, as the panel shows it: its size, kind, quantization and context.
struct ModelInfo: Identifiable, Sendable, Hashable {
    let id: String
    let repository: URL
    let snapshot: URL
    /// The weights' bytes: what the model holds in memory when loaded whole.
    let weights: Int64
    /// Everything the repository keeps on disk (all snapshots' blobs).
    let disk: Int64
    let type: String
    let mixture: Bool
    let bits: Int?
    let context: Int?
    let adapters: [String]

    /// A short human name: "Qwen3.6 35B A3B" for mlx-community/Qwen3.6-35B-A3B-4bit.
    var title: String { Library.title(id) }
}

/// How a model fits this Mac's memory now.
enum Fit: Sendable {
    case whole, hotExperts, mayPage, tooLarge, unknown
}

enum Library {
    static func scan(cache: URL, adapters: URL) -> [ModelInfo] {
        ModelCache.models(at: cache).compactMap { id in
            let repository = cache.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
            guard let snapshot = newestSnapshot(repository) else { return nil }
            let config = (try? ModelCache.json(snapshot.appending(path: "config.json"))) ?? [:]
            let text = config["text_config"] as? [String: Any] ?? config
            let quantization = config["quantization"] as? [String: Any] ?? text["quantization"] as? [String: Any]
            let context = (text["max_position_embeddings"] as? Int) ?? (config["max_position_embeddings"] as? Int)
            return ModelInfo(
                id: id, repository: repository, snapshot: snapshot,
                weights: weights(snapshot), disk: size(of: repository.appending(path: "blobs")),
                type: (config["model_type"] as? String) ?? "?",
                mixture: ((text["num_experts"] as? Int) ?? 0) > 0,
                bits: quantization?["bits"] as? Int, context: context,
                adapters: adaptersFor(id, root: adapters)
            )
        }
    }

    static func title(_ id: String) -> String {
        var name = String(id.split(separator: "/").last ?? Substring(id))
        for tail in ["-MLX", "-mlx"] { name = name.replacingOccurrences(of: tail, with: "") }
        name = name.replacingOccurrences(of: #"-\d+bit"#, with: "", options: .regularExpression)
        return name.replacingOccurrences(of: "-", with: " ")
    }

    static func fit(_ model: ModelInfo, room: Int64?) -> Fit {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        if model.weights > physical * 3 / 4 && !model.mixture { return .tooLarge }
        guard let room else { return .unknown }
        if model.weights + model.weights / 10 <= room { return .whole }
        return model.mixture ? .hotExperts : .mayPage
    }

    private static func newestSnapshot(_ repository: URL) -> URL? {
        let snapshots = (try? FileManager.default.contentsOfDirectory(
            at: repository.appending(path: "snapshots"), includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return snapshots.max {
            let a = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let b = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (a ?? .distantPast) < (b ?? .distantPast)
        }
    }

    private static func weights(_ snapshot: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.reduce(Int64(0)) { sum, file in
            let real = file.resolvingSymlinksInPath()
            return sum + Int64((try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func size(of directory: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    private static func adaptersFor(_ id: String, root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let file = id.replacingOccurrences(of: "/", with: "--") + ".safetensors"
        return names.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).appending(path: file).path) }
            .sorted()
    }

    /// The model's repository removed from the cache: every snapshot and blob.
    static func delete(_ model: ModelInfo) throws {
        try FileManager.default.removeItem(at: model.repository)
    }
}

/// ~/.config/okay-mlx/models.json: the owner's settings by model ("*" for all), as okay-mlx's `Settings` reads them.
/// The server reads a model's settings when it loads it.
struct SettingsFile: Sendable {
    static let fields = ["temperature", "top_p", "top_k", "presence_penalty", "frequency_penalty",
                         "expert_slots", "guesses", "drafts"]
    let url: URL

    init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        url = environment["OKAY_MLX_MODELS"].map { URL(fileURLWithPath: $0) } ??
            home.appending(path: ".config/okay-mlx/models.json")
    }

    func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func entry(_ key: String) -> [String: Any] { read()[key] as? [String: Any] ?? [:] }

    /// The fields of `key` set (`.remove` removes the field); an entry left empty is removed.
    func update(_ key: String, _ values: [String: SettingValue]) throws {
        var all = read()
        var entry = all[key] as? [String: Any] ?? [:]
        for (field, value) in values {
            switch value {
            case .int(let v): entry[field] = v
            case .double(let v): entry[field] = v
            case .bool(let v): entry[field] = v
            case .remove: entry.removeValue(forKey: field)
            }
        }
        all[key] = entry.isEmpty ? nil : entry
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Hidden from clients: as set, else a model built here (`local/…`, research derivatives) is hidden.
    func hidden(_ id: String) -> Bool { entry(id)["hidden"] as? Bool ?? id.hasPrefix("local/") }
    var unloadAfter: Int { entry("*")["unload_after_minutes"] as? Int ?? 0 }
}

/// A value written to models.json, or the field removed.
enum SettingValue: Sendable {
    case int(Int), double(Double), bool(Bool), remove
}
