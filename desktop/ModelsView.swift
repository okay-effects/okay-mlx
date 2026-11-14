import AppKit
import SwiftUI

/// The models on this Mac and the one in memory: what the panel reads and does beyond the service itself.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var admin: Admin.Status?
    @Published private(set) var adminError: String?
    @Published private(set) var openCode = OpenCode.State()
    @Published private(set) var chamber = OpenChamber.State()
    /// What OpenChamber's own API says (its models, its default), when it runs and lets the panel in.
    @Published private(set) var chamberAPI: ChamberAPI.State?
    @Published private(set) var chamberAPIError: String?
    @Published var pairing: ChamberAPI.Pairing?
    @Published private(set) var working: String?
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var unloadAfter = 0
    @Published var error: String?
    @Published var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSyncOpenCode") }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    var settings: SettingsFile { SettingsFile(home: home) }
    private var endpoint = "http://127.0.0.1:8090"
    private var scanning = false
    private var lastScan = Date.distantPast

    init() {
        autoSync = UserDefaults.standard.object(forKey: "autoSyncOpenCode") as? Bool ?? true
    }

    /// The library read again: the server at once, the disk (the cache, opencode, OpenChamber) when `rescan` or every
    /// 30 s — a model's blobs are walked to size them.
    func refresh(_ status: Service.Status, rescan: Bool = false) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        endpoint = status.endpoint
        let cache = status.modelCache
        let home = self.home
        let adapters = ProcessInfo.processInfo.environment["OKAY_MLX_ADAPTERS"].map { URL(fileURLWithPath: $0) } ??
            home.appending(path: ".okay-mlx/adapters")
        let stale = rescan || models.isEmpty || Date().timeIntervalSince(lastScan) > 30
        let (found, code, chamber) = stale
            ? await Task.detached {
                (Library.scan(cache: cache, adapters: adapters), OpenCode(home: home).state(),
                 OpenChamber(home: home).state())
            }.value
            : (models, openCode, self.chamber)
        if stale { lastScan = Date() }
        if stale && chamber.running {
            do {
                chamberAPI = try await ChamberAPI(base: chamber.url, home: home).state()
                chamberAPIError = nil
            } catch {
                chamberAPI = nil
                chamberAPIError = error.localizedDescription
            }
        } else if !chamber.running {
            chamberAPI = nil
        }
        let scanned = found
        let file = settings
        let entries = file.read()
        let hiddenNow = Set(scanned.map(\.id).filter {
            (entries[$0] as? [String: Any])?["hidden"] as? Bool ?? $0.hasPrefix("local/") })
        models = scanned.sorted { (hiddenNow.contains($0.id) ? 1 : 0, $0.id) < (hiddenNow.contains($1.id) ? 1 : 0, $1.id) }
        openCode = code
        self.chamber = chamber
        hidden = hiddenNow
        unloadAfter = file.unloadAfter
        if status.pid != nil {
            do {
                admin = try await Admin(endpoint: endpoint).status()
                adminError = nil
            } catch {
                admin = nil
                adminError = error.localizedDescription
            }
        } else {
            admin = nil
            adminError = nil
        }
        if autoSync && !inSync && openCode.readable { syncOpenCode(quietly: true) }
    }

    // MARK: models in memory

    func load(_ id: String, reload: Bool = false) {
        act(reload ? String(localized: "Reloading \(id)…") : String(localized: "Loading \(id)…")) { [endpoint] in
            try await Admin(endpoint: endpoint).load(id, reload: reload)
        }
    }

    func unload(force: Bool = false) {
        act(String(localized: "Unloading…")) { [endpoint] in try await Admin(endpoint: endpoint).unload(force: force) }
    }

    func setUnloadAfter(_ minutes: Int) {
        act(nil) { [settings] in try settings.update("*", ["unload_after_minutes": minutes == 0 ? .remove : .int(minutes)]) }
    }

    // MARK: the library

    func setStartup(_ id: String) {
        act(nil) { try Service().setStartupModel(id) }
    }

    func toggleHidden(_ id: String) {
        let hide = !hidden.contains(id)
        act(nil) { [settings] in try settings.update(id, ["hidden": hide ? .bool(true) : (id.hasPrefix("local/") ? .bool(false) : .remove)]) }
    }

    func save(_ id: String, _ values: [String: SettingValue], reloadNow: Bool) {
        act(nil) { [settings, endpoint] in
            try settings.update(id, values)
            if reloadNow { try await Admin(endpoint: endpoint).load(id, reload: true) }
        }
    }

    func delete(_ model: ModelInfo) {
        let loaded = admin?.loaded?.model == model.id
        act(String(localized: "Deleting \(model.id)…")) { [endpoint] in
            if loaded { try await Admin(endpoint: endpoint).unload() }
            try await Task.detached { try Library.delete(model) }.value
        }
    }

    // MARK: clients

    /// The models opencode should list: those not hidden, with their adapters.
    var offered: [(id: String, title: String, context: Int?)] {
        models.filter { !hidden.contains($0.id) }.flatMap { model in
            [(model.id, model.title, model.context)] +
                model.adapters.map { ("\(model.id)+\($0)", "\(model.title) + \($0)", model.context) }
        }
    }

    var inSync: Bool {
        openCode.listed.sorted() == offered.map(\.id).sorted() && openCode.baseURL == endpoint + "/v1"
    }

    func syncOpenCode(quietly: Bool = false) {
        let offered = offered
        let home = home
        act(quietly ? nil : String(localized: "Updating opencode…")) { [endpoint] in
            try await Task.detached { try OpenCode(home: home).sync(offered, endpoint: endpoint) }.value
        }
    }

    func setChamberDefault(_ model: String?) {
        let api = ChamberAPI(base: chamber.url, home: home)
        act(nil) { try await api.setDefault(model) }
    }

    func pair() {
        let api = ChamberAPI(base: chamber.url, home: home)
        act(String(localized: "Making a pairing link…")) { [weak self] in
            let link = try await api.pair()
            await MainActor.run { self?.pairing = link }
        }
    }

    func restartChamber() {
        let home = home
        act(String(localized: "Restarting OpenChamber…")) {
            try await Task.detached { try OpenChamber(home: home).restart() }.value
        }
    }

    private func act(_ title: String?, _ work: @escaping @Sendable () async throws -> Void) {
        guard working == nil else { return }
        working = title ?? ""
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = nil
            await refreshAfterAction()
        }
    }

    /// Set by the panel: reads the service again after an action.
    var refreshAfterAction: @MainActor () async -> Void = {}
}

struct ModelsView: View {
    let status: Service.Status
    let busy: Bool
    @ObservedObject var installer: InstallModel
    @ObservedObject var library: LibraryModel
    let completed: @MainActor () async -> Void
    @State private var editing: ModelInfo?
    // OKAY_MLX_PANEL_FIND opens the search (screenshots, scripts)
    @State private var finding = ProcessInfo.processInfo.environment["OKAY_MLX_PANEL_FIND"] != nil
    @State private var deleting: ModelInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Models", selection: $finding) {
                Text("Downloaded").tag(false)
                Text("Find on Hugging Face").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if finding {
                CatalogView(status: status, busy: busy, installer: installer, library: library, completed: completed)
            } else {
            HStack {
                Text("Downloaded models").font(.headline)
                Spacer()
                if let working = library.working, !working.isEmpty {
                    ProgressView().controlSize(.small)
                    Text(working).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if library.models.isEmpty {
                Text("Download a model to get started.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(library.models) { model in
                    row(model)
                        .padding(.vertical, 4)
                        .contextMenu { menu(model) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text("Hidden models stay on disk and still load when a client names them; clients just do not list them.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { model in
            ModelSettingsSheet(model: model, library: library, loaded: library.admin?.loaded?.model == model.id)
        }
        .confirmationDialog(
            "Delete \(deleting?.id ?? "")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), presenting: deleting
        ) { model in
            Button("Delete \(model.disk.formatted(.byteCount(style: .file)))", role: .destructive) {
                library.delete(model)
            }
        } message: { model in
            if model.id == status.startupModel {
                Text("This is the startup model: the service will start with no model until you choose another.")
            } else {
                Text("The files are removed from the Hugging Face cache. You can download the model again later.")
            }
        }
    }

    private func row(_ model: ModelInfo) -> some View {
        let loaded = library.admin?.loaded?.model == model.id
        let loading = library.admin?.loading == model.id
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.title).font(.body.weight(.semibold))
                    if model.id == status.startupModel {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).help("Startup model")
                    }
                    if library.hidden.contains(model.id) {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Hidden from clients")
                    }
                }
                Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    tag(model.weights.formatted(.byteCount(style: .memory)))
                    if model.mixture { tag("MoE") }
                    if let bits = model.bits { tag("\(bits)-bit") }
                    if let context = model.context { tag("\(context / 1024)K ctx") }
                    if !model.adapters.isEmpty { tag("+\(model.adapters.joined(separator: ", "))") }
                    fit(model, loaded: loaded)
                }
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else if loaded {
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Loaded", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.green)
                    Button("Unload") { library.unload() }
                        .disabled(library.working != nil)
                }
            } else {
                Button("Load") { library.load(model.id) }
                    .disabled(library.working != nil || library.admin == nil)
                    .help(library.admin == nil ? "Start the service to load a model." : "Load this model now.")
            }
            Menu {
                menu(model)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func menu(_ model: ModelInfo) -> some View {
        let loaded = library.admin?.loaded?.model == model.id
        if loaded {
            Button("Reload with current settings") { library.load(model.id, reload: true) }
        }
        Button("Settings…") { editing = model }
        Button("Set as startup model") { library.setStartup(model.id) }
            .disabled(model.id == status.startupModel)
        Button(library.hidden.contains(model.id) ? "Show in clients" : "Hide from clients") {
            library.toggleHidden(model.id)
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.snapshot]) }
        Button("Copy model ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.id, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = model }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func fit(_ model: ModelInfo, loaded: Bool) -> some View {
        FitBadge(weights: model.weights, mixture: model.mixture, room: library.admin?.room)
    }
}

/// Whether a model of these weights fits the memory free now (the server's room), as a small tag.
struct FitBadge: View {
    let weights: Int64
    let mixture: Bool
    let room: Int64?

    var body: some View {
        switch Library.fit(weights, mixture: mixture, room: room) {
        case .whole:
            tag(String(localized: "fits")).foregroundStyle(.green)
        case .hotExperts:
            tag(String(localized: "hot experts")).foregroundStyle(.orange)
                .help("Not enough free memory to hold it whole: it runs with its most used experts in memory, slower.")
        case .mayPage:
            tag(String(localized: "may be slow")).foregroundStyle(.orange)
                .help("Not enough free memory now: the system may page it and generation becomes slow.")
        case .tooLarge:
            tag(String(localized: "too large")).foregroundStyle(.red)
                .help("Larger than this Mac can hold.")
        case .unknown:
            EmptyView()
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

/// A model's settings as okay-mlx reads them from models.json when it loads the model: sampling, and how it runs.
struct ModelSettingsSheet: View {
    let model: ModelInfo
    @ObservedObject var library: LibraryModel
    let loaded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var reloadNow = true

    private let labels: [(key: String, title: LocalizedStringKey, help: LocalizedStringKey)] = [
        ("temperature", "Temperature", "Randomness of sampling; 0 is greedy."),
        ("top_p", "Top P", "Nucleus sampling share, 0–1."),
        ("top_k", "Top K", "Candidates considered per token; 0 for all."),
        ("presence_penalty", "Presence penalty", "Discourages repeating tokens already used, 0–2."),
        ("frequency_penalty", "Frequency penalty", "Discourages frequent tokens, 0–2."),
        ("expert_slots", "Hot experts per layer", "Mixture of experts only: experts kept in memory; 0 holds all. Empty: chosen by free memory."),
        ("guesses", "Guesses per pass", "Tokens guessed from the text and checked at once; 0 turns it off."),
        ("drafts", "Own drafts per pass", "Tokens the model drafts itself when it has a draft layer; 0 turns it off.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title).font(.title3.weight(.semibold))
            Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            Form {
                ForEach(labels, id: \.key) { field in
                    TextField(field.title, text: Binding(
                        get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }
                    ), prompt: Text("default"))
                    .help(field.help)
                }
            }
            .formStyle(.grouped)
            Text("Empty fields use the model's own defaults. Requests that set a value themselves override these.")
                .font(.caption).foregroundStyle(.secondary)
            if loaded {
                Toggle("Reload the model now to apply", isOn: $reloadNow)
            } else {
                Text("Applies the next time the model loads.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    library.save(model.id, parsed(), reloadNow: loaded && reloadNow)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(invalid)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            let entry = library.settings.entry(model.id)
            for field in SettingsFile.fields {
                if let value = entry[field] { values[field] = "\(value)" }
            }
        }
    }

    private var invalid: Bool {
        values.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && number($0.key, $0.value) == nil }
    }

    private func number(_ key: String, _ text: String) -> SettingValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if ["top_k", "expert_slots", "guesses", "drafts"].contains(key) {
            return Int(trimmed).flatMap { $0 >= 0 ? .int($0) : nil }
        }
        return Double(trimmed).flatMap { $0 >= 0 ? .double($0) : nil }
    }

    private func parsed() -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for field in SettingsFile.fields {
            let text = values[field]?.trimmingCharacters(in: .whitespaces) ?? ""
            out[field] = text.isEmpty ? .remove : number(field, text) ?? .remove
        }
        return out
    }
}
