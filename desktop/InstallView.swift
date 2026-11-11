import SwiftUI

@MainActor
final class InstallModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progress: Installation.Progress?
    @Published private(set) var title = ""
    @Published private(set) var result: String?
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()

    func server(_ status: Service.Status, completed: @escaping @MainActor () async -> Void) {
        start(String(localized: "Installing server…"), completed: completed) { report in
            let service = Service()
            let installer = Installation(home: service.home)
            try await installer.installServer(report: report)
            if !status.cachedModels.contains(status.startupModel) {
                report(Installation.Progress(file: status.startupModel, completed: 0, total: 0))
                try await installer.downloadModel(status.startupModel, cache: status.modelCache, report: report)
            }
            try Task.checkCancellation()
            try await service.perform(.start)
        }
    }

    func model(_ repo: String, cache: URL, completed: @escaping @MainActor () async -> Void) {
        start(String(localized: "Downloading model…"), completed: completed) { report in
            try await Installation(home: FileManager.default.homeDirectoryForCurrentUser)
                .downloadModel(repo, cache: cache, report: report)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func start(
        _ title: String, completed: @escaping @MainActor () async -> Void,
        work: @escaping @Sendable (@escaping Installation.Report) async throws -> Void
    ) {
        guard !running else { return }
        running = true
        progress = nil
        result = nil
        error = nil
        self.title = title
        operation = UUID()
        let currentOperation = operation
        task = Task { [self] in
            do {
                try await work { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.running, self.operation == currentOperation else { return }
                        self.progress = update
                    }
                }
                result = String(localized: "Installation complete.")
            } catch {
                if Task.isCancelled {
                    result = String(localized: "Download cancelled. Retry to reuse completed files.")
                } else {
                    self.error = error.localizedDescription
                }
            }
            running = false
            task = nil
            await completed()
        }
    }
}

struct InstallProgressView: View {
    @ObservedObject var installer: InstallModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if installer.running {
                HStack {
                    Text(installer.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Cancel") { installer.cancel() }
                }
                if let progress = installer.progress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    Text("\(bytes(progress.completed)) / \(bytes(progress.total))")
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView().controlSize(.small)
                }
                if let file = installer.progress?.file {
                    Text(file).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if let result = installer.result {
                Text(result).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }
}

struct ModelDownloadView: View {
    let status: Service.Status
    let busy: Bool
    @ObservedObject var installer: InstallModel
    let completed: @MainActor () async -> Void
    @State private var repo = Service.defaultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Download a model").font(.headline)
            HStack {
                TextField("Hugging Face model ID", text: $repo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)
                Button("Download", action: download).buttonStyle(.borderedProminent)
                    .disabled(repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(installer.running || busy)
            Text("Source: huggingface.co · Supported architectures: Qwen3 and Qwen3.5.")
                .font(.caption).foregroundStyle(.secondary)
            Text(status.modelCache.path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func download() {
        guard !installer.running, !busy else { return }
        installer.model(repo, cache: status.modelCache, completed: completed)
    }
}
