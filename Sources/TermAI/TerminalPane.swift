import SwiftUI
import AppKit
import os.log

private let termPaneLogger = Logger(subsystem: "com.termai.app", category: "TerminalPane")

struct TerminalPane: View {
    @EnvironmentObject private var ptyModel: PTYModel
    /// Per-tab suggestion service passed from AppTab via environment
    @EnvironmentObject private var suggestionService: TerminalSuggestionService
    @State private var hasSelection: Bool = false
    @State private var hovering: Bool = false
    @State private var buttonHovering: Bool = false
    
    // Timer for continuous selection checking while hovering
    @State private var selectionCheckTimer: Timer? = nil

    let onAddToChat: (String, TerminalContextMeta?) -> Void
    let onToggleChat: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with glass material
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Terminal")
                    .font(.headline)
                
                // Provider/Model selectors for AI suggestions (similar to chat header)
                TerminalSuggestionsHeaderView(onOpenSettings: onOpenSettings)
                
                // AI Suggestions status badge (shows when suggestions are active/loading)
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
                    // Show action buttons when hovering and there's content to add
                    // (suggestions bar is now static at bottom, so no conflict)
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
                    // Continuously check for selection while hovering
                    // (SwiftTerm doesn't have a selection change callback)
                    if isHovering {
                        checkForSelection()
                        startSelectionCheckTimer()
                    } else {
                        stopSelectionCheckTimer()
                    }
                }
            
            // AI Suggestions Bar (static at bottom)
            TerminalSuggestionsBar(
                suggestionService: suggestionService,
                onRunCommand: runCommand,
                onOpenSettings: onOpenSettings
            )
            .animation(.easeInOut(duration: 0.2), value: suggestionService.isVisible)
        }
        .onReceive(ptyModel.$hasSelection) { hasSelection = $0 }
        .onReceive(ptyModel.$currentWorkingDirectory) { cwd in
            termPaneLogger.info(">>> onReceive CWD changed: '\(cwd, privacy: .public)'")
            // Trigger suggestions on CWD change (debounced by service)
            triggerSuggestionsIfNeeded()
        }
        .onReceive(ptyModel.$lastOutputChunk) { chunk in
            termPaneLogger.debug("onReceive lastOutputChunk changed, len=\(chunk.count), captureActive=\(self.ptyModel.captureActive)")
            // Trigger suggestions after command output (if not in capture mode)
            if !ptyModel.captureActive {
                triggerSuggestionsIfNeeded()
            }
        }
        .onReceive(ptyModel.$lastExitCode) { exitCode in
            termPaneLogger.debug("onReceive lastExitCode: \(exitCode)")
            // Immediately trigger on errors
            if exitCode != 0 && !ptyModel.captureActive {
                triggerSuggestionsIfNeeded()
            }
        }
        .onReceive(ptyModel.$didFinishInitialLoad) { didLoad in
            termPaneLogger.debug("onReceive didFinishInitialLoad: \(didLoad)")
            // Trigger startup suggestions when terminal is ready
            if didLoad {
                triggerStartupSuggestions()
            }
        }
        .onReceive(ptyModel.$lastUserCommand) { command in
            termPaneLogger.debug("onReceive lastUserCommand: \(command ?? "nil")")
            // Record user commands to history for "resume" suggestions
            if let cmd = command, !cmd.isEmpty, !ptyModel.captureActive {
                recordCommandToHistory(cmd)
                
                // CRITICAL: Abort any in-progress suggestion pipeline and restart with fresh context
                // This ensures user activity (typing commands) takes priority over stale suggestions
                suggestionService.userActivityDetected(
                    command: cmd,
                    cwd: ptyModel.currentWorkingDirectory,
                    gitInfo: ptyModel.gitInfo,
                    lastExitCode: ptyModel.lastExitCode,
                    lastOutput: ptyModel.lastOutputChunk
                )
            }
        }
        // Handle Escape key to dismiss suggestions
        .background(
            SuggestionKeyboardHandler(
                suggestionService: suggestionService
            )
        )
        .onAppear {
            // Wire up the terminal context callback for post-command regeneration
            // This must be set early so commandExecuted() can get fresh context
            setupTerminalContextCallback()
        }
        .onDisappear {
            stopSelectionCheckTimer()
        }
    }
    
    // MARK: - Setup
    
    private func setupTerminalContextCallback() {
        termPaneLogger.info("Setting up terminal context callback for suggestion service")
        suggestionService.getTerminalContext = { [weak ptyModel] in
            guard let model = ptyModel else {
                termPaneLogger.warning("PTYModel is nil in terminal context callback")
                return (cwd: "", lastOutput: "", lastExitCode: 0, gitInfo: nil)
            }
            let cwd = model.currentWorkingDirectory
            termPaneLogger.info(">>> getTerminalContext callback invoked - returning cwd: '\(cwd, privacy: .public)'")
            return (
                cwd: cwd,
                lastOutput: model.lastOutputChunk,
                lastExitCode: model.lastExitCode,
                gitInfo: model.gitInfo
            )
        }
    }
    
    // MARK: - Suggestion Triggers
    
    private func triggerSuggestionsIfNeeded() {
        // Don't trigger during agent capture mode
        guard !ptyModel.captureActive else { 
            termPaneLogger.debug("triggerSuggestionsIfNeeded: skipped (captureActive)")
            return 
        }
        
        let cwd = ptyModel.currentWorkingDirectory
        termPaneLogger.info(">>> triggerSuggestionsIfNeeded called with cwd: '\(cwd, privacy: .public)'")
        
        suggestionService.triggerSuggestions(
            cwd: cwd,
            lastOutput: ptyModel.lastOutputChunk,
            lastExitCode: ptyModel.lastExitCode,
            gitInfo: ptyModel.gitInfo
        )
    }
    
    private func triggerStartupSuggestions() {
        // Don't trigger during agent capture mode
        guard !ptyModel.captureActive else { return }
        
        // Ensure callback is set (may have been set in onAppear, but re-set for safety)
        setupTerminalContextCallback()
        
        suggestionService.triggerStartupSuggestions(
            cwd: ptyModel.currentWorkingDirectory,
            gitInfo: ptyModel.gitInfo,
            isNewDirectory: false
        )
    }
    
    private func recordCommandToHistory(_ command: String) {
        // Record the command with the current exit code
        // Note: Exit code may not be updated yet, so we use 0 as default
        // The exit code will be properly tracked when we receive it
        CommandHistoryStore.shared.recordCommand(
            command,
            cwd: ptyModel.currentWorkingDirectory,
            exitCode: ptyModel.lastExitCode
        )
    }
    
    private func runCommand(_ command: String) {
        termPaneLogger.info("Running suggested command: \(command)")
        // Run the command immediately in the terminal (with newline to execute)
        ptyModel.sendInput?(command + "\n")
        // Clear suggestions and set cooldown
        suggestionService.commandExecuted(command: command, cwd: ptyModel.currentWorkingDirectory, waitForCWDUpdate: true)
        
        // For cd commands, manually update CWD after a short delay
        // OSC 7 detection doesn't reliably work for programmatic sendInput commands
        if command.hasPrefix("cd ") {
            let cdTarget = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let currentCWD = ptyModel.currentWorkingDirectory
            
            // Schedule CWD update after command has time to execute
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                
                // Resolve the target path
                let resolvedPath: String
                if cdTarget.hasPrefix("~") {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    resolvedPath = home + cdTarget.dropFirst()
                } else if cdTarget.hasPrefix("/") {
                    resolvedPath = cdTarget
                } else if cdTarget == "-" {
                    // cd - goes to previous directory, skip manual update
                    return
                } else if cdTarget == ".." {
                    resolvedPath = (currentCWD as NSString).deletingLastPathComponent
                } else if cdTarget.hasPrefix("..") {
                    // Handle paths like ../foo or ../../bar
                    resolvedPath = (currentCWD as NSString).appendingPathComponent(cdTarget)
                } else {
                    // Relative path
                    resolvedPath = (currentCWD as NSString).appendingPathComponent(cdTarget)
                }
                
                // Normalize the path
                let normalizedPath = (resolvedPath as NSString).standardizingPath
                
                // Verify the directory exists before updating
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDir), isDir.boolValue {
                    termPaneLogger.info("Manually updating CWD after cd: \(currentCWD) → \(normalizedPath)")
                    ptyModel.currentWorkingDirectory = normalizedPath
                } else {
                    termPaneLogger.warning("cd target doesn't exist or isn't a directory: \(normalizedPath)")
                }
            }
        }
    }
    
    private func checkForSelection() {
        // Manually check for selection since rangeChanged doesn't fire on selection changes
        let selection = ptyModel.getSelectionText?() ?? ""
        hasSelection = !selection.isEmpty
    }
    
    private func startSelectionCheckTimer() {
        stopSelectionCheckTimer()
        // Check every 200ms while hovering to catch selection changes
        // Capture the model reference for the timer callback
        let model = ptyModel
        selectionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak model] _ in
            DispatchQueue.main.async {
                guard let model = model else { return }
                let selection = model.getSelectionText?() ?? ""
                // Update will happen through the published property
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

// MARK: - Keyboard Handler for Suggestions
private struct SuggestionKeyboardHandler: NSViewRepresentable {
    @ObservedObject var suggestionService: TerminalSuggestionService
    
    func makeNSView(context: Context) -> KeyEventMonitorView {
        let view = KeyEventMonitorView()
        view.setupMonitor(suggestionService: suggestionService)
        return view
    }
    
    func updateNSView(_ nsView: KeyEventMonitorView, context: Context) {
        // Update the service reference if needed
        nsView.suggestionService = suggestionService
    }
    
    /// NSView that uses a local event monitor to intercept key events
    /// This works without requiring first responder status
    class KeyEventMonitorView: NSView {
        weak var suggestionService: TerminalSuggestionService?
        private var eventMonitor: Any?
        
        func setupMonitor(suggestionService: TerminalSuggestionService) {
            self.suggestionService = suggestionService
            
            // Remove any existing monitor
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            
            // Add local event monitor for key down events
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                
                // Only handle events if our window is key
                guard self.window?.isKeyWindow == true else { return event }
                
                // Check for Escape key
                if event.keyCode == 53 { // Escape
                    if self.suggestionService?.isVisible == true {
                        Task { @MainActor in
                            self.suggestionService?.clearSuggestions(userInitiated: true)
                        }
                        return nil // Consume the event
                    }
                }
                
                // Check for Control+Space to toggle suggestions
                if event.keyCode == 49 && event.modifierFlags.contains(.control) { // Space with Control
                    Task { @MainActor in
                        self.suggestionService?.toggleVisibility()
                    }
                    return nil // Consume the event
                }
                
                return event // Pass through unhandled events
            }
        }
        
        deinit {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Terminal Suggestions Header View

/// Compact provider/model selectors for terminal AI suggestions in the header bar
struct TerminalSuggestionsHeaderView: View {
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject private var apiKeyManager = CloudAPIKeyManager.shared
    
    // Local models fetching state
    @State private var localModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var modelFetchError: String? = nil
    
    let onOpenSettings: () -> Void
    
    private var availableCloudProviders: [CloudProvider] {
        CloudAPIKeyManager.shared.availableProviders
    }
    
    private var providerIcon: String {
        guard let provider = agentSettings.terminalSuggestionsProvider else {
            return "questionmark.circle"
        }
        switch provider {
        case .cloud(let cloudProvider):
            return cloudProvider.icon
        case .local(let localProvider):
            return localProvider.icon
        }
    }
    
    private var providerColor: Color {
        guard let provider = agentSettings.terminalSuggestionsProvider else {
            return .gray
        }
        switch provider {
        case .cloud(let cloudProvider):
            switch cloudProvider {
            case .openai: return .green
            case .anthropic: return .orange
            }
        case .local(let localProvider):
            switch localProvider {
            case .ollama: return .blue
            case .lmStudio: return .purple
            case .vllm: return .orange
            }
        }
    }
    
    private var providerName: String {
        guard let provider = agentSettings.terminalSuggestionsProvider else {
            return "Select"
        }
        return provider.displayName
    }
    
    private var availableModels: [String] {
        guard let provider = agentSettings.terminalSuggestionsProvider else {
            return []
        }
        switch provider {
        case .cloud(let cloudProvider):
            return CuratedModels.models(for: cloudProvider).map { $0.id }
        case .local:
            return localModels
        }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            // Provider selector - compact chip
            providerSelector
            
            // Model selector - compact chip (only if provider is selected)
            if agentSettings.terminalSuggestionsProvider != nil {
                modelSelector
            }
        }
    }
    
    // MARK: - Provider Selector
    
    private var providerSelector: some View {
        Menu {
            // Cloud Providers Section
            if !availableCloudProviders.isEmpty {
                Text("Cloud Providers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(availableCloudProviders, id: \.rawValue) { provider in
                    Button(action: {
                        selectCloudProvider(provider)
                    }) {
                        HStack {
                            Image(systemName: provider.icon)
                            Text(provider.rawValue)
                            if agentSettings.terminalSuggestionsProvider == .cloud(provider) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                
                Divider()
            }
            
            Text("Local Providers")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ForEach(LocalLLMProvider.allCases, id: \.rawValue) { provider in
                Button(action: {
                    selectLocalProvider(provider)
                }) {
                    HStack {
                        Image(systemName: provider.icon)
                        Text(provider.rawValue)
                        if agentSettings.terminalSuggestionsProvider == .local(provider) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            
            Divider()
            
            // Settings link
            Button(action: onOpenSettings) {
                Label("All Settings...", systemImage: "gearshape")
            }
        } label: {
            providerChipLabel
        }
        .controlSize(.mini)
        .menuStyle(.borderlessButton)
        .help("Select AI provider for suggestions")
    }
    
    private var providerChipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: providerIcon)
                .font(.system(size: 9))
            Text(providerName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(agentSettings.terminalSuggestionsProvider == nil ? .orange : providerColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(agentSettings.terminalSuggestionsProvider == nil 
                    ? Color.orange.opacity(0.15) 
                    : providerColor.opacity(0.1))
        )
        .overlay(
            Capsule()
                .stroke(agentSettings.terminalSuggestionsProvider == nil 
                    ? Color.orange.opacity(0.3) 
                    : providerColor.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Model Selector
    
    private var modelSelector: some View {
        Menu {
            if availableModels.isEmpty && !isFetchingModels {
                if agentSettings.terminalSuggestionsProvider?.isLocal == true {
                    Button("Click to fetch models...") {
                        fetchModels()
                    }
                } else {
                    Button("No models available") { }
                        .disabled(true)
                }
            } else if isFetchingModels {
                Button("Loading models...") { }
                    .disabled(true)
            } else {
                // All models with reasoning icon support
                ForEach(availableModels, id: \.self) { modelId in
                    let isReasoning = CuratedModels.supportsReasoning(modelId: modelId)
                    let isSelected = agentSettings.terminalSuggestionsModelId == modelId
                    
                    Button(action: {
                        agentSettings.terminalSuggestionsModelId = modelId
                        agentSettings.save()
                    }) {
                        HStack {
                            if isReasoning {
                                ReasoningBrainLabel(displayName(for: modelId), size: .small)
                            } else {
                                Text(displayName(for: modelId))
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            
            // Refresh button for local providers
            if agentSettings.terminalSuggestionsProvider?.isLocal == true {
                Divider()
                Button(action: fetchModels) {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(isFetchingModels)
            }
        } label: {
            modelChipLabel
        }
        .controlSize(.mini)
        .menuStyle(.borderlessButton)
        .help(agentSettings.terminalSuggestionsModelId == nil 
            ? "Select AI model for suggestions" 
            : "Current model: \(agentSettings.terminalSuggestionsModelId ?? "")")
        .onAppear {
            // Auto-fetch models for local providers
            if agentSettings.terminalSuggestionsProvider?.isLocal == true && localModels.isEmpty {
                fetchModels()
            }
        }
    }
    
    private var modelChipLabel: some View {
        HStack(spacing: 4) {
            if isFetchingModels {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            } else if let modelId = agentSettings.terminalSuggestionsModelId,
                      CuratedModels.supportsReasoning(modelId: modelId) {
                // Show brain icon for reasoning models
                ReasoningBrainIcon(size: .small, showGlow: true)
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 9))
            }
            
            if let modelId = agentSettings.terminalSuggestionsModelId {
                Text(displayName(for: modelId))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Model")
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundColor(agentSettings.terminalSuggestionsModelId == nil ? .orange : .primary)
        .frame(minWidth: 50, maxWidth: 120)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(agentSettings.terminalSuggestionsModelId == nil 
                    ? Color.orange.opacity(0.15) 
                    : Color.primary.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(agentSettings.terminalSuggestionsModelId == nil 
                    ? Color.orange.opacity(0.3) 
                    : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    // MARK: - Helper Methods
    
    private func selectCloudProvider(_ provider: CloudProvider) {
        let wasLocal = agentSettings.terminalSuggestionsProvider?.isLocal == true
        agentSettings.terminalSuggestionsProvider = .cloud(provider)
        // Reset model if switching from local to cloud or different cloud provider
        if wasLocal || (agentSettings.terminalSuggestionsModelId.map { CuratedModels.find(id: $0)?.provider != provider } ?? true) {
            agentSettings.terminalSuggestionsModelId = nil
        }
        agentSettings.save()
    }
    
    private func selectLocalProvider(_ provider: LocalLLMProvider) {
        let wasCloud = agentSettings.terminalSuggestionsProvider?.isCloud == true
        let wasDifferentLocal = agentSettings.terminalSuggestionsProvider != .local(provider)
        
        agentSettings.terminalSuggestionsProvider = .local(provider)
        // Reset model if switching providers
        if wasCloud || wasDifferentLocal {
            agentSettings.terminalSuggestionsModelId = nil
            localModels = []
            fetchModels()
        }
        agentSettings.save()
    }
    
    private func fetchModels() {
        guard case .local(let provider) = agentSettings.terminalSuggestionsProvider else { return }
        
        isFetchingModels = true
        modelFetchError = nil
        
        Task {
            defer {
                Task { @MainActor in
                    isFetchingModels = false
                }
            }
            
            do {
                let models = try await LocalProviderService.fetchModels(for: provider)
                await MainActor.run {
                    localModels = models
                    if models.isEmpty {
                        modelFetchError = "No models found"
                    }
                }
            } catch {
                await MainActor.run {
                    modelFetchError = error.localizedDescription
                    localModels = []
                }
            }
        }
    }
    
    private func displayName(for modelId: String) -> String {
        CuratedModels.find(id: modelId)?.displayName ?? modelId
    }
}

// MARK: - Terminal Action Button (Vibrant Style)
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
    @Environment(\.colorScheme) var colorScheme
    
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

