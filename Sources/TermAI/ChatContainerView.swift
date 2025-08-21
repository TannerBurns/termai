import SwiftUI

/// Container view that manages multiple chat tabs
struct ChatContainerView: View {
    @EnvironmentObject var tabsManager: ChatTabsManager
    let ptyModel: PTYModel

    @State private var refreshID = UUID() // Force refresh when model changes
    
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
            .padding(8)
            

            
            // Tab bar below header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(tabsManager.sessions.enumerated()), id: \.element.id) { index, session in
                        let isSelected = session.id == tabsManager.selectedSessionId
                        
                        HStack(spacing: 4) {
                            Button(action: {
                                tabsManager.selectSession(id: session.id)
                            }) {
                                Text(session.sessionTitle.isEmpty ? "Chat \(index + 1)" : session.sessionTitle)
                                    .lineLimit(1)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                tabsManager.closeSession(at: index)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Close Chat")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15)
                            )
                        )
                    }
                    
                    // New tab button
                    Button(action: {
                        _ = tabsManager.createNewSession(copySettingsFrom: tabsManager.selectedSession)
                    }) {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("New Chat Tab")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(height: 32)
            
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
                    }
                }
            } else {
                Color.clear
            }
        }
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
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
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
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                }
            }
            .controlSize(.mini)
            .menuStyle(.borderlessButton)
            .help("Click to change model")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
