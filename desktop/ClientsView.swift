import AppKit
import SwiftUI

/// The clients that use the server: OpenChamber (opencode's web and iPhone client) and opencode itself, which list
/// the models of opencode's "okay-mlx" provider; others connect by URL.
struct ClientsView: View {
    let status: Service.Status
    @ObservedObject var library: LibraryModel
    @State private var confirmRestart = false
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                chamber
                opencode
                others
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Restart OpenChamber?", isPresented: $confirmRestart) {
            Button("Restart") { library.restartChamber() }
        } message: {
            Text("Its opencode reads the new model list on start. Running sessions are interrupted.")
        }
    }

    private var chamber: some View {
        card {
            HStack {
                Label("OpenChamber", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
                Spacer()
                let state = library.chamber
                Label(state.running ? String(localized: "Running")
                      : (state.installed ? String(localized: "Stopped") : String(localized: "Not installed")),
                      systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.running ? .green : .secondary)
            }
            Text(library.chamber.url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
            HStack {
                Button("Open OpenChamber") { NSWorkspace.shared.open(library.chamber.url) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!library.chamber.running)
                Button("Restart…") { confirmRestart = true }
                    .disabled(!library.chamber.installed || library.working != nil)
            }
            Text("""
                OpenChamber runs opencode, which offers the models of its "okay-mlx" provider. \
                Picking one there makes okay-mlx load it.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var opencode: some View {
        card {
            HStack {
                Label("opencode models", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                if !library.openCode.readable {
                    Label("Config not readable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else if library.inSync {
                    Label("In sync", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Label("Out of sync", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text(OpenCode(home: library.home).config.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            let offered = Set(library.offered.map(\.id))
            let listed = Set(library.openCode.listed)
            ForEach(library.offered.map(\.id).sorted() + listed.subtracting(offered).sorted(), id: \.self) { id in
                HStack {
                    Image(systemName: listed.contains(id) && offered.contains(id) ? "checkmark" :
                            (offered.contains(id) ? "plus" : "minus"))
                        .frame(width: 14)
                        .foregroundStyle(listed.contains(id) && offered.contains(id) ? .green :
                            (offered.contains(id) ? .orange : .red))
                    Text(id).font(.callout.monospaced())
                }
            }
            HStack {
                Button("Update opencode now") { library.syncOpenCode() }
                    .disabled(library.inSync || !library.openCode.readable || library.working != nil)
                Toggle("Keep in sync automatically", isOn: $library.autoSync)
            }
            Text("""
                The panel writes only the "okay-mlx" provider (names, tool calls, each model's context so opencode \
                compacts before it overflows); the rest of the file stays as you wrote it. A backup of the original \
                is kept beside it (.okay-mlx.bak). Restart OpenChamber to see changes there.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var others: some View {
        card {
            Label("Other clients", systemImage: "terminal").font(.headline)
            let model = library.admin?.loaded?.model ?? status.startupModel
            line("OpenAI-compatible", status.endpoint + "/v1")
            line("Anthropic API (Claude Code)",
                 "ANTHROPIC_BASE_URL=\(status.endpoint) ANTHROPIC_AUTH_TOKEN=local claude --model \(model)")
            Text("""
                A request naming a downloaded model loads it in place of the one in memory; \
                other names use the model loaded now.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = value
                } label: {
                    Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
