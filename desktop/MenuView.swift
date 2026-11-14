import AppKit
import SwiftUI

/// The menu bar item's window (spec §3.2): the service's state, the model in memory, the models to switch to,
/// and the way to the panel and to OpenChamber.
struct MenuView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.status?.apiReady == true ? Color.green : Color.secondary).frame(width: 9)
                Text("okay-mlx").font(.headline)
                Spacer()
                if let working = library.working {
                    ProgressView().controlSize(.small).help(working)
                }
            }
            memory
            Divider()
            Text("Switch model").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.models.filter { !library.hidden.contains($0.id) }) { item in
                        let loaded = library.admin?.loaded?.model == item.id
                        Button {
                            if !loaded { library.load(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: loaded ? "checkmark" : "circle").frame(width: 14)
                                    .foregroundStyle(loaded ? .green : .secondary)
                                Text(item.title)
                                Spacer()
                                Text(item.weights.formatted(.byteCount(style: .memory)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .disabled(library.working != nil || library.admin == nil)
                    }
                }
            }
            .frame(maxHeight: 260)
            Divider()
            HStack {
                Button("Unload") { library.unload() }
                    .disabled(library.admin?.loaded == nil || library.working != nil)
                Spacer()
                Button("OpenChamber") { NSWorkspace.shared.open(library.chamber.url) }
                    .disabled(!library.chamber.running)
                Button("Panel…") {
                    openWindow(id: "control-panel")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var memory: some View {
        if let admin = library.admin {
            if let loading = admin.loading {
                Text("Loading \(Library.title(loading))…").font(.callout)
            } else if let loaded = admin.loaded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Library.title(loaded.model)).font(.title3.weight(.semibold))
                    Text(admin.running > 0 ? String(localized: "generating · \(admin.running)")
                         : String(localized: "idle"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No model in memory").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text(model.status?.pid == nil ? String(localized: "Service stopped")
                 : String(localized: "Waiting for the server…"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
