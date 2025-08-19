import SwiftUI
import AppKit

struct TerminalPane: View {
    @EnvironmentObject private var ptyModel: PTYModel
    @State private var hasSelection: Bool = false
    @State private var hovering: Bool = false
    @State private var buttonHovering: Bool = false

    let onAddToChat: (String, TerminalContextMeta?) -> Void
    let onToggleChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal")
                    .font(.headline)
                Spacer()
                Button(action: onToggleChat) {
                    Image(systemName: "bubble.right")
                }
                .help("Toggle Chat")
            }
            .padding(8)

            SwiftTermView(model: ptyModel)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(alignment: .bottomTrailing) {
                    let hasChunk = !ptyModel.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if (hovering || buttonHovering) && (hasSelection || hasChunk) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if hasSelection {
                                Button(action: addSelectionToChat) {
                                    Label("Add Selection", systemImage: "text.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .onHover { buttonHovering = $0 }
                            }
                            if hasChunk {
                                Button(action: addLastOutputToChat) {
                                    Label("Add Last Output", systemImage: "plus.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .onHover { buttonHovering = $0 }
                            }
                        }
                        .padding(12)
                    }
                }
                .onHover { hovering = $0 }
            .onReceive(ptyModel.$hasSelection) { hasSelection = $0 }
            .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
                let sel = ptyModel.getSelectionText?() ?? ""
                if hasSelection != !sel.isEmpty {
                    hasSelection = !sel.isEmpty
                }
            }

            // Footer removed to avoid duplication
        }
    }

    private func addSelectionToChat() {
        let sel = ptyModel.getSelectionText?() ?? ""
        guard !sel.isEmpty else { return }
        var meta = TerminalContextMeta(startRow: -1, endRow: -1)
        meta.cwd = ptyModel.currentWorkingDirectory
        onAddToChat(sel, meta)
    }

    private func addLastOutputToChat() {
        let chunk = ptyModel.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        var meta = ptyModel.lastOutputLineRange.map { TerminalContextMeta(startRow: $0.start, endRow: $0.end) }
        if meta == nil { meta = TerminalContextMeta(startRow: -1, endRow: -1) }
        meta?.cwd = ptyModel.currentWorkingDirectory
        onAddToChat(chunk, meta)
    }
}


