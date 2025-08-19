import SwiftUI
import AppKit

struct TerminalPane: View {
    @EnvironmentObject private var ptyModel: PTYModel
    @State private var hasSelection: Bool = false
    @State private var hovering: Bool = false
    @State private var buttonHovering: Bool = false

    let onAddToChat: (String, TerminalContextMeta?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal")
                    .font(.headline)
                Spacer()
                Button(action: copyAll) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(ptyModel.collectedOutput.isEmpty)
                Button(action: addSelectionToChat) {
                    Label("Add Selection", systemImage: "text.badge.plus")
                }
                .disabled(!hasSelection)
                Button(action: addAllToChat) {
                    Label("Add to Chat", systemImage: "arrow.turn.right.up")
                }
                .disabled(ptyModel.collectedOutput.isEmpty)
            }
            .padding(8)

            SwiftTermView(model: ptyModel)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(alignment: .bottomTrailing) {
                    let hasChunk = !ptyModel.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if (hovering || buttonHovering) && hasChunk {
                        Button(action: {
                            let chunk = ptyModel.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !chunk.isEmpty else { return }
                            let meta = ptyModel.lastOutputLineRange.map { TerminalContextMeta(startRow: $0.start, endRow: $0.end) }
                            onAddToChat(chunk, meta)
                        }) {
                            Label("Add Last Output", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(12)
                        .onHover { buttonHovering = $0 }
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

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ptyModel.collectedOutput, forType: .string)
    }

    private func addAllToChat() {
        onAddToChat(ptyModel.collectedOutput, nil)
    }

    private func addSelectionToChat() {
        let sel = ptyModel.getSelectionText?() ?? ""
        guard !sel.isEmpty else { return }
        onAddToChat(sel, nil)
    }
}


