import Foundation

enum ModelCache {
    static func root(home: URL, environment: [String: String]) -> URL {
        if let path = environment["HF_HUB_CACHE"] { return URL(fileURLWithPath: path) }
        if let path = environment["HF_HOME"] { return URL(fileURLWithPath: path).appending(path: "hub") }
        return home.appending(path: ".cache/huggingface/hub")
    }

    static func models(at root: URL) -> [String] {
        let files = FileManager.default
        let repositories = (try? files.contentsOfDirectory(
            at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil
        )) ?? []
        return repositories.compactMap { repo in
            let name = repo.lastPathComponent
            guard name.hasPrefix("models--"), !name.contains("Embedding") else { return nil }
            let snapshots = (try? files.contentsOfDirectory(
                at: repo.appending(path: "snapshots"), includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let newest = snapshots.max {
                let a = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let b = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (a ?? .distantPast) < (b ?? .distantPast)
            }
            guard let newest, (try? validate(newest)) != nil else { return nil }
            return String(name.dropFirst(8)).replacingOccurrences(of: "--", with: "/", range: nil)
        }.sorted()
    }

    static func validate(_ snapshot: URL) throws {
        let config = try json(snapshot.appending(path: "config.json"))
        guard let type = config["model_type"] as? String,
              ["qwen3", "qwen3_5", "qwen3_5_moe"].contains(type) else {
            throw InstallFailure(String(localized: "This model architecture is not supported by okay-mlx."))
        }
        let tokenizer = snapshot.appending(path: "tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizer.path) else {
            throw InstallFailure(String(localized: "The model is missing its tokenizer."))
        }
        let template = snapshot.appending(path: "chat_template.jinja")
        if !FileManager.default.fileExists(atPath: template.path) {
            let settings = try json(snapshot.appending(path: "tokenizer_config.json"))
            guard settings["chat_template"] != nil else {
                throw InstallFailure(String(localized: "The model is missing its chat template."))
            }
        }
        let index = snapshot.appending(path: "model.safetensors.index.json")
        let weights: Set<String>
        if FileManager.default.fileExists(atPath: index.path) {
            guard let map = try json(index)["weight_map"] as? [String: String], !map.isEmpty else {
                throw InstallFailure(String(localized: "The model weight index is invalid."))
            }
            weights = Set(map.values)
        } else {
            weights = ["model.safetensors"]
        }
        for name in weights {
            // a cached file is a symlink into blobs/: its size is the blob's, not the link's
            guard safePath(name), let size = try? snapshot.appending(path: name).resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw InstallFailure(String(localized: "The model download is incomplete."))
            }
            try validateWeights(snapshot.appending(path: name).resolvingSymlinksInPath(), size: size)
        }
    }

    private static func validateWeights(_ file: URL, size: Int) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count == 8, size >= 8 else {
            throw InstallFailure(String(localized: "The model download is incomplete."))
        }
        let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length <= UInt64(min(size - 8, 64 * 1024 * 1024)),
              let data = try handle.read(upToCount: Int(length)),
              let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallFailure(String(localized: "The model weight index is invalid."))
        }
        for (name, tensor) in header where name != "__metadata__" {
            guard let offsets = (tensor as? [String: Any])?["data_offsets"] as? [UInt64],
                  offsets.count == 2, offsets[0] <= offsets[1],
                  offsets[1] <= UInt64(size - 8) - length else {
                throw InstallFailure(String(localized: "The model download is incomplete."))
            }
        }
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func json(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw InstallFailure(String(localized: "The downloaded metadata is invalid."))
        }
        return object
    }
}

struct InstallFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
