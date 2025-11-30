import SwiftUI

/// Container view that manages multiple chat tabs
struct ChatContainerView: View {
    @EnvironmentObject var tabsManager: ChatTabsManager
    let ptyModel: PTYModel
    
    // Command approval state
    @State private var pendingApproval: PendingCommandApproval? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Main Chat header with provider/model info
            HStack(spacing: 8) {
                Text("Chat")
                    .font(.headline)
                
                if let session = tabsManager.selectedSession {
                    // Create a view that observes the session
                    SessionHeaderView(session: session)
                    
                    // Agent toggle or cancel button
                    if session.isAgentRunning {
                        // Show cancel button when agent is running
                        Button(action: { session.cancelAgent() }) {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                                Text("Cancel")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.15))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            )
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel agent execution")
                    } else {
                        // Show agent toggle when not running
                        Toggle(isOn: Binding(
                            get: { session.agentModeEnabled },
                            set: { session.agentModeEnabled = $0; session.persistSettings() }
                        )) {
                            Text("Agent").font(.caption2)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("When enabled, the assistant can run terminal commands automatically.")
                    }
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial.opacity(0.5))
            
            Divider()
            
            // Selected chat tab content (without redundant header)
            if let selectedSession = tabsManager.selectedSession,
               let index = tabsManager.sessions.firstIndex(where: { $0.id == selectedSession.id }) {
                ChatTabContentView(
                    session: selectedSession,
                    tabIndex: index,
                    ptyModel: ptyModel
                )
                .id(selectedSession.id) // Force view recreation when session changes
                .onReceive(NotificationCenter.default.publisher(for: .TermAIExecuteCommand)) { note in
                    // When a command is executed, schedule a capture and publish a finish event for the selected session
                    guard let cmd = note.userInfo?["command"] as? String else { return }
                    // Capture after a small delay to accumulate output
                    // Wait longer to ensure markers are processed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        // Grab last output chunk and exit code from the terminal
                        let output = ptyModel.lastOutputChunk
                        let rc = ptyModel.lastExitCode
                        let cwd = ptyModel.currentWorkingDirectory
                        // Route the finish to the same session id that issued the command (if provided)
                        let sid = (note.userInfo?["sessionId"] as? UUID) ?? selectedSession.id
                        NotificationCenter.default.post(name: .TermAICommandFinished, object: nil, userInfo: [
                            "sessionId": sid,
                            "command": cmd,
                            "output": output,
                            "cwd": cwd,
                            "exitCode": rc
                        ])
                        // Clear last-sent marker after capture
                        ptyModel.lastSentCommandForCapture = nil
                        // Disable capture state to stop heavy updates until next command
                        ptyModel.captureActive = false
                    }
                }
            } else {
                Color.clear
            }
        }
        .background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .TermAICommandPendingApproval)) { note in
            guard let sessionId = note.userInfo?["sessionId"] as? UUID,
                  let approvalId = note.userInfo?["approvalId"] as? UUID,
                  let command = note.userInfo?["command"] as? String else { return }
            
            // Only show if this is for the selected session
            if sessionId == tabsManager.selectedSessionId {
                pendingApproval = PendingCommandApproval(
                    approvalId: approvalId,
                    sessionId: sessionId,
                    command: command
                )
            }
        }
        .sheet(item: $pendingApproval) { approval in
            CommandApprovalSheet(
                approval: approval,
                onApprove: { editedCommand in
                    NotificationCenter.default.post(
                        name: .TermAICommandApprovalResponse,
                        object: nil,
                        userInfo: [
                            "approvalId": approval.approvalId,
                            "approved": true,
                            "command": editedCommand
                        ]
                    )
                    pendingApproval = nil
                },
                onReject: {
                    NotificationCenter.default.post(
                        name: .TermAICommandApprovalResponse,
                        object: nil,
                        userInfo: [
                            "approvalId": approval.approvalId,
                            "approved": false
                        ]
                    )
                    pendingApproval = nil
                }
            )
        }
    }
}

// MARK: - Pending Command Approval Model
struct PendingCommandApproval: Identifiable {
    let id = UUID()
    let approvalId: UUID
    let sessionId: UUID
    let command: String
}

// MARK: - Command Approval Sheet
struct CommandApprovalSheet: View {
    let approval: PendingCommandApproval
    let onApprove: (String) -> Void
    let onReject: () -> Void
    
    @State private var editedCommand: String = ""
    @State private var isEditing: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command Approval Required")
                        .font(.headline)
                    Text("The agent wants to execute the following command")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(20)
            .background(Color.orange.opacity(0.1))
            
            Divider()
            
            // Command display/edit area
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Command")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: { isEditing.toggle() }) {
                        Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                if isEditing {
                    TextEditor(text: $editedCommand)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                        )
                        .frame(minHeight: 80, maxHeight: 200)
                } else {
                    ScrollView {
                        Text(editedCommand)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
                    )
                    .frame(minHeight: 60, maxHeight: 200)
                }
                
                // Warning message for potentially dangerous commands
                if isPotentiallyDangerous(editedCommand) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("This command may modify or delete files. Please review carefully.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                }
            }
            .padding(20)
            
            Divider()
            
            // Action buttons
            HStack(spacing: 12) {
                Button(action: onReject) {
                    Text("Reject")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
                .foregroundColor(.red)
                
                Button(action: { onApprove(editedCommand) }) {
                    Text("Approve & Run")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.green)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(width: 500)
        .background(colorScheme == .dark ? Color(white: 0.1) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            editedCommand = approval.command
        }
    }
    
    private func isPotentiallyDangerous(_ command: String) -> Bool {
        let dangerous = ["rm ", "rm\t", "rmdir", "mv ", "mv\t", "> ", ">> ", 
                         "sudo ", "chmod ", "chown ", "dd ", "mkfs", "format"]
        let lower = command.lowercased()
        return dangerous.contains { lower.contains($0) }
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

// Separate view that observes the session for real-time updates
private struct SessionHeaderView: View {
    @ObservedObject var session: ChatSession
    
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
            }
        }
        return .primary
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Provider selector - clickable chip
            Menu {
                // Cloud Providers Section
                if !availableCloudProviders.isEmpty {
                    Text("Cloud Providers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(availableCloudProviders, id: \.rawValue) { provider in
                        Button(action: {
                            session.switchToCloudProvider(provider)
                        }) {
                            HStack {
                                Image(systemName: provider.icon)
                                Text(provider.rawValue)
                                if session.providerType == .cloud(provider) {
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
                
                Button(action: {
                    session.switchToLocalProvider(.ollama)
                }) {
                    HStack {
                        Image(systemName: "cube.fill")
                        Text("Ollama")
                        if session.providerType == .local(.ollama) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    session.switchToLocalProvider(.lmStudio)
                }) {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("LM Studio")
                        if session.providerType == .local(.lmStudio) {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button(action: {
                    session.switchToLocalProvider(.vllm)
                }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("vLLM")
                        if session.providerType == .local(.vllm) {
                            Image(systemName: "checkmark")
                        }
                    }
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
                        Button(action: {
                            session.model = modelId
                            session.persistSettings()
                        }) {
                            HStack {
                                Text(displayName(for: modelId))
                                
                                if CuratedModels.supportsReasoning(modelId: modelId) {
                                    Image(systemName: "brain")
                                        .font(.caption2)
                                        .foregroundColor(.purple)
                                }
                                
                                if modelId == session.model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    
                    if !session.providerType.isCloud {
                        Divider()
                        
                        Button("Refresh Models") {
                            Task {
                                await session.fetchAvailableModels()
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
                        Image(systemName: "cpu")
                            .font(.caption2)
                        Text(displayName(for: session.model))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        if session.currentModelSupportsReasoning {
                            Image(systemName: "brain")
                                .font(.system(size: 9))
                                .foregroundColor(.purple)
                        }
                    }
                    .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.ultraThinMaterial))
                }
            }
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
