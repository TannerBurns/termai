import SwiftUI

/// Container view that manages multiple chat tabs
struct ChatContainerView: View {
    @EnvironmentObject var tabsManager: ChatTabsManager
    @StateObject private var historyManager = ChatHistoryManager.shared
    @ObservedObject private var processManager = ProcessManager.shared
    @ObservedObject var ptyModel: PTYModel
    
    // Command approval state
    // Command approval is now inline (no longer using sheet)
    @State private var showingHistoryPopover: Bool = false
    @State private var showingProcessMonitor: Bool = false
    
    // File change approval state
    @State private var pendingFileChangeApproval: PendingFileChangeApproval? = nil
    
    // Test runner state
    @State private var showingTestRunner: Bool = false
    @StateObject private var testRunnerWrapper = TestRunnerAgentWrapper(agent: nil)
    
    var body: some View {
        VStack(spacing: 0) {
            // Main Chat header with provider/model info
            HStack(spacing: 8) {
                Text("Chat")
                    .font(.headline)
                
                if let session = tabsManager.selectedSession {
                    // Provider and model selectors (agent controls moved to per-chat)
                    SessionHeaderView(session: session)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            // Tab bar below header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tabsManager.sessions.enumerated()), id: \.element.id) { index, session in
                        let isSelected = session.id == tabsManager.selectedSessionId
                        
                        ChatTabPill(
                            session: session,
                            index: index,
                            isSelected: isSelected,
                            onSelect: { tabsManager.selectSession(id: session.id) },
                            onClose: { tabsManager.closeSession(at: index) }
                        )
                    }
                    
                    // New chat button
                    Button(action: {
                        _ = tabsManager.createNewSession(copySettingsFrom: tabsManager.selectedSession)
                    }) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("New Chat Session (⇧⌘T)")
                    
                    // History button
                    Button(action: { showingHistoryPopover.toggle() }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundColor(historyManager.entries.isEmpty ? .secondary.opacity(0.5) : .secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(historyManager.entries.isEmpty)
                    .help(historyManager.entries.isEmpty ? "No chat history" : "View chat history")
                    .popover(isPresented: $showingHistoryPopover, arrowEdge: .bottom) {
                        ChatHistoryPopover(
                            entries: historyManager.entries,
                            onRestore: { entry in
                                _ = tabsManager.restoreFromHistory(sessionId: entry.id)
                                showingHistoryPopover = false
                            },
                            onDelete: { entry in
                                historyManager.deleteEntry(id: entry.id)
                            },
                            onClearAll: {
                                historyManager.clearAllEntries()
                                showingHistoryPopover = false
                            }
                        )
                    }
                    
                    // Process Monitor button (only visible when processes are running)
                    if !processManager.runningProcesses.isEmpty {
                        ProcessMonitorButton(
                            processCount: processManager.runningCount,
                            isShowingPopover: $showingProcessMonitor
                        )
                        .popover(isPresented: $showingProcessMonitor, arrowEdge: .bottom) {
                            ProcessMonitorPopover(
                                processes: processManager.runningProcesses,
                                onStop: { pid in
                                    _ = processManager.stopProcess(pid: pid)
                                },
                                onStopAll: {
                                    processManager.stopAllProcesses()
                                    showingProcessMonitor = false
                                }
                            )
                        }
                    }
                    
                    // Test Runner button with progress (only shown if enabled in settings)
                    if AgentSettings.shared.testRunnerEnabled {
                        TestRunnerButton(
                            agent: testRunnerWrapper.agent,
                            onStart: { startTestRunner() },
                            onShowPanel: { showingTestRunner = true },
                            isDisabled: !(tabsManager.selectedSession?.isConfigured ?? false)
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial.opacity(0.5))
            
            Divider()
            
            // Selected chat tab content (without redundant header)
            if let selectedSession = tabsManager.selectedSession,
               let index = tabsManager.sessions.firstIndex(where: { $0.id == selectedSession.id }) {
                SessionContentSwitcher(
                    session: selectedSession,
                    tabIndex: index,
                    ptyModel: ptyModel
                )
                .id(selectedSession.id) // Force view recreation when session changes
                .onReceive(NotificationCenter.default.publisher(for: .TermAIExecuteCommand)) { note in
                    // When a command is executed, set up prompt-based capture
                    // NO PROBE COMMAND - we capture transparently:
                    // - CWD: tracked via OSC 7 sequences that shells emit automatically
                    // - Exit code: captured via OSC 7777 sequences from precmd hook
                    guard let cmd = note.userInfo?["command"] as? String else { return }
                    let sessionIdFromNote = note.userInfo?["sessionId"] as? UUID
                    
                    // Enqueue the completion callback - supports rapid command sequences
                    // Each command gets its own callback in a FIFO queue
                    ptyModel.enqueueCommandCompletion { [weak ptyModel] in
                        guard let ptyModel = ptyModel else { return }
                        
                        // Get the command output, CWD (from OSC 7), and exit code (from OSC 7777)
                        let output = ptyModel.lastOutputChunk
                        let cwd = ptyModel.currentWorkingDirectory
                        let rc = ptyModel.lastExitCode
                        
                        // Route the finish to the same session id that issued the command
                        let sid = sessionIdFromNote ?? selectedSession.id
                        NotificationCenter.default.post(name: .TermAICommandFinished, object: nil, userInfo: [
                            "sessionId": sid,
                            "command": cmd,
                            "output": output,
                            "cwd": cwd,
                            "exitCode": rc
                        ])
                        
                        // Clear last-sent marker after capture
                        ptyModel.lastSentCommandForCapture = nil
                        // Disable capture state only if no more pending commands
                        // (captureActive will be re-enabled by the next command if any)
                    }
                    
                    // Mark capture active during command execution
                    ptyModel.captureActive = true
                }
            } else {
                Color.clear
            }
        }
        .background(.regularMaterial)
        // Command approval is now handled inline in chat via AgentEventView
        // The notification is still posted but we don't show a sheet anymore
        .onReceive(NotificationCenter.default.publisher(for: .TermAICommandPendingApproval)) { _ in
            // Inline approval buttons are shown in the chat message
            // No need to show the sheet anymore
        }
        // File change approval is now handled inline in chat via AgentEventView
        // The sheet is kept for viewing changes via ViewChangesButton but auto-show is disabled
        .onReceive(NotificationCenter.default.publisher(for: .TermAIFileChangePendingApproval)) { _ in
            // Inline approval buttons are shown in the chat message
            // No need to auto-show the sheet anymore
        }
        .sheet(item: $pendingFileChangeApproval) { approval in
            FileChangeApprovalSheet(
                approval: approval,
                onApprove: {
                    NotificationCenter.default.post(
                        name: .TermAIFileChangeApprovalResponse,
                        object: nil,
                        userInfo: [
                            "approvalId": approval.id,
                            "approved": true
                        ]
                    )
                    pendingFileChangeApproval = nil
                },
                onReject: {
                    NotificationCenter.default.post(
                        name: .TermAIFileChangeApprovalResponse,
                        object: nil,
                        userInfo: [
                            "approvalId": approval.id,
                            "approved": false
                        ]
                    )
                    pendingFileChangeApproval = nil
                },
                onPartialApprove: { decisions, modifiedContent in
                    NotificationCenter.default.post(
                        name: .TermAIFileChangeApprovalResponse,
                        object: nil,
                        userInfo: [
                            "approvalId": approval.id,
                            "approved": true,
                            "partialApproval": true,
                            "hunkDecisions": decisions,
                            "modifiedContent": modifiedContent
                        ]
                    )
                    pendingFileChangeApproval = nil
                }
            )
        }
        .sheet(isPresented: $showingTestRunner) {
            if let agent = testRunnerWrapper.agent {
                TestRunnerPanel(
                    agent: agent,
                    onDismiss: {
                        showingTestRunner = false
                    },
                    onRerun: {
                        // Create fresh agent with current CWD and re-run
                        startTestRunner()
                    },
                    onRerunFailed: {
                        Task {
                            await agent.rerunFailed()
                        }
                    },
                    onRunFix: { command in
                        Task {
                            await agent.runFixAndRetry(command: command)
                        }
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .TermAITestRunnerShow)) { _ in
            startTestRunner()
            showingTestRunner = true
        }
        .onChange(of: ptyModel.currentWorkingDirectory) { _ in
            // Reset test runner when directory changes so user can run tests in the new location
            if testRunnerWrapper.agent != nil {
                testRunnerWrapper.setAgent(nil)
                showingTestRunner = false
            }
        }
    }
    
    // MARK: - Test Runner Helpers
    
    /// Start a new test run in the background (creates agent if needed)
    private func startTestRunner() {
        guard let session = tabsManager.selectedSession else { return }
        
        // Get project path from terminal CWD or fallback
        let projectPath = ptyModel.currentWorkingDirectory.isEmpty 
            ? FileManager.default.currentDirectoryPath 
            : ptyModel.currentWorkingDirectory
        
        // Create new agent with current session's provider/model
        let agent = TestRunnerAgent(
            provider: session.providerType,
            modelId: session.model,
            projectPath: projectPath
        )
        
        // Update the wrapper with the new agent
        testRunnerWrapper.setAgent(agent)
        
        // Start the test run in background - UI will update via @ObservedObject wrapper
        Task {
            await agent.runTests()
        }
    }
}

// MARK: - Session Content Switcher
/// Observes the session directly to properly switch between setup and chat views when configuration changes
private struct SessionContentSwitcher: View {
    @ObservedObject var session: ChatSession
    let tabIndex: Int
    @ObservedObject var ptyModel: PTYModel
    
    var body: some View {
        Group {
            if session.isConfigured {
                ChatTabContentView(
                    session: session,
                    tabIndex: tabIndex,
                    ptyModel: ptyModel
                )
            } else {
                SessionSetupPromptView(session: session)
            }
        }
    }
}

// MARK: - Chat Tab Pill
private struct ChatTabPill: View {
    @ObservedObject var session: ChatSession
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var closeHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(session.sessionTitle.isEmpty ? "Chat \(index + 1)" : session.sessionTitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            
            if isSelected || isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(closeHovered ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
                .help("Close Chat (⇧⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}

// Separate view that observes the session for real-time updates (provider/model only)
private struct SessionHeaderView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject private var localProviderManager = LocalProviderAvailabilityManager.shared

    private var availableCloudProviders: [CloudProvider] {
        CloudAPIKeyManager.shared.availableProviders
    }
    
    private var providerIcon: String {
        if case .cloud(let provider) = session.providerType {
            return provider.icon
        }
        return "network"
    }
    
    private var providerColor: Color {
        if case .cloud(let provider) = session.providerType {
            switch provider {
            case .openai: return .green
            case .anthropic: return .orange
            case .google: return .blue
            }
        }
        return .primary
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Provider selector - clickable chip
            Menu {
                // Cloud Providers Section
                Text("Cloud Providers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(CloudProvider.allCases, id: \.rawValue) { provider in
                    let isAvailable = CloudAPIKeyManager.shared.hasAPIKey(for: provider)
                    Button(action: {
                        session.switchToCloudProvider(provider)
                    }) {
                        HStack {
                            Image(systemName: provider.icon)
                            Text(provider.rawValue)
                            if !isAvailable {
                                Text("No API Key")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            if session.providerType == .cloud(provider) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!isAvailable)
                }
                
                Divider()
                
                Text("Local Providers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(LocalLLMProvider.allCases, id: \.rawValue) { provider in
                    let isAvailable = LocalProviderAvailabilityManager.shared.isAvailable(for: provider)
                    Button(action: {
                        session.switchToLocalProvider(provider)
                    }) {
                        HStack {
                            Image(systemName: provider.icon)
                            Text(provider.rawValue)
                            if !isAvailable {
                                Text("Not Running")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            if session.providerType == .local(provider) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!isAvailable)
                }
            } label: {
                Label(session.providerName, systemImage: providerIcon)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(session.providerType.isCloud ? providerColor : .primary)
                    .frame(width: 82, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .controlSize(.mini)
            .menuStyle(.borderlessButton)
            .help("Click to change provider")
            
            // Model selector - clickable chip
            Menu {
                if session.availableModels.isEmpty {
                    Button("Fetching models...") {}
                        .disabled(true)
                } else {
                    ForEach(session.availableModels, id: \.self) { modelId in
                        let isFavorite = agentSettings.isFavorite(modelId)
                        let isReasoning = CuratedModels.supportsReasoning(modelId: modelId)
                        let isSelected = modelId == session.model
                        
                        Button(action: {
                            session.model = modelId
                            session.updateContextLimit()
                            session.persistSettings()
                        }) {
                            // Star prefix for favorites, checkmark suffix for selected
                            let prefix = isFavorite ? "★ " : ""
                            let suffix = isSelected ? " ✓" : ""
                            
                            if isReasoning {
                                // Use enhanced brain icon for reasoning models
                                ReasoningBrainLabel(prefix + displayName(for: modelId) + suffix, size: .small)
                            } else {
                                Text(prefix + displayName(for: modelId) + suffix)
                            }
                        }
                    }
                    
                    if !session.providerType.isCloud {
                        Divider()
                        
                        Button("Refresh Models") {
                            Task {
                                await session.fetchAvailableModels(forceRefresh: true)
                            }
                        }
                    }
                }
            } label: {
                if session.model.isEmpty {
                    Label("Select Model", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.orange)
                        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                } else {
                    HStack(spacing: 4) {
                        // Show enhanced brain for reasoning models, cpu for others
                        if session.currentModelSupportsReasoning {
                            ReasoningBrainIcon(size: .small, showGlow: true)
                        } else {
                            Image(systemName: "cpu")
                            .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(displayName(for: session.model))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        // Favorite indicator - RIGHT of model name
                        if agentSettings.isFavorite(session.model) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                        }
                    }
                    .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.ultraThinMaterial))
                }
            }
            .id(agentSettings.favoriteModels) // Force menu refresh when favorites change
            .controlSize(.mini)
            .menuStyle(.borderlessButton)
            .help("Click to change model")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func displayName(for modelId: String) -> String {
        CuratedModels.find(id: modelId)?.displayName ?? modelId
    }
}

// MARK: - Chat History Popover

private struct ChatHistoryPopover: View {
    let entries: [ChatHistoryEntry]
    let onRestore: (ChatHistoryEntry) -> Void
    let onDelete: (ChatHistoryEntry) -> Void
    let onClearAll: () -> Void
    
    @State private var hoveredEntry: UUID? = nil
    @State private var showingClearConfirmation: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    private let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
                Text("Chat History")
                    .font(.headline)
                Spacer()
                
                if entries.count > 1 {
                    Button(action: { showingClearConfirmation = true }) {
                        Text("Clear All")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all chat history")
                    
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                }
                
                Text("\(entries.count) saved")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
            
            Divider()
            
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No saved chats")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ChatHistoryRow(
                                entry: entry,
                                isHovered: hoveredEntry == entry.id,
                                dateFormatter: dateFormatter,
                                onRestore: { onRestore(entry) },
                                onDelete: { onDelete(entry) }
                            )
                            .onHover { hovering in
                                hoveredEntry = hovering ? entry.id : nil
                            }
                            
                            if entry.id != entries.last?.id {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 320)
        .background(colorScheme == .dark ? Color(white: 0.1) : Color.white)
        .alert("Clear All History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                onClearAll()
            }
        } message: {
            Text("This will permanently delete all \(entries.count) saved chat sessions. This action cannot be undone.")
        }
    }
}

// MARK: - Chat History Row

private struct ChatHistoryRow: View {
    let entry: ChatHistoryEntry
    let isHovered: Bool
    let dateFormatter: RelativeDateTimeFormatter
    let onRestore: () -> Void
    let onDelete: () -> Void
    
    @State private var deleteHovered: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            // Main content - clickable to restore
            Button(action: onRestore) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    Text(entry.messagePreview)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Text(dateFormatter.localizedString(for: entry.savedDate, relativeTo: Date()))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                        
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("\(entry.messageCount) messages")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                        
                        // Show plan indicator if session has plans
                        if !entry.planIds.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.5))
                            
                            HStack(spacing: 3) {
                                Image(systemName: "map.fill")
                                    .font(.system(size: 8))
                                Text(entry.planIds.count == 1 ? "1 plan" : "\(entry.planIds.count) plans")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(Color(red: 0.7, green: 0.4, blue: 0.9).opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            
            // Delete button - visible on hover
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(deleteHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { deleteHovered = $0 }
                .help("Remove from history")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Process Monitor Button

struct ProcessMonitorButton: View {
    let processCount: Int
    @Binding var isShowingPopover: Bool
    
    @State private var isHovered: Bool = false
    @State private var isPulsing: Bool = false
    
    var body: some View {
        Button(action: { isShowingPopover.toggle() }) {
            ZStack(alignment: .topTrailing) {
                // Main icon
                Image(systemName: "gearshape.2.fill")
                    .font(.caption)
                    .foregroundColor(isHovered ? .accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    )
                    .scaleEffect(isPulsing ? 1.05 : 1.0)
                
                // Badge with count
                Text("\(processCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(
                        Circle()
                            .fill(Color.green)
                    )
                    .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(processCount) background process\(processCount == 1 ? "" : "es") running")
        .onAppear {
            // Subtle pulse animation
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Process Monitor Popover

struct ProcessMonitorPopover: View {
    let processes: [BackgroundProcessInfo]
    let onStop: (Int32) -> Void
    let onStopAll: () -> Void
    
    @State private var expandedPid: Int32? = nil
    @State private var hoveredPid: Int32? = nil
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.2.fill")
                    .foregroundColor(.accentColor)
                Text("Background Processes")
                    .font(.headline)
                Spacer()
                
                if processes.count > 1 {
                    Button(action: onStopAll) {
                        Text("Stop All")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Process list
            if processes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundColor(.green)
                    Text("No background processes")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(processes) { process in
                            ProcessRow(
                                process: process,
                                isExpanded: expandedPid == process.id,
                                isHovered: hoveredPid == process.id,
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedPid == process.id {
                                            expandedPid = nil
                                        } else {
                                            expandedPid = process.id
                                        }
                                    }
                                },
                                onStop: { onStop(process.id) }
                            )
                            .onHover { hoveredPid = $0 ? process.id : nil }
                            
                            if process.id != processes.last?.id {
                                Divider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Process Row

private struct ProcessRow: View {
    let process: BackgroundProcessInfo
    let isExpanded: Bool
    let isHovered: Bool
    let onToggleExpand: () -> Void
    let onStop: () -> Void
    
    @State private var stopHovered: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(process.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(process.isRunning ? Color.green.opacity(0.3) : Color.clear, lineWidth: 3)
                            .scaleEffect(1.5)
                    )
                
                // Process info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("PID \(process.id)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text(process.uptimeString)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Text(process.shortCommand)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Expand button
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                // Stop button
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(stopHovered ? .red : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(stopHovered ? Color.red.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { stopHovered = $0 }
                .help("Stop process")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? (colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            
            // Expanded output
            if isExpanded && !process.recentOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Output:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(process.recentOutput)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 80)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.leading, 20)
                .background(colorScheme == .dark ? Color.black.opacity(0.2) : Color.gray.opacity(0.1))
            }
        }
    }
}

// MARK: - Agent Checklist Popover

struct AgentChecklistPopover: View {
    let checklist: TaskChecklist?
    let currentStep: Int
    let estimatedSteps: Int
    let phase: String
    
    @State private var hoveredItemId: Int? = nil
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .foregroundColor(.blue)
                Text("Agent Progress")
                    .font(.headline)
                Spacer()
                
                // Progress badge with donut chart
                if let checklist = checklist {
                    HStack(spacing: 6) {
                        ProgressDonut(
                            completed: checklist.completedCount,
                            total: checklist.items.count,
                            size: 18,
                            lineWidth: 3
                        )
                        
                        Text("\(checklist.completedCount)/\(checklist.items.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                } else if estimatedSteps > 0 {
                    Text("Step \(currentStep)/~\(estimatedSteps)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Current phase indicator
            if !phase.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text("Current: \(phase)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
            }
            
            // Checklist items or empty state
            if let checklist = checklist, !checklist.items.isEmpty {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                        Rectangle()
                            .fill(Color.green.opacity(0.6))
                            .frame(width: geo.size.width * CGFloat(checklist.progressPercent) / 100.0)
                    }
                }
                .frame(height: 3)
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(checklist.items) { item in
                            ChecklistItemRow(
                                item: item,
                                isHovered: hoveredItemId == item.id
                            )
                            .onHover { hoveredItemId = $0 ? item.id : nil }
                            
                            if item.id != checklist.items.last?.id {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            } else {
                // No checklist available yet
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.title2)
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Building task list...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("The agent is analyzing the request")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            
            // Goal description at bottom
            if let checklist = checklist, !checklist.goalDescription.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(checklist.goalDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(colorScheme == .dark ? Color.black.opacity(0.15) : Color.gray.opacity(0.05))
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Checklist Item Row

private struct ChecklistItemRow: View {
    let item: TaskChecklistItem
    let isHovered: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    private var statusColor: Color {
        switch item.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }
    
    private var statusIcon: String {
        switch item.status {
        case .pending: return "circle"
        case .inProgress: return "arrow.right.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "slash.circle"
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundColor(statusColor)
                .frame(width: 20)
            
            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundColor(item.status == .completed || item.status == .skipped ? .secondary : .primary)
                    .strikethrough(item.status == .skipped)
                
                if let note = item.verificationNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .italic()
                }
            }
            
            Spacer()
            
            // Step number badge
            Text("\(item.id)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.1))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            item.status == .inProgress 
                ? Color.blue.opacity(0.08) 
                : (isHovered ? (colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Context Usage Indicator

/// Circular progress indicator showing context window usage
struct ContextUsageIndicator: View {
    @ObservedObject var session: ChatSession
    @State private var isHovered: Bool = false
    @State private var isPulsing: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    /// Show context usage when we have meaningful activity:
    /// - During agent execution (isAgentRunning)
    /// - When we have a real assistant response
    /// Before that, currentContextTokens just reflects estimated system prompt, not real usage
    private var displayedTokens: Int {
        // Always show during active agent execution
        if session.isAgentRunning {
            return session.currentContextTokens
        }
        // Also show if we have agent context accumulated (even if not actively running)
        if !session.agentContextLog.isEmpty {
            return session.currentContextTokens
        }
        // For normal chat, show after first assistant response
        return session.hasAssistantResponse ? session.currentContextTokens : 0
    }
    
    private var usagePercent: Double {
        guard session.effectiveContextLimit > 0 else { return 0 }
        return min(1.0, Double(displayedTokens) / Double(session.effectiveContextLimit))
    }
    
    private var usageColor: Color {
        switch usagePercent {
        case 0..<0.6:
            return .green
        case 0.6..<0.8:
            return .yellow
        case 0.8..<0.9:
            return .orange
        default:
            return .red
        }
    }
    
    private var formattedTokens: String {
        let current = displayedTokens
        let limit = session.effectiveContextLimit
        
        // Format with K suffix for thousands
        func format(_ n: Int) -> String {
            if n >= 1_000_000 {
                return String(format: "%.1fM", Double(n) / 1_000_000)
            } else if n >= 1_000 {
                return String(format: "%.0fK", Double(n) / 1_000)
            }
            return "\(n)"
        }
        
        return "\(format(current)) / \(format(limit))"
    }
    
    private var percentText: String {
        String(format: "%.0f%%", usagePercent * 100)
    }
    
    var body: some View {
        HStack(spacing: 4) {
            // Circular progress ring
            ZStack {
                // Background ring
                Circle()
                    .stroke(usageColor.opacity(0.2), lineWidth: 2)
                    .frame(width: 16, height: 16)
                
                // Progress ring
                Circle()
                    .trim(from: 0, to: usagePercent)
                    .stroke(usageColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: usagePercent)
                
                // Pulse animation when high usage
                if usagePercent > 0.8 && isPulsing {
                    Circle()
                        .stroke(usageColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 16, height: 16)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .opacity(isPulsing ? 0 : 0.5)
                }
            }
            
            // Token count text (shown on hover or when high usage)
            if isHovered || usagePercent > 0.8 {
                Text(formattedTokens)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .transition(.opacity.combined(with: .scale))
            }
            
            // Summarized indicator
            if session.recentlySummarized {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8))
                    Text("Summarized")
                        .font(.system(size: 8))
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.purple.opacity(0.15))
                )
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isHovered ? usageColor.opacity(0.1) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.3), value: session.recentlySummarized)
        .help("Context: \(formattedTokens) tokens (\(percentText))\(session.summarizationCount > 0 ? "\nSummarized \(session.summarizationCount) time(s)" : "")")
        .onAppear {
            // Start pulse animation for high usage
            if usagePercent > 0.8 {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: usagePercent) { newValue in
            if newValue > 0.8 && !isPulsing {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else if newValue <= 0.8 {
                isPulsing = false
            }
        }
    }
}

// MARK: - Context Usage Popover (Detailed View)

struct ContextUsagePopover: View {
    @ObservedObject var session: ChatSession
    @Environment(\.colorScheme) var colorScheme
    
    private var usagePercent: Double {
        session.contextUsagePercent
    }
    
    private var usageColor: Color {
        switch usagePercent {
        case 0..<0.6:
            return .green
        case 0.6..<0.8:
            return .yellow
        case 0.8..<0.9:
            return .orange
        default:
            return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(usageColor)
                Text("Context Usage")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f%%", usagePercent * 100))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(usageColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [usageColor.opacity(0.8), usageColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * usagePercent)
                        .animation(.easeInOut(duration: 0.3), value: usagePercent)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Stats
            VStack(spacing: 8) {
                StatRow(label: "Current", value: formatTokens(session.currentContextTokens))
                StatRow(label: "Limit", value: formatTokens(session.effectiveContextLimit))
                StatRow(label: "Available", value: formatTokens(max(0, session.effectiveContextLimit - session.currentContextTokens)))
                
                if session.summarizationCount > 0 {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundColor(.purple)
                        Text("Summarized \(session.summarizationCount) time(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let date = session.lastSummarizationDate {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                }
                
                if session.providerType.isLocal && session.customLocalContextSize != nil {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("Custom context size")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
    }
    
    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM tokens", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK tokens", Double(count) / 1_000)
        }
        return "\(count) tokens"
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Session Setup Prompt View

/// Shown when a chat session has no model configured yet
private struct SessionSetupPromptView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject private var localProviderManager = LocalProviderAvailabilityManager.shared
    @Environment(\.colorScheme) var colorScheme
    
    private var availableCloudProviders: [CloudProvider] {
        CloudAPIKeyManager.shared.availableProviders
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer()
                    .frame(height: 40)
                
                // Icon and title
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    VStack(spacing: 8) {
                        Text("Welcome to TermAI")
                            .font(.system(size: 24, weight: .bold))
                        
                        Text("Select a provider and model to start chatting")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Setup cards
                VStack(spacing: 16) {
                    // Step 1: Provider
                    setupCard(
                        step: 1,
                        title: "Choose a Provider",
                        subtitle: session.hasExplicitlyConfiguredProvider ? session.providerName : "No provider selected",
                        isComplete: session.hasExplicitlyConfiguredProvider,
                        icon: providerIcon
                    ) {
                        providerPicker
                    }
                    
                    // Step 2: Model
                    setupCard(
                        step: 2,
                        title: "Select a Model",
                        subtitle: session.model.isEmpty ? "No model selected" : session.model,
                        isComplete: !session.model.isEmpty,
                        icon: "cpu"
                    ) {
                        modelPicker
                    }
                }
                .frame(maxWidth: 400)
                
                // Ready indicator
                if session.isConfigured {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Ready to chat!")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.green)
                        }
                        
                        Text("Start typing in the message field below")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .background(
            colorScheme == .dark
                ? Color(white: 0.08)
                : Color(white: 0.96)
        )
        .onAppear {
            // Only fetch models after user has explicitly chosen a provider
            // This ensures no network requests are made without user consent
            if session.hasExplicitlyConfiguredProvider && session.availableModels.isEmpty {
                Task { await session.fetchAvailableModels() }
            }
        }
    }
    
    private var providerIcon: String {
        if case .cloud(let provider) = session.providerType {
            return provider.icon
        }
        return "cube.fill"
    }
    
    @ViewBuilder
    private func setupCard<Content: View>(
        step: Int,
        title: String,
        subtitle: String,
        isComplete: Bool,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.green : Color.orange)
                        .frame(width: 24, height: 24)
                    
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isComplete ? Color.green.opacity(0.3) : Color.orange.opacity(0.3),
                    lineWidth: 1
                )
        )
    }
    
    private func providerDescription(for provider: CloudProvider) -> String {
        switch provider {
        case .openai: return "GPT-4, GPT-5, o-series models"
        case .anthropic: return "Claude 3.5, Claude 4 models"
        case .google: return "Gemini Pro, Gemini Flash models"
        }
    }
    
    private func providerColor(for provider: CloudProvider) -> Color {
        switch provider {
        case .openai: return .green
        case .anthropic: return .orange
        case .google: return .blue
        }
    }
    
    @ViewBuilder
    private var providerPicker: some View {
        VStack(spacing: 8) {
            // Cloud providers section
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud Providers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                
                ForEach(CloudProvider.allCases, id: \.rawValue) { provider in
                    let isAvailable = CloudAPIKeyManager.shared.hasAPIKey(for: provider)
                    providerRow(
                        name: provider.rawValue,
                        icon: provider.icon,
                        description: providerDescription(for: provider),
                        isSelected: session.hasExplicitlyConfiguredProvider && session.providerType == .cloud(provider),
                        isAvailable: isAvailable,
                        color: providerColor(for: provider)
                    ) {
                        session.switchToCloudProvider(provider)
                    }
                }
            }
            
            // Local providers section
            VStack(alignment: .leading, spacing: 6) {
                Text("Local Providers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                
                providerRow(
                    name: "Ollama",
                    icon: "cube.fill",
                    description: "Run models locally with Ollama",
                    isSelected: session.hasExplicitlyConfiguredProvider && session.providerType == .local(.ollama),
                    isAvailable: LocalProviderAvailabilityManager.shared.isAvailable(for: .ollama),
                    unavailableReason: "Not Running",
                    color: .blue
                ) {
                    session.switchToLocalProvider(.ollama)
                }
                
                providerRow(
                    name: "LM Studio",
                    icon: "sparkles",
                    description: "Local models via LM Studio",
                    isSelected: session.hasExplicitlyConfiguredProvider && session.providerType == .local(.lmStudio),
                    isAvailable: LocalProviderAvailabilityManager.shared.isAvailable(for: .lmStudio),
                    unavailableReason: "Not Running",
                    color: .purple
                ) {
                    session.switchToLocalProvider(.lmStudio)
                }
                
                providerRow(
                    name: "vLLM",
                    icon: "bolt.fill",
                    description: "High-performance inference server",
                    isSelected: session.hasExplicitlyConfiguredProvider && session.providerType == .local(.vllm),
                    isAvailable: LocalProviderAvailabilityManager.shared.isAvailable(for: .vllm),
                    unavailableReason: "Not Running",
                    color: .orange
                ) {
                    session.switchToLocalProvider(.vllm)
                }
            }
        }
    }
    
    @ViewBuilder
    private func providerRow(
        name: String,
        icon: String,
        description: String,
        isSelected: Bool,
        isAvailable: Bool = true,
        unavailableReason: String = "No API Key",
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Provider icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? color : (isAvailable ? color.opacity(0.15) : Color.gray.opacity(0.1)))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .white : (isAvailable ? color : .gray.opacity(0.4)))
                }
                
                // Provider info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isAvailable ? .primary : .secondary.opacity(0.6))
                        
                        if !isAvailable {
                            Text(unavailableReason)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.15))
                                )
                        }
                    }
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(isAvailable ? .secondary : .secondary.opacity(0.5))
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(color)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1.0 : 0.7)
    }
    
    @ViewBuilder
    private var modelPicker: some View {
        if !session.hasExplicitlyConfiguredProvider {
            // Show prompt to select provider first
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .foregroundColor(.secondary)
                Text("Select a provider above first")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if session.availableModels.isEmpty {
            if let error = session.modelFetchError {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("Retry") {
                        Task { await session.fetchAvailableModels(forceRefresh: true) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading models...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(session.availableModels, id: \.self) { modelId in
                        let isSelected = modelId == session.model
                        let displayName = CuratedModels.find(id: modelId)?.displayName ?? modelId
                        let isReasoning = CuratedModels.supportsReasoning(modelId: modelId)
                        
                        Button(action: {
                            session.model = modelId
                            session.updateContextLimit()
                            session.persistSettings()
                        }) {
                            HStack(spacing: 10) {
                                // Model icon - brain for reasoning, cpu for others
                                if isReasoning {
                                    ReasoningBrainIcon(size: .small, showGlow: isSelected)
                                } else {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 14))
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                }
                                
                                // Model name
                                Text(displayName)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                // Reasoning badge
                                if isReasoning {
                                    Text("Thinking")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.purple)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(Color.purple.opacity(0.15))
                                        )
                                }
                                
                                // Selection indicator
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 250) // Limit height to prevent overflow
        }
    }
}
