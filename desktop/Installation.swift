import CryptoKit
import Darwin
import Foundation

struct Installation: Sendable {
    struct Progress: Sendable {
        let file: String
        let completed: Int64
        let total: Int64
    }
    typealias Report = @Sendable (Progress) -> Void

    let home: URL
    private var files: FileManager { .default }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
    }

    private struct Repository: Decodable {
        struct File: Decodable {
            let rfilename: String
            let size: Int64?
        }
        let sha: String
        let siblings: [File]
    }

    func installServer(report: @escaping Report) async throws {
        let root = home.appending(path: ".okay-mlx")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try FileLock(root.appending(path: "install.lock"))
        defer { lock.unlock() }
        let binary = root.appending(path: "bin/okay-mlx")
        guard !files.isExecutableFile(atPath: binary.path) else { return }
        let release: Release = try await metadata(
            URL(string: "https://api.github.com/repos/okay-effects/okay-mlx/releases/latest")!
        )
        guard let asset = release.assets.first(where: { $0.name == "okay-mlx-macos-arm64.tar.gz" }),
              asset.size > 0, let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw InstallFailure(String(localized: "The release has no verified Apple Silicon archive."))
        }
        let stage = root.appending(path: ".install-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        var keepBackup = false
        defer { if !keepBackup { try? files.removeItem(at: stage) } }
        let archive = stage.appending(path: "release.tar.gz")
        try await download(asset.browser_download_url, to: archive, size: asset.size, report: report)
        report(Progress(file: String(localized: "Verifying server archive…"), completed: 0, total: 0))
        guard try sha256(archive) == String(digest.dropFirst(7)) else {
            throw InstallFailure(String(localized: "The server archive checksum does not match."))
        }
        try Task.checkCancellation()
        let entries = try await command("/usr/bin/tar", ["-tzf", archive.path])
        guard entries.split(separator: "\n").allSatisfy({ entry in
            let name = String(entry).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !entry.hasPrefix("/") && ModelCache.safePath(name)
        }) else { throw InstallFailure(String(localized: "The server archive contains invalid paths.")) }
        let payload = stage.appending(path: "payload")
        try files.createDirectory(at: payload, withIntermediateDirectories: true)
        _ = try await command("/usr/bin/tar", ["-xzf", archive.path, "-C", payload.path])
        for name in ["bin/okay-mlx", "lib/libokm.dylib", "lib/libmlx.dylib", "lib/libmlxc.dylib", "lib/mlx.metallib"] {
            let file = payload.appending(path: name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw InstallFailure(String(localized: "The server archive is incomplete."))
            }
        }
        guard files.isExecutableFile(atPath: payload.appending(path: "bin/okay-mlx").path) else {
            throw InstallFailure(String(localized: "The server archive is incomplete."))
        }
        try Task.checkCancellation()
        // Install the libraries before publishing the executable. Restore existing directories on failure.
        var saved: [String] = []
        var installed: [String] = []
        do {
            for name in ["lib", "bin"] {
                let target = root.appending(path: name)
                if files.fileExists(atPath: target.path) {
                    try files.moveItem(at: target, to: stage.appending(path: "old-\(name)"))
                    saved.append(name)
                }
                try files.moveItem(at: payload.appending(path: name), to: target)
                installed.append(name)
            }
        } catch {
            let original = error
            do {
                for name in installed.reversed() { try files.removeItem(at: root.appending(path: name)) }
                for name in saved.reversed() {
                    try files.moveItem(at: stage.appending(path: "old-\(name)"), to: root.appending(path: name))
                }
            } catch {
                keepBackup = true
                throw InstallFailure(String(localized: "Installation failed. Backup files remain at \(stage.path)."))
            }
            throw original
        }
    }

    func downloadModel(_ input: String, cache: URL, report: @escaping Report) async throws {
        let repo = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }), !repo.contains("--"), !repo.contains("Embedding") else {
            throw InstallFailure(String(localized: "Enter a model ID such as mlx-community/Qwen3-0.6B-4bit."))
        }
        let meta: Repository = try await metadata(
            URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!, authenticated: true
        )
        guard meta.sha.count == 40, meta.sha.allSatisfy(\.isHexDigit) else {
            throw InstallFailure(String(localized: "The downloaded metadata is invalid."))
        }
        let selected = meta.siblings.filter {
            let name = $0.rfilename
            return !name.hasPrefix(".") &&
                (name.hasSuffix(".json") || name.hasSuffix(".safetensors") ||
                 name.hasSuffix(".jinja") || name.hasSuffix(".txt") || name.hasSuffix(".model"))
        }
        guard !selected.isEmpty, selected.allSatisfy({ ModelCache.safePath($0.rfilename) && ($0.size ?? 0) > 0 }),
              Set(selected.map(\.rfilename)).count == selected.count else {
            throw InstallFailure(String(localized: "The downloaded metadata is invalid."))
        }
        let repository = cache.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
        try files.createDirectory(at: repository, withIntermediateDirectories: true)
        let lock = try FileLock(repository.appending(path: "okay-mlx-download.lock"))
        defer { lock.unlock() }
        let target = repository.appending(path: "snapshots/\(meta.sha)")
        if files.fileExists(atPath: target.path), (try? ModelCache.validate(target)) != nil { return }
        // Keep partial downloads outside snapshots so the running server cannot see an incomplete model.
        let stage = repository.appending(path: ".okay-mlx-download/\(meta.sha)")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        var completed: Int64 = 0
        let total = selected.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        for file in selected {
            try Task.checkCancellation()
            let local = stage.appending(path: file.rfilename)
            if (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size!) {
                completed += file.size!
            }
        }
        let remaining = total - completed
        let capacity = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < remaining + 256 * 1024 * 1024 {
            throw InstallFailure(String(localized: "There is not enough free disk space for this model."))
        }
        // Fetch config first and reject unsupported architectures before downloading weights.
        guard let config = selected.first(where: { $0.rfilename == "config.json" }) else {
            throw InstallFailure(String(localized: "The model download is incomplete."))
        }
        let configURL = stage.appending(path: "config.json")
        if (try? configURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) != Int(config.size!) {
            try await download(
                URL(string: "https://huggingface.co/\(repo)/resolve/\(meta.sha)/config.json")!,
                to: configURL, size: config.size!, authenticated: true, report: report
            )
            completed += config.size!
        }
        let type = try ModelCache.json(configURL)["model_type"] as? String
        guard ["qwen3", "qwen3_5", "qwen3_5_moe"].contains(type ?? "") else {
            throw InstallFailure(String(localized: "This model architecture is not supported by okay-mlx."))
        }
        for file in selected where file.rfilename != "config.json" {
            try Task.checkCancellation()
            let local = stage.appending(path: file.rfilename)
            if (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size!) { continue }
            let before = completed
            let url = URL(string: "https://huggingface.co")!
                .appending(path: repo).appending(path: "resolve/\(meta.sha)").appending(path: file.rfilename)
            try await download(url, to: local, size: file.size!, authenticated: true) { update in
                report(Progress(file: file.rfilename, completed: before + update.completed, total: total))
            }
            completed += file.size!
        }
        try ModelCache.validate(stage)
        try Task.checkCancellation()
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) {
            // Preserve an older partial snapshot while publishing the completed replacement.
            let backup = repository.appending(path: ".incomplete-\(UUID().uuidString)")
            try files.moveItem(at: target, to: backup)
            do {
                try files.moveItem(at: stage, to: target)
            } catch {
                try files.moveItem(at: backup, to: target)
                throw error
            }
            try? files.removeItem(at: backup)
        } else {
            try files.moveItem(at: stage, to: target)
        }
        report(Progress(file: repo, completed: total, total: total))
    }

    private func metadata<T: Decodable>(_ url: URL, authenticated: Bool = false) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(url, authenticated: authenticated))
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(_ url: URL, authenticated: Bool) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("okay-mlx-desktop", forHTTPHeaderField: "User-Agent")
        if authenticated {
            let environment = ProcessInfo.processInfo.environment
            let hfHome = environment["HF_HOME"].map { URL(fileURLWithPath: $0) } ??
                home.appending(path: ".cache/huggingface")
            let tokenFile = environment["HF_TOKEN_PATH"].map { URL(fileURLWithPath: $0) } ??
                hfHome.appending(path: "token")
            let token = environment["HF_TOKEN"] ?? (try? String(contentsOf: tokenFile, encoding: .utf8))
            if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private func download(
        _ url: URL, to target: URL, size: Int64, authenticated: Bool = false, report: @escaping Report
    ) async throws {
        let delegate = DownloadProgress(report: report)
        let (temporary, response) = try await URLSession.shared.download(
            for: request(url, authenticated: authenticated), delegate: delegate
        )
        defer { try? files.removeItem(at: temporary) }
        try check(response)
        let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actual == Int(size) else {
            throw InstallFailure(String(localized: "The downloaded file size does not match. Please retry."))
        }
        try Task.checkCancellation()
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        try files.moveItem(at: temporary, to: target)
        report(Progress(file: target.lastPathComponent, completed: size, total: size))
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(localized: "Download failed (HTTP \(code)). Check the model ID and connection.")
            throw InstallFailure(message)
        }
    }

    private func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func command(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            task.standardOutput = pipe
            task.standardError = pipe
            try task.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                throw InstallFailure(String(decoding: output, as: UTF8.self))
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: Installation.Report
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    init(report: @escaping Installation.Report) { self.report = report }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {}
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let now = Date()
        let finished = totalBytesWritten == totalBytesExpectedToWrite
        let shouldReport = now.timeIntervalSince(lastReport) >= 0.2 || finished
        if shouldReport { lastReport = now }
        lock.unlock()
        guard shouldReport else { return }
        report(Installation.Progress(
            file: downloadTask.originalRequest?.url?.lastPathComponent ?? "",
            completed: totalBytesWritten, total: totalBytesExpectedToWrite
        ))
    }
}

private final class FileLock {
    private let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw InstallFailure(String(localized: "Another installation is already in progress."))
        }
    }
    func unlock() { flock(descriptor, LOCK_UN) }
    deinit { close(descriptor) }
}
