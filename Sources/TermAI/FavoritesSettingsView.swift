import SwiftUI

/// Settings view for managing favorite terminal commands
struct FavoritesSettingsView: View {
    @ObservedObject private var settings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    
    @State private var newCommandText: String = ""
    @State private var isAddingCommand: Bool = false
    @State private var isGeneratingEmoji: Bool = false
    @State private var editingCommandId: UUID? = nil
    @State private var editingCommandText: String = ""
    @State private var regeneratingEmojiId: UUID? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header Section
                headerSection
                
                // Add New Command Section
                addCommandSection
                
                // Favorites List Section
                favoritesListSection
                
                // Tips Section
                tipsSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(
                "Favorite Commands",
                subtitle: "Save frequently used commands for quick access from the terminal toolbar"
            )
        }
    }
    
    // MARK: - Add Command Section
    
    private var addCommandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add New Command")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            
            HStack(spacing: 12) {
                TextField("Enter command (e.g., git status, npm run dev)", text: $newCommandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .onSubmit {
                        addCommand()
                    }
                
                Button(action: addCommand) {
                    if isGeneratingEmoji {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(newCommandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingEmoji)
                .help("Add command to favorites")
            }
            
            if !settings.isTerminalSuggestionsConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("Configure AI in Terminal Suggestions settings to enable smart emoji generation")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }
    
    // MARK: - Favorites List Section
    
    private var favoritesListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Favorites")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if !settings.favoriteCommands.isEmpty {
                    Text("\(settings.favoriteCommands.count) command\(settings.favoriteCommands.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            if settings.favoriteCommands.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(settings.favoriteCommands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                        favoriteCommandRow(command)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No favorite commands yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            Text("Add commands above to see them in your terminal toolbar")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }
    
    private func favoriteCommandRow(_ command: FavoriteCommand) -> some View {
        HStack(spacing: 12) {
            // Emoji button with regenerate option
            Button(action: { regenerateEmoji(for: command) }) {
                ZStack {
                    if regeneratingEmojiId == command.id {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 32, height: 32)
                    } else {
                        Text(command.emoji)
                            .font(.system(size: 20))
                            .frame(width: 32, height: 32)
                    }
                }
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .help("Click to regenerate emoji")
            
            // Command text (editable)
            if editingCommandId == command.id {
                TextField("Command", text: $editingCommandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                    .onSubmit {
                        saveEditedCommand(command)
                    }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.command)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if let name = command.name, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 8) {
                if editingCommandId == command.id {
                    Button(action: { cancelEditing() }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel editing")
                    
                    Button(action: { saveEditedCommand(command) }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Save changes")
                } else {
                    Button(action: { startEditing(command) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit command")
                    
                    Button(action: { deleteCommand(command) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete command")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    // MARK: - Tips Section
    
    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tips")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "sparkles", text: "AI will automatically pick an emoji that represents your command")
                tipRow(icon: "hand.tap", text: "Click any emoji to regenerate it with AI")
                tipRow(icon: "sidebar.left", text: "Favorites appear as emoji buttons on the left side of your terminal")
                tipRow(icon: "cursorarrow.click.2", text: "Click an emoji button to instantly run that command")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
            )
        }
    }
    
    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 16)
            
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Actions
    
    /// Get all currently used emojis
    private var existingEmojis: Set<String> {
        Set(settings.favoriteCommands.map { $0.emoji })
    }
    
    private func addCommand() {
        let command = newCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        
        isGeneratingEmoji = true
        
        // Capture existing emojis before async call
        let usedEmojis = existingEmojis
        
        Task {
            let emoji = await EmojiGenerator.shared.generateEmoji(for: command, avoiding: usedEmojis)
            
            await MainActor.run {
                let newFavorite = FavoriteCommand(command: command, emoji: emoji)
                settings.addFavoriteCommand(newFavorite)
                newCommandText = ""
                isGeneratingEmoji = false
            }
        }
    }
    
    private func regenerateEmoji(for command: FavoriteCommand) {
        regeneratingEmojiId = command.id
        
        // Get emojis to avoid (all except the current command's emoji)
        let usedEmojis = Set(settings.favoriteCommands.filter { $0.id != command.id }.map { $0.emoji })
        
        Task {
            let emoji = await EmojiGenerator.shared.generateEmoji(for: command.command, avoiding: usedEmojis)
            
            await MainActor.run {
                var updated = command
                updated.emoji = emoji
                settings.updateFavoriteCommand(updated)
                regeneratingEmojiId = nil
            }
        }
    }
    
    private func startEditing(_ command: FavoriteCommand) {
        editingCommandId = command.id
        editingCommandText = command.command
    }
    
    private func cancelEditing() {
        editingCommandId = nil
        editingCommandText = ""
    }
    
    private func saveEditedCommand(_ command: FavoriteCommand) {
        let newText = editingCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else {
            cancelEditing()
            return
        }
        
        var updated = command
        updated.command = newText
        settings.updateFavoriteCommand(updated)
        
        editingCommandId = nil
        editingCommandText = ""
    }
    
    private func deleteCommand(_ command: FavoriteCommand) {
        settings.removeFavoriteCommand(id: command.id)
    }
}

// MARK: - Preview

#if DEBUG
struct FavoritesSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        FavoritesSettingsView()
            .frame(width: 600, height: 700)
    }
}
#endif

