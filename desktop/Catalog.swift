import Foundation
import SwiftUI

/// Models found on Hugging Face (spec §3.1): one request to the hub's model list with each model's config and
/// parameter counts expanded, the architectures okay-mlx runs kept, each with its size in memory.
enum Catalog {
    static let supported: Set<String> = ["qwen3", "qwen3_5", "qwen3_5_moe"]

    struct Found: Identifiable, Sendable, Hashable {
        let id: String
        let type: String
        let bits: Int?
        /// The weights' bytes, from the hub's parameter counts (an estimate within a few percent).
        let bytes: Int64
        let downloads: Int
        let mixture: Bool
        var title: String { Library.title(id) }
    }

    private struct Model: Decodable {
        struct Config: Decodable {
            struct Quantization: Decodable { let bits: Int?; let group_size: Int? }
            let model_type: String?
            let quantization_config: Quantization?
            let quantization: Quantization?
        }
        struct Tensors: Decodable { let parameters: [String: Int64] }
        let id: String
        let config: Config?
        let safetensors: Tensors?
        let downloads: Int?
    }

    /// `query` searched among `author`'s models (empty author: everyone's), most downloaded first.
    static func search(_ query: String, author: String = "mlx-community", limit: Int = 60) async throws -> [Found] {
        var parts = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        for field in ["config", "safetensors", "downloads"] { items.append(URLQueryItem(name: "expand[]", value: field)) }
        parts.queryItems = items
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("okay-mlx-desktop", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallFailure(String(localized: "Hugging Face search failed. Check the connection."))
        }
        return try JSONDecoder().decode([Model].self, from: data).compactMap { model in
            guard let type = model.config?.model_type, supported.contains(type),
                  !model.id.contains("Embedding"), let counts = model.safetensors?.parameters else { return nil }
            let quantization = model.config?.quantization_config ?? model.config?.quantization
            return Found(id: model.id, type: type, bits: quantization?.bits,
                         bytes: bytes(counts, bits: quantization?.bits, group: quantization?.group_size ?? 64),
                         downloads: model.downloads ?? 0, mixture: type.hasSuffix("_moe"))
        }
    }

    /// The bytes of weights the hub counts as parameters. It counts a quantized tensor (U32) two ways, by repository:
    /// as its logical weights (then each is `bits` wide, plus a BF16 scale and bias a group, not counted apart) or as
    /// its packed words (4 bytes each; the scales and biases counted in BF16 — nearly as many as the words). The
    /// ratio tells which: mlx-community/Qwen3.5-4B-MLX-4bit 4.2e9 U32, 0.33e9 BF16 (logical); …/Qwen3.5-4B-4bit
    /// 0.53e9 U32, 0.47e9 BF16 (packed) — both 3.03 GB, as the files are.
    static func bytes(_ counts: [String: Int64], bits: Int?, group: Int) -> Int64 {
        let words = counts["U32"] ?? 0
        let halves = counts["BF16"] ?? 0
        let packed = bits.map { words > 0 && Double(halves) / Double(words) > 1.5 / Double($0) } ?? true
        return counts.reduce(Int64(0)) { sum, entry in
            let (dtype, n) = entry
            switch dtype {
            case "U32" where bits != nil && !packed:
                return sum + n * Int64(bits!) / 8 + n * 4 / Int64(max(group, 1))
            case "BF16", "F16", "I16", "U16": return sum + n * 2
            case "U8", "I8", "F8_E4M3", "F8_E5M2": return sum + n
            case "F64", "I64", "U64": return sum + n * 8
            default: return sum + n * 4
            }
        }
    }
}

/// The Models tab's search: models found on Hugging Face, each with its size, whether it fits, and Download.
struct CatalogView: View {
    let status: Service.Status
    let busy: Bool
    @ObservedObject var installer: InstallModel
    @ObservedObject var library: LibraryModel
    let completed: @MainActor () async -> Void
    @State private var query = "Qwen3.5"
    @State private var everyone = false
    @State private var found: [Catalog.Found] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search Hugging Face", text: $query, prompt: Text("Qwen3.5, Qwen3.6 35B, 8bit…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Picker("Author", selection: $everyone) {
                    Text("mlx-community").tag(false)
                    Text("Everyone").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Button("Search", action: search).buttonStyle(.borderedProminent)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if searching {
                ProgressView().controlSize(.small)
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            List(found) { model in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).font(.body.weight(.semibold))
                        Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            tag(model.bytes.formatted(.byteCount(style: .memory)))
                            if model.mixture { tag("MoE") }
                            if let bits = model.bits { tag("\(bits)-bit") } else { tag("bf16") }
                            tag(String(localized: "\(model.downloads.formatted()) downloads"))
                            FitBadge(weights: model.bytes, mixture: model.mixture,
                                     room: library.admin?.room)
                        }
                    }
                    Spacer()
                    if library.models.contains(where: { $0.id == model.id }) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else {
                        Button("Download") {
                            installer.model(model.id, cache: status.modelCache, completed: completed)
                        }
                        .disabled(installer.running || busy)
                    }
                }
                .padding(.vertical, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if found.isEmpty && !searching {
                    Text("Only the architectures okay-mlx runs are shown: Qwen3, Qwen3.5, Qwen3.6, Qwen3.8.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
            Divider()
            ModelDownloadView(status: status, busy: busy, installer: installer, completed: completed)
        }
        .task { if found.isEmpty { search() } }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        error = nil
        let author = everyone ? "" : "mlx-community"
        Task {
            do { found = try await Catalog.search(text, author: author) } catch {
                self.error = error.localizedDescription
                found = []
            }
            searching = false
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}
