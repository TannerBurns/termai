import SwiftUI

/// Vertical toolbar displaying favorite commands as emoji buttons
/// Appears on the left side of the terminal when favorites exist
struct FavoritesToolbar: View {
    @ObservedObject private var settings = AgentSettings.shared
    let onRunCommand: (String) -> Void
    
    @State private var hoveredIndex: Int? = nil
    @Environment(\.colorScheme) var colorScheme
    
    // Button dimensions for positioning
    static let buttonSize: CGFloat = 36
    static let buttonSpacing: CGFloat = 4
    static let topPadding: CGFloat = 8
    static let toolbarWidth: CGFloat = 44
    
    /// Expose hover state for external tooltip rendering
    var hoveredCommandInfo: (command: FavoriteCommand, index: Int)? {
        guard let index = hoveredIndex, index < settings.favoriteCommands.count else { return nil }
        return (settings.favoriteCommands[index], index)
    }
    
    var body: some View {
        if !settings.favoriteCommands.isEmpty {
            // Toolbar with buttons
            VStack(spacing: Self.buttonSpacing) {
                ForEach(Array(settings.favoriteCommands.enumerated()), id: \.element.id) { index, command in
                    FavoriteCommandButton(
                        command: command,
                        isHovered: hoveredIndex == index,
                        onHover: { isHovered in
                            withAnimation(.easeInOut(duration: 0.12)) {
                                hoveredIndex = isHovered ? index : nil
                            }
                        },
                        onTap: {
                            onRunCommand(command.command)
                        }
                    )
                }
                
                Spacer()
            }
            .padding(.vertical, Self.topPadding)
            .padding(.horizontal, 4)
            .frame(width: Self.toolbarWidth)
            .background(
                Rectangle()
                    .fill(colorScheme == .dark 
                        ? Color(white: 0.08) 
                        : Color(white: 0.95))
            )
            .overlay(
                Rectangle()
                    .fill(colorScheme == .dark 
                        ? Color.white.opacity(0.06) 
                        : Color.black.opacity(0.08))
                    .frame(width: 1),
                alignment: .trailing
            )
        }
    }
}

/// Wrapper view that renders FavoritesToolbar and reports hover state for external tooltip rendering
struct FavoritesToolbarWithTooltip: View {
    @ObservedObject private var settings = AgentSettings.shared
    let onRunCommand: (String) -> Void
    
    /// Binding to report hovered command info to parent for tooltip rendering
    @Binding var hoveredCommandInfo: (command: FavoriteCommand, index: Int)?
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        if !settings.favoriteCommands.isEmpty {
            // Toolbar content
            VStack(spacing: FavoritesToolbar.buttonSpacing) {
                ForEach(Array(settings.favoriteCommands.enumerated()), id: \.element.id) { index, command in
                    FavoriteCommandButton(
                        command: command,
                        isHovered: hoveredCommandInfo?.index == index,
                        onHover: { isHovered in
                            withAnimation(.easeInOut(duration: 0.12)) {
                                hoveredCommandInfo = isHovered ? (command, index) : nil
                            }
                        },
                        onTap: {
                            onRunCommand(command.command)
                        }
                    )
                }
                
                Spacer()
            }
            .padding(.vertical, FavoritesToolbar.topPadding)
            .padding(.horizontal, 4)
            .frame(width: FavoritesToolbar.toolbarWidth)
            .background(
                Rectangle()
                    .fill(colorScheme == .dark 
                        ? Color(white: 0.08) 
                        : Color(white: 0.95))
            )
            .overlay(
                Rectangle()
                    .fill(colorScheme == .dark 
                        ? Color.white.opacity(0.06) 
                        : Color.black.opacity(0.08))
                    .frame(width: 1),
                alignment: .trailing
            )
        }
    }
}

/// Individual favorite command button with emoji
struct FavoriteCommandButton: View {
    let command: FavoriteCommand
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: onTap) {
            Text(command.emoji)
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered 
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovered 
                            ? Color.accentColor.opacity(0.4)
                            : Color.clear, lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { onHover($0) }
    }
}

/// Custom tooltip showing the command text
struct CommandTooltip: View {
    let command: String
    let name: String?
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.7))
            }
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorScheme == .dark 
                    ? Color(white: 0.18) 
                    : Color(white: 0.98))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 2, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(colorScheme == .dark 
                    ? Color.white.opacity(0.12) 
                    : Color.black.opacity(0.1), lineWidth: 1)
        )
        .fixedSize()
    }
}

/// Compact favorites bar for terminal header (alternative layout)
struct FavoritesHeaderBar: View {
    @ObservedObject private var settings = AgentSettings.shared
    let onRunCommand: (String) -> Void
    
    @State private var hoveredCommandId: UUID? = nil
    
    var body: some View {
        if !settings.favoriteCommands.isEmpty {
            HStack(spacing: 4) {
                ForEach(settings.favoriteCommands.prefix(8)) { command in
                    Button(action: { onRunCommand(command.command) }) {
                        Text(command.emoji)
                            .font(.system(size: 14))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(hoveredCommandId == command.id 
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.05))
                            )
                            .scaleEffect(hoveredCommandId == command.id ? 1.08 : 1.0)
                            .animation(.easeInOut(duration: 0.12), value: hoveredCommandId == command.id)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered in
                        hoveredCommandId = isHovered ? command.id : nil
                    }
                    .help(command.displayText)
                }
                
                // Show overflow indicator if there are more than 8 favorites
                if settings.favoriteCommands.count > 8 {
                    Text("+\(settings.favoriteCommands.count - 8)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FavoritesToolbar_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 0) {
            // Simulated toolbar
            VStack(spacing: 4) {
                ForEach(["🌿", "📦", "🧪", "🚀", "🔨"], id: \.self) { emoji in
                    Text(emoji)
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(width: 44)
            .background(Color(white: 0.08))
            
            // Simulated terminal
            Rectangle()
                .fill(Color(white: 0.1))
        }
        .frame(width: 600, height: 400)
    }
}
#endif

