import SwiftUI

/// Container view that manages multiple chat tabs
struct ChatContainerView: View {
    @EnvironmentObject var tabsManager: ChatTabsManager
    let ptyModel: PTYModel
    @State private var showSystemPrompt: Bool = false
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
                }
                
                Spacer()
                
                Button(action: { showSystemPrompt.toggle() }) {
                    Label("System Prompt", systemImage: showSystemPrompt ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            
            // System prompt editor (when expanded)
            if showSystemPrompt, let session = tabsManager.selectedSession {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: Binding(
                        get: { session.systemPrompt },
                        set: { newValue in
                            session.systemPrompt = newValue
                            session.persistSettings()
                        }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            
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
            // Provider chip
            Label(session.providerName, systemImage: "network")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.gray.opacity(0.15)))
            
            // Model chip
            if session.model.isEmpty {
                Label("No model selected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            } else {
                Label(session.model, systemImage: "cpu")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
            }
        }
    }
}
