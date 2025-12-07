import SwiftUI

// MARK: - Editor Pane View

/// Container view managing the editor tab bar and content (terminal or file viewer)
struct EditorPaneView: View {
    @ObservedObject var tabsManager: EditorTabsManager
    @EnvironmentObject var ptyModel: PTYModel
    @EnvironmentObject var suggestionService: TerminalSuggestionService
    
    let onAddToChat: (String, TerminalContextMeta?) -> Void
    let onToggleChat: () -> Void
    let onToggleFileTree: () -> Void
    let onOpenSettings: () -> Void
    let onAddFileToChat: (String, String?, [LineRange]?) -> Void  // (content, filePath, lineRanges)
    let isFileTreeVisible: Bool
    let isChatVisible: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            EditorTabBar(tabsManager: tabsManager)
                .environmentObject(tabsManager)
            
            Divider()
            
            // Content area - show terminal or file viewer based on selected tab
            ZStack {
                // Terminal (always keep alive to preserve state)
                terminalContent
                    .opacity(tabsManager.selectedTab?.type.isTerminal == true ? 1 : 0)
                    .allowsHitTesting(tabsManager.selectedTab?.type.isTerminal == true)
                
                // File viewers for open files
                ForEach(tabsManager.fileTabs) { tab in
                    FileViewerTab(tab: tab, onAddToChat: onAddFileToChat)
                        .opacity(tabsManager.selectedTabId == tab.id ? 1 : 0)
                        .allowsHitTesting(tabsManager.selectedTabId == tab.id)
                }
            }
        }
        // Handle plan opening from chat
        .onReceive(NotificationCenter.default.publisher(for: .TermAIOpenPlanInEditor)) { note in
            if let planId = note.userInfo?["planId"] as? UUID {
                tabsManager.openPlan(id: planId)
            }
        }
        // Handle file opening from chat
        .onReceive(NotificationCenter.default.publisher(for: .TermAIOpenFileInEditor)) { note in
            if let path = note.userInfo?["path"] as? String {
                tabsManager.openFile(at: path)
            }
        }
    }
    
    // MARK: - Terminal Content
    
    private var terminalContent: some View {
        TerminalPaneContent(
            onAddToChat: onAddToChat,
            onToggleChat: onToggleChat,
            onToggleFileTree: onToggleFileTree,
            onOpenSettings: onOpenSettings,
            isFileTreeVisible: isFileTreeVisible,
            isChatVisible: isChatVisible
        )
        .environmentObject(ptyModel)
        .environmentObject(suggestionService)
    }
}

// MARK: - Terminal Pane Content (Extracted from TerminalPane)

/// The terminal view content without header (header is replaced by editor tabs)
struct TerminalPaneContent: View {
    @EnvironmentObject private var ptyModel: PTYModel
    @EnvironmentObject private var suggestionService: TerminalSuggestionService
    
    @State private var hasSelection: Bool = false
    @State private var hovering: Bool = false
    @State private var buttonHovering: Bool = false
    @State private var selectionCheckTimer: Timer? = nil
    @State private var hoveredFavoriteCommand: (command: FavoriteCommand, index: Int)? = nil

    let onAddToChat: (String, TerminalContextMeta?) -> Void
    let onToggleChat: () -> Void
    let onToggleFileTree: () -> Void
    let onOpenSettings: () -> Void
    let isFileTreeVisible: Bool
    let isChatVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Terminal header (condensed - model/provider selector)
            terminalHeader
            
            // Terminal view with favorites toolbar and contextual action overlay
            HStack(spacing: 0) {
                // Favorites toolbar (left side, only shown if favorites exist)
                FavoritesToolbarWithTooltip(
                    onRunCommand: runFavoriteCommand,
                    hoveredCommandInfo: $hoveredFavoriteCommand
                )
                
                // Terminal view with action overlay
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
                                        color: .cyan,
                                        action: addSelectionToChat
                                    )
                                    .onHover { buttonHovering = $0 }
                                }
                                if hasChunk {
                                    TerminalActionButton(
                                        label: "Add Last Output",
                                        icon: "plus.circle.fill",
                                        color: .green,
                                        action: addLastOutputToChat
                                    )
                                    .onHover { buttonHovering = $0 }
                                }
                            }
                            .padding(12)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .onHover { isHovering in
                        hovering = isHovering
                        if isHovering {
                            checkForSelection()
                            startSelectionCheckTimer()
                        } else {
                            stopSelectionCheckTimer()
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                if let info = hoveredFavoriteCommand {
                    CommandTooltip(command: info.command.command, name: info.command.name)
                        .fixedSize()
                        .offset(
                            x: FavoritesToolbar.toolbarWidth + 4,
                            y: FavoritesToolbar.topPadding + CGFloat(info.index) * (FavoritesToolbar.buttonSize + FavoritesToolbar.buttonSpacing)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
                        .allowsHitTesting(false)
                }
            }
            
            // AI Suggestions Bar
            TerminalSuggestionsBar(
                suggestionService: suggestionService,
                onRunCommand: runCommand,
                onOpenSettings: onOpenSettings
            )
            .animation(.easeInOut(duration: 0.2), value: suggestionService.isVisible)
        }
        .onReceive(ptyModel.$hasSelection) { hasSelection = $0 }
        .onDisappear {
            stopSelectionCheckTimer()
        }
    }
    
    // MARK: - Terminal Header
    
    private var terminalHeader: some View {
        HStack(spacing: 8) {
            // Provider/Model selectors for AI suggestions
            TerminalSuggestionsHeaderView(onOpenSettings: onOpenSettings)
            
            // AI Suggestions status badge
            SuggestionBadge(
                suggestionService: suggestionService,
                onTap: {
                    if suggestionService.needsModelSetup {
                        onOpenSettings()
                    } else {
                        suggestionService.toggleVisibility()
                    }
                }
            )
            
            Spacer()
            
            // File tree toggle button
            Button(action: onToggleFileTree) {
                Image(systemName: isFileTreeVisible ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isFileTreeVisible ? .accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isFileTreeVisible ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle File Tree (⌘B)")
            
            // Chat toggle button
            Button(action: onToggleChat) {
                Image(systemName: isChatVisible ? "bubble.right.fill" : "bubble.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isChatVisible ? .accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isChatVisible ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle Chat Panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Actions
    
    private func runFavoriteCommand(_ command: String) {
        ptyModel.sendInput?(command + "\n")
    }
    
    private func runCommand(_ command: String) {
        ptyModel.sendInput?(command + "\n")
        suggestionService.commandExecuted(command: command, cwd: ptyModel.currentWorkingDirectory, waitForCWDUpdate: true)
    }
    
    private func checkForSelection() {
        let selection = ptyModel.getSelectionText?() ?? ""
        hasSelection = !selection.isEmpty
    }
    
    private func startSelectionCheckTimer() {
        stopSelectionCheckTimer()
        let model = ptyModel
        selectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak model] _ in
            DispatchQueue.main.async {
                guard let model = model else { return }
                let selection = model.getSelectionText?() ?? ""
                model.hasSelection = !selection.isEmpty
            }
        }
    }
    
    private func stopSelectionCheckTimer() {
        selectionCheckTimer?.invalidate()
        selectionCheckTimer = nil
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

// MARK: - Terminal Action Button (Copied from TerminalPane for use here)

private struct TerminalActionButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    let color: Color
    
    init(label: String, icon: String, color: Color = .blue, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.color = color
        self.action = action
    }
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? color : color.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(color.opacity(isHovered ? 0.2 : 0.12))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(isHovered ? 0.6 : 0.35), lineWidth: 1)
            )
            .shadow(color: color.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 8 : 4, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#if DEBUG
struct EditorPaneView_Previews: PreviewProvider {
    static var previews: some View {
        let tabsManager = EditorTabsManager()
        tabsManager.openFile(at: "/Users/test/App.swift")
        
        return EditorPaneView(
            tabsManager: tabsManager,
            onAddToChat: { _, _ in },
            onToggleChat: {},
            onToggleFileTree: {},
            onOpenSettings: {},
            onAddFileToChat: { _, _, _ in },
            isFileTreeVisible: true,
            isChatVisible: true
        )
        .environmentObject(PTYModel())
        .environmentObject(TerminalSuggestionService())
        .environmentObject(tabsManager)
        .frame(width: 600, height: 400)
    }
}
#endif

