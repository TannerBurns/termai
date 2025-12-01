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
            // Header with glass material
            HStack {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Terminal")
                    .font(.headline)
                
                Spacer()
                
                Button(action: onToggleChat) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Toggle Chat Panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Terminal view with contextual action overlay
            SwiftTermView(model: ptyModel)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(alignment: .bottomTrailing) {
                    let hasChunk = !ptyModel.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if (hovering || buttonHovering) && (hasSelection || hasChunk) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if hasSelection {
                                TerminalActionButton(
                                    label: "Add Selection",
                                    icon: "text.badge.plus",
                                    action: addSelectionToChat
                                )
                                .onHover { buttonHovering = $0 }
                            }
                            if hasChunk {
                                TerminalActionButton(
                                    label: "Add Last Output",
                                    icon: "plus.circle.fill",
                                    action: addLastOutputToChat
                                )
                                .onHover { buttonHovering = $0 }
                            }
                        }
                        .padding(12)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .onHover { hovering = $0 }
                .onReceive(ptyModel.$hasSelection) { hasSelection = $0 }
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

// MARK: - Terminal Action Button
private struct TerminalActionButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: Color.accentColor.opacity(0.3), radius: isHovered ? 6 : 3, y: 2)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

