import AppKit
import CoreImage
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
        .sheet(item: $library.pairing) { link in PairingSheet(link: link) }
        .confirmationDialog("Restart OpenChamber?", isPresented: $confirmRestart) {
            Button("Restart") { library.restartChamber() }
        } message: {
            Text("OpenChamber and its opencode start again. Running sessions are interrupted.")
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
                Button("Pair a device…") { library.pair() }
                    .disabled(!library.chamber.running || library.working != nil)
                    .help("A single-use link and QR code for the OpenChamber iPhone app, through the relay.")
                Button("Restart…") { confirmRestart = true }
                    .disabled(!library.chamber.installed || library.working != nil)
            }
            if let api = library.chamberAPI {
                let wanted = library.offered.map(\.id)
                let all = Set(wanted).isSubset(of: Set(api.models))
                Label(String(localized: "OpenChamber offers \(api.models.count) of \(wanted.count) okay-mlx models"),
                      systemImage: all ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(all ? .green : .orange)
                Picker("Default model for new sessions", selection: Binding(
                    get: { api.defaultModel ?? "" },
                    set: { value in
                        library.setChamberDefault(
                            value.isEmpty ? nil : String(value.dropFirst(OpenCode.provider.count + 1)))
                    }
                )) {
                    Text("OpenCode's own choice").tag("")
                    ForEach(library.offered, id: \.id) { model in
                        Text(model.title).tag("\(OpenCode.provider)/\(model.id)")
                    }
                    if let other = api.defaultModel, !other.isEmpty, !other.hasPrefix(OpenCode.provider + "/") {
                        Text(other).tag(other)
                    }
                }
                .disabled(library.working != nil)
            } else if let error = library.chamberAPIError {
                Text(error).font(.caption).foregroundStyle(.orange)
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
                is kept beside it (.okay-mlx.bak). OpenChamber picks the change up within seconds.
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

/// A pairing link as a QR code for the OpenChamber iPhone app: single-use, expiring.
struct PairingSheet: View {
    let link: ChamberAPI.Pairing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a device").font(.title3.weight(.semibold))
            if let image = Self.qr(link.url) {
                // a long link makes a dense code: shown large, with the white border scanners need
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 320, height: 320)
                    .padding(16).background(Color.white)
            }
            Text("Scan with the OpenChamber app on the iPhone (Settings → Remote Instances → Add).")
                .font(.callout).multilineTextAlignment(.center)
            if let fingerprint = link.fingerprint {
                Text("Fingerprint: \(fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let expires = link.expires {
                Text("Single-use; expires at \(expires.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 400)
    }

    static func qr(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
