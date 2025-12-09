import SwiftUI
import AppKit
import TermAIModels

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String
    var fullDetails: String? = nil
    let onDismiss: () -> Void
    
    @State private var isExpanded: Bool = false
    @State private var showCopied: Bool = false
    
    private var hasExpandableDetails: Bool {
        fullDetails != nil && fullDetails != message
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main error banner - entire area is clickable if expandable
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(isExpanded ? nil : 2)
                Spacer()
                
                // Show details button (only if there are full details)
                if hasExpandableDetails {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide" : "Details")
                            .font(.caption2)
                            .fontWeight(.medium)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                }
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasExpandableDetails {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }
            
            // Expanded details section
            if isExpanded, let details = fullDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Full Error Details")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(details, forType: .string)
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopied = false
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                    Text(showCopied ? "Copied!" : "Copy")
                                        .font(.caption2)
                                }
                                .foregroundColor(showCopied ? .green : .accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        ScrollView {
                            Text(details)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.7))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Scroll to Bottom Button

struct ScrollToBottomButton: View {
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text("New messages")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: isHovered ? 8 : 4, y: 2)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Terminal Context Card

struct TerminalContextCard: View {
    let context: String
    let meta: TerminalContextMeta?
    let onRemove: () -> Void
    
    @State private var isExpanded: Bool = false
    
    /// Whether this is a file context (vs terminal output)
    private var isFileContext: Bool {
        meta?.filePath != nil
    }
    
    private var displayTitle: String {
        if let filePath = meta?.filePath {
            return (filePath as NSString).lastPathComponent
        }
        return "Terminal Context"
    }
    
    private var displaySubtitle: String? {
        if let filePath = meta?.filePath {
            return shortenPath(filePath)
        }
        return meta?.cwd.flatMap { shortenPath($0) }
    }
    
    private var iconName: String {
        isFileContext ? "doc.text.fill" : "terminal.fill"
    }
    
    private var accentColor: Color {
        isFileContext ? .blue : .orange
    }
    
    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Icon with glow effect
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.2))
                        .frame(width: 24, height: 24)
                    Image(systemName: iconName)
                        .font(.system(size: 10))
                        .foregroundColor(accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                    if let subtitle = displaySubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                // Line count badge for files
                if isFileContext {
                    let lineCount = context.components(separatedBy: .newlines).count
                    Text("\(lineCount) lines")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                
                Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                Text(context)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.4), accentColor.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Flow Layout

/// A simple flow layout that wraps content to multiple lines
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> ArrangementResult {
        let maxWidth = proposal.width ?? .infinity
        
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            
            // Check if we need to wrap to next line
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineWidth = max(maxLineWidth, currentX - spacing)
        }
        
        totalHeight = currentY + lineHeight
        
        return ArrangementResult(
            positions: positions,
            sizes: sizes,
            size: CGSize(width: maxLineWidth, height: totalHeight)
        )
    }
    
    private struct ArrangementResult {
        var positions: [CGPoint]
        var sizes: [CGSize]
        var size: CGSize
    }
}
