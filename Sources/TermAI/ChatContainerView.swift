import SwiftUI

/// Container view that manages multiple chat tabs
struct ChatContainerView: View {
    @EnvironmentObject var tabsManager: ChatTabsManager
    let ptyModel: PTYModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Main Chat header with provider/model info
            HStack(spacing: 8) {
                Text("Chat")
                    .font(.headline)
                
                if let session = tabsManager.selectedSession {
                    // Create a view that observes the session
                    SessionHeaderView(session: session)
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
    
    var body: some View {
        HStack(spacing: 8) {
            // Provider selector - clickable chip
            Menu {
                Button(action: {
                    session.providerName = "Ollama"
                    session.apiBaseURL = ChatSession.LocalProvider.ollama.defaultBaseURL
                    session.persistSettings()
                    Task { await session.fetchAvailableModels() }
                }) {
                    HStack {
                        Text("Ollama (Local)")
                        if session.providerName == "Ollama" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Button(action: {
                    session.providerName = "LM Studio"
                    session.apiBaseURL = ChatSession.LocalProvider.lmStudio.defaultBaseURL
                    session.persistSettings()
                    Task { await session.fetchAvailableModels() }
                }) {
                    HStack {
                        Text("LM Studio")
                        if session.providerName == "LM Studio" {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button(action: {
                    session.providerName = "vLLM"
                    session.apiBaseURL = ChatSession.LocalProvider.vllm.defaultBaseURL
                    session.persistSettings()
                    Task { await session.fetchAvailableModels() }
                }) {
                    HStack {
                        Text("vLLM")
                        if session.providerName == "vLLM" {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Label(session.providerName, systemImage: "network")
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 72, alignment: .leading)
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
                    ForEach(session.availableModels, id: \.self) { model in
                        Button(action: {
                            session.model = model
                            session.persistSettings()
                        }) {
                            HStack {
                                Text(model)
                                if model == session.model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button("Refresh Models") {
                        Task {
                            await session.fetchAvailableModels()
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
                        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                } else {
                    Label(session.model, systemImage: "cpu")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
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
}
