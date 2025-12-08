import SwiftUI

// MARK: - Terminal Suggestions Bar (Static Bottom Bar)

/// A static horizontal bar showing AI-powered command suggestions at the bottom of the terminal
struct TerminalSuggestionsBar: View {
    @ObservedObject var suggestionService: TerminalSuggestionService
    let onRunCommand: (String) -> Void
    let onOpenSettings: () -> Void
    
    @State private var hoveredSuggestionId: UUID? = nil
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        if suggestionService.isVisible || suggestionService.needsModelSetup || suggestionService.isLoading {
            suggestionsContent
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    
    @ViewBuilder
    private var suggestionsContent: some View {
        HStack(spacing: 8) {
            // AI icon and label
            HStack(spacing: 6) {
                Image(systemName: phaseIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(phaseColor)
                
                Text(phaseLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .frame(height: 20)
            
            // Content based on state
            if suggestionService.needsModelSetup {
                setupPrompt
            } else if suggestionService.currentPhase.isActive {
                // Phase description shown inline (icon and label already shown on left)
                Text(suggestionService.currentPhase.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let error = suggestionService.lastError {
                errorView(error)
            } else if !suggestionService.suggestions.isEmpty {
                suggestionsRow
            }
            
            Spacer()
            
            // Dismiss button
            Button(action: { suggestionService.clearSuggestions(userInitiated: true) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("Dismiss (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            colorScheme == .dark
                ? Color(red: 0.13, green: 0.14, blue: 0.17)  // #21252b - Atom One Dark header
                : Color(red: 0.91, green: 0.91, blue: 0.91)  // #e8e8e8 - Atom One Light header
        )
        .overlay(
            Rectangle()
                .fill(colorScheme == .dark
                    ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451 - Atom One Dark divider
                    : Color(red: 0.82, green: 0.82, blue: 0.82)) // #d1d1d1 - Atom One Light divider
                .frame(height: 1),
            alignment: .top
        )
    }
    
    // MARK: - Phase Display Helpers
    
    private var phaseIcon: String {
        switch suggestionService.currentPhase {
        case .idle:
            return "sparkles"
        case .gatheringContext:
            return "doc.text.magnifyingglass"
        case .researching:
            return "magnifyingglass"
        case .planning:
            return "brain"
        case .generating:
            return "wand.and.stars"
        case .readingOutput:
            return "terminal"
        case .updatingContext:
            return "arrow.triangle.2.circlepath"
        }
    }
    
    private var phaseColor: Color {
        switch suggestionService.currentPhase {
        case .idle:
            return .purple
        case .gatheringContext:
            return .blue
        case .researching:
            return .cyan
        case .planning:
            return .orange
        case .generating:
            return .green
        case .readingOutput:
            return .teal
        case .updatingContext:
            return .indigo
        }
    }
    
    private var phaseLabel: String {
        if suggestionService.currentPhase.isActive {
            return suggestionService.currentPhase.label
        }
        return "Suggestions"
    }
    
    // MARK: - Setup Prompt
    
    private var setupPrompt: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                Text("Configure AI model for suggestions")
                    .font(.system(size: 11))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Error View
    
    private func errorView(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
    
    // MARK: - Suggestions Row (Horizontal)
    
    private var suggestionsRow: some View {
        HStack(spacing: 8) {
            ForEach(suggestionService.suggestions) { suggestion in
                SuggestionChip(
                    suggestion: suggestion,
                    isHovered: hoveredSuggestionId == suggestion.id,
                    onRun: { onRunCommand(suggestion.command) }
                )
                .onHover { isHovered in
                    hoveredSuggestionId = isHovered ? suggestion.id : nil
                }
            }
        }
    }
}

// MARK: - Suggestion Chip (Horizontal Card)

private struct SuggestionChip: View {
    let suggestion: CommandSuggestion
    let isHovered: Bool
    let onRun: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    @State private var showTooltip: Bool = false
    @State private var hoverTask: Task<Void, Never>? = nil
    
    private var sourceIcon: String {
        switch suggestion.source {
        case .projectContext: return "folder.fill"
        case .errorAnalysis: return "exclamationmark.triangle.fill"
        case .gitStatus: return "arrow.triangle.branch"
        case .cwdChange: return "folder.badge.gearshape"
        case .generalContext: return "lightbulb.fill"
        case .startup: return "play.fill"
        case .resumeCommand: return "clock.arrow.circlepath"
        case .shellHistory: return "terminal.fill"
        }
    }
    
    private var sourceColor: Color {
        switch suggestion.source {
        case .projectContext: return .blue
        case .errorAnalysis: return .red
        case .gitStatus: return .green
        case .cwdChange: return .orange
        case .generalContext: return .purple
        case .startup: return .cyan
        case .resumeCommand: return .indigo
        case .shellHistory: return .teal
        }
    }
    
    var body: some View {
        Button(action: {
            // Cancel tooltip and run immediately
            hoverTask?.cancel()
            showTooltip = false
            onRun()
        }) {
            HStack(spacing: 8) {
                // Source icon
                Image(systemName: sourceIcon)
                    .font(.system(size: 10))
                    .foregroundColor(sourceColor)
                
                // Command
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.command)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(suggestion.reason)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                // Run indicator on hover
                if isHovered {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered 
                        ? (colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                        : (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? sourceColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .overlay(alignment: .top) {
            if showTooltip {
                SuggestionTooltip(
                    command: suggestion.command,
                    reason: suggestion.reason,
                    sourceColor: sourceColor,
                    sourceIcon: sourceIcon
                )
                .offset(y: -8)
                .anchorPreference(key: TooltipBoundsKey.self, value: .bounds) { $0 }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false) // Don't capture clicks
            }
        }
        .onChange(of: isHovered) { newValue in
            hoverTask?.cancel()
            if newValue {
                // Show tooltip after a delay
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms delay
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showTooltip = true
                            }
                        }
                    }
                }
            } else {
                withAnimation(.easeIn(duration: 0.1)) {
                    showTooltip = false
                }
            }
        }
    }
}

// MARK: - Tooltip Bounds Key

private struct TooltipBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Suggestion Tooltip

private struct SuggestionTooltip: View {
    let command: String
    let reason: String
    let sourceColor: Color
    let sourceIcon: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Full command
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 10))
                    .foregroundColor(sourceColor)
                
                Text(command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Reason
            Text(reason)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 150, maxWidth: 350)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark
                    ? Color(red: 0.17, green: 0.19, blue: 0.23)  // #2c313a Atom One Dark elevated
                    : Color(red: 0.96, green: 0.96, blue: 0.96)) // #f5f5f5 Atom One Light
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        // Position above the chip
        .offset(y: -50)
    }
}

// MARK: - Compact Suggestion Badge (for header)

/// A compact badge shown in the terminal header when suggestions are available or loading
struct SuggestionBadge: View {
    @ObservedObject var suggestionService: TerminalSuggestionService
    let onTap: () -> Void
    
    private var badgeIcon: String {
        switch suggestionService.currentPhase {
        case .idle:
            return "sparkles"
        case .gatheringContext:
            return "doc.text.magnifyingglass"
        case .researching:
            return "magnifyingglass"
        case .planning:
            return "brain"
        case .generating:
            return "wand.and.stars"
        case .readingOutput:
            return "terminal"
        case .updatingContext:
            return "arrow.triangle.2.circlepath"
        }
    }
    
    private var badgeColor: Color {
        switch suggestionService.currentPhase {
        case .idle:
            return .purple
        case .gatheringContext:
            return .blue
        case .researching:
            return .cyan
        case .planning:
            return .orange
        case .generating:
            return .green
        case .readingOutput:
            return .teal
        case .updatingContext:
            return .indigo
        }
    }
    
    var body: some View {
        // Only show badge when there are active suggestions or loading
        // (Setup state is now handled by the provider/model selectors in the header)
        if !suggestionService.suggestions.isEmpty || suggestionService.currentPhase.isActive {
            // Active suggestions badge with phase awareness
            Button(action: onTap) {
                HStack(spacing: 4) {
                    if suggestionService.currentPhase.isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        
                        // Show phase label when processing
                        Text(suggestionService.currentPhase.label)
                            .font(.system(size: 9))
                    } else {
                        Image(systemName: badgeIcon)
                            .font(.system(size: 10))
                    }
                    
                    if !suggestionService.suggestions.isEmpty && !suggestionService.currentPhase.isActive {
                        Text("\(suggestionService.suggestions.count)")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundColor(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(badgeColor.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .help(suggestionService.currentPhase.isActive 
                ? suggestionService.currentPhase.description 
                : "View AI suggestions (Ctrl+Space)")
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TerminalSuggestionsBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()
            TerminalSuggestionsBar(
                suggestionService: TerminalSuggestionService.shared,
                onRunCommand: { _ in },
                onOpenSettings: { }
            )
        }
        .frame(width: 700, height: 400)
        .background(Color.gray.opacity(0.2))
    }
}
#endif
