import AppKit
import SwiftUI

@main
struct OkayMLX: App {
    var body: some Scene {
        Window("okay-mlx", id: "control-panel") {
            ControlPanel()
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class PanelModel: ObservableObject {
    @Published private(set) var status: Service.Status?
    @Published private(set) var busy = false
    @Published private(set) var refreshError: String?
    @Published var actionError: String?

    private let service = Service()
    private var revision = 0
    private var refreshing = false

    func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await read(revision)
    }

    private func read(_ expected: Int) async {
        do {
            let latest = try await service.status()
            guard expected == revision else { return }
            status = latest
            refreshError = nil
        } catch {
            guard expected == revision else { return }
            refreshError = error.localizedDescription
        }
    }

    func perform(_ action: Service.Action) async {
        guard !busy else { return }
        revision += 1
        busy = true
        defer { busy = false }
        do {
            try await service.perform(action)
        } catch {
            actionError = error.localizedDescription
        }
        await read(revision)
    }
}

private struct ControlPanel: View {
    private enum Tab: String, CaseIterable {
        case overview = "Overview"
        case models = "Models"
        case resources = "Resources"
        case log = "Log"
    }

    @StateObject private var model = PanelModel()
    @StateObject private var installer = InstallModel()
    @State private var tab = Tab.overview
    @State private var confirmStop = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let error = model.refreshError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            InstallProgressView(installer: installer)
            if let status = model.status {
                switch tab {
                case .overview: overview(status)
                case .models: models(status)
                case .resources: ResourcesView(pid: status.pid)
                case .log: log(status)
                }
            } else if model.refreshError == nil {
                Spacer()
                ProgressView("Checking service…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(12))
            }
        }
        .alert("Command failed", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Installation failed", isPresented: Binding(
            get: { installer.error != nil }, set: { if !$0 { installer.error = nil } }
        )) {
            Button("OK", role: .cancel) { installer.error = nil }
        } message: {
            Text(installer.error ?? "")
        }
        .confirmationDialog("Disable automatic startup?", isPresented: $confirmStop) {
            Button("Disable and Stop", role: .destructive) { run(.disableAutostart) }
        } message: {
            Text("The service will stop. Current requests will be interrupted.")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "cpu")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 13)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("okay-mlx").font(.system(size: 26, weight: .semibold))
                Text("Local model server").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small).accessibilityLabel("Running command")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)
        }
    }

    private func overview(_ status: Service.Status) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Label(stateText(status), systemImage: "circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(stateColor(status))
                        Spacer()
                        if let pid = status.pid {
                            Text("PID \(pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Active model").font(.caption).foregroundStyle(.secondary)
                        Text(status.models.first ?? "—")
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Divider()
                    HStack {
                        Text(status.endpoint).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(status.endpoint, forType: .string)
                        } label: {
                            let title: LocalizedStringKey = copied ? "Copied" : "Copy URL"
                            Label(title, systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .onChange(of: status.endpoint) { copied = false }
                    }
                }
                .padding(16)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 13) {
                    Text("Service controls").font(.headline)
                    HStack {
                        let needsEnabling = status.enabled == false || !status.installed
                        let startTitle: LocalizedStringKey = needsEnabling ? "Enable and Start" : "Start"
                        Button(startTitle) {
                            if status.cachedModels.contains(status.startupModel) || status.loaded {
                                run(.start)
                            } else {
                                installer.server(status) { await model.refresh() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.pid != nil || (!status.installed && !status.binaryExists))
                        Button("Stop") { run(.stop) }
                            .disabled(!status.loaded)
                        Button("Restart") { run(.restart) }
                            .disabled(!status.loaded)
                    }
                    .disabled(model.busy || installer.running || model.refreshError != nil)
                    Divider()
                    Toggle(isOn: Binding(get: { status.autostart }, set: { enabled in
                        if enabled {
                            run(.enableAutostart)
                        } else if status.loaded {
                            confirmStop = true
                        } else {
                            run(.disableAutostart)
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start at macOS login").font(.subheadline.weight(.medium))
                            Text("Startup model: \(status.startupModel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Start at macOS login")
                    .disabled(model.busy || installer.running || model.refreshError != nil || status.enabled == nil ||
                              (!status.installed && !status.binaryExists))
                    if !status.binaryExists || !status.installed ||
                        (!status.loaded && !status.cachedModels.contains(status.startupModel)) {
                        let title: LocalizedStringKey = status.binaryExists ? "Set up service" : "Install server"
                        Button(title) {
                            installer.server(status) { await model.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || installer.running)
                        Text("Downloads the server from GitHub Releases and its startup model from Hugging Face.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if status.autostart && !status.loaded {
                        Text("The service will start at the next macOS login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }

    private func models(_ status: Service.Status) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelDownloadView(status: status, busy: model.busy, installer: installer) {
                await model.refresh()
            }
            Divider()
            Text("Downloaded models").font(.headline)
            let names = Array(Set(status.cachedModels + status.models)).sorted()
            if names.isEmpty {
                let message: LocalizedStringKey = status.apiReady
                    ? "Model list unavailable."
                    : "Download a model to get started."
                Text(message)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(names, id: \.self) { name in
                    HStack {
                        Text(name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if status.apiReady && name == status.models.first {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func log(_ status: Service.Status) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Service log").font(.headline)
                    Text("Last 64 KiB").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = status.log {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                }
            }
            LogText(text: status.logText.isEmpty ? String(localized: "The log is empty.") : status.logText)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func stateText(_ status: Service.Status) -> LocalizedStringKey {
        if status.apiReady { return "API available" }
        if status.pid != nil { return "Process running · API unavailable" }
        if status.loaded { return "Waiting for process" }
        return status.installed ? "Service stopped" : "Service not configured"
    }

    private func stateColor(_ status: Service.Status) -> Color {
        if status.apiReady { return .green }
        if status.loaded { return .orange }
        return .secondary
    }

    private func run(_ action: Service.Action) {
        Task { await model.perform(action) }
    }
}

private struct LogText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 12)
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let nearBottom = view.bounds.maxY - scroll.contentView.bounds.maxY < 32
        let visible = scroll.contentView.bounds.origin
        view.string = text
        if nearBottom {
            view.scrollToEndOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: visible)
        }
    }
}
