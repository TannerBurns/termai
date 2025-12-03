import Foundation
import SwiftUI

/// Manages multiple chat tabs with complete isolation
@MainActor
final class ChatTabsManager: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionId: UUID?
    @Published private(set) var isLoading: Bool = true
    
    /// Optional tab ID for scoped persistence (when used within an AppTab)
    private let tabId: UUID?
    
    init(tabId: UUID? = nil) {
        self.tabId = tabId
        
        // Create a default session immediately (will be replaced if restoration succeeds)
        let firstSession = ChatSession()
        sessions = [firstSession]
        selectedSessionId = firstSession.id
        
        // Load saved sessions asynchronously
        Task { @MainActor in
            await loadSessionsAsync()
        }
    }
    
    var selectedSession: ChatSession? {
        sessions.first { $0.id == selectedSessionId }
    }
    
    var selectedIndex: Int {
        sessions.firstIndex { $0.id == selectedSessionId } ?? 0
    }
    
    func createNewSession(copySettingsFrom source: ChatSession? = nil) -> ChatSession {
        let newSession = ChatSession()
        
        // Only copy settings, never messages or pending context
        if let source = source {
            newSession.apiBaseURL = source.apiBaseURL
            newSession.apiKey = source.apiKey
            newSession.model = source.model
            newSession.providerName = source.providerName
            newSession.providerType = source.providerType
            // systemPrompt is now automatically generated and cannot be copied
        }
        
        sessions.append(newSession)
        selectedSessionId = newSession.id
        saveSessions() // Save when adding new session
        return newSession
    }
    
    func closeSession(at index: Int) {
        guard index >= 0 && index < sessions.count else { return }
        
        let sessionToRemove = sessions[index]
        sessionToRemove.cancelStreaming()
        
        // Archive to history if the session has messages
        let hasMessages = !sessionToRemove.messages.filter { $0.role == "user" }.isEmpty
        if hasMessages {
            // Make sure session data is saved immediately before archiving (bypass debounce)
            sessionToRemove.persistMessagesImmediately()
            sessionToRemove.persistSettings()
            ChatHistoryManager.shared.addEntry(from: sessionToRemove)
        }
        
        // If this is the only session, replace it with a new one (don't reuse ID)
        if sessions.count == 1 {
            // Create a new session with settings from the old one
            let newSession = ChatSession()
            newSession.apiBaseURL = sessionToRemove.apiBaseURL
            newSession.apiKey = sessionToRemove.apiKey
            newSession.model = sessionToRemove.model
            newSession.providerName = sessionToRemove.providerName
            newSession.providerType = sessionToRemove.providerType
            newSession.persistSettings()
            
            sessions = [newSession]
            selectedSessionId = newSession.id
            saveSessions()
            return
        }
        
        sessions.remove(at: index)
        
        // Update selection if needed
        if sessionToRemove.id == selectedSessionId {
            let newIndex = min(index, sessions.count - 1)
            selectedSessionId = sessions[newIndex].id
        }
        
        saveSessions() // Save when removing session
    }
    
    func closeSession(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            closeSession(at: index)
        }
    }
    
    func selectSession(id: UUID) {
        if sessions.contains(where: { $0.id == id }) {
            selectedSessionId = id
            saveSessions() // Save selection change
        }
    }
    
    // MARK: - History Restoration
    
    /// Restore a session from chat history as a new tab
    func restoreFromHistory(sessionId: UUID) -> ChatSession? {
        // Check if session already exists in active sessions
        if sessions.contains(where: { $0.id == sessionId }) {
            // Just select it instead
            selectedSessionId = sessionId
            saveSessions()
            return sessions.first { $0.id == sessionId }
        }
        
        // Create a new session with the archived ID
        let restoredSession = ChatSession(restoredId: sessionId)
        restoredSession.loadSettings()
        restoredSession.loadMessages()
        
        // Only restore if it has messages
        guard !restoredSession.messages.isEmpty else {
            return nil
        }
        
        // Add to sessions and select it
        sessions.append(restoredSession)
        selectedSessionId = restoredSession.id
        saveSessions()
        
        // Remove from history since it's now active
        ChatHistoryManager.shared.removeEntry(id: sessionId)
        
        return restoredSession
    }
    
    // MARK: - Persistence
    
    private var manifestFileName: String {
        if let tabId = tabId {
            return "sessions-manifest-\(tabId.uuidString).json"
        }
        return "sessions-manifest.json"
    }
    
    func saveSessions() {
        let sessionData = SessionsData(
            sessionIds: sessions.map { $0.id },
            selectedSessionId: selectedSessionId
        )
        // Use background save for manifest to avoid blocking main thread
        PersistenceService.saveJSONInBackground(sessionData, to: manifestFileName)
        
        // Also make sure each session saves its settings
        // Use immediate persist to ensure data is written before app quit
        for session in sessions {
            session.persistSettings()
            session.persistMessagesImmediately()
        }
    }
    
    /// Save sessions synchronously - for app quit scenarios where we need to ensure data is written
    func saveSessionsImmediately() {
        let sessionData = SessionsData(
            sessionIds: sessions.map { $0.id },
            selectedSessionId: selectedSessionId
        )
        try? PersistenceService.saveJSON(sessionData, to: manifestFileName)
        
        for session in sessions {
            session.persistSettings()
            session.persistMessagesImmediately()
        }
    }
    
    /// Load sessions asynchronously from disk
    private func loadSessionsAsync() async {
        // Load manifest on background thread
        let sessionData: SessionsData? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = try? PersistenceService.loadJSON(SessionsData.self, from: manifestFileName)
                continuation.resume(returning: result)
            }
        }
        
        guard let sessionData = sessionData, !sessionData.sessionIds.isEmpty else {
            isLoading = false
            return
        }
        
        // Restore each session
        var restoredSessions: [ChatSession] = []
        for sessionId in sessionData.sessionIds {
            let session = ChatSession(restoredId: sessionId)
            session.loadSettings()
            session.loadMessages()
            restoredSessions.append(session)
        }
        
        if !restoredSessions.isEmpty {
            sessions = restoredSessions
            selectedSessionId = sessionData.selectedSessionId
        }
        
        isLoading = false
    }
}

// MARK: - Supporting Types
private struct SessionsData: Codable {
    let sessionIds: [UUID]
    let selectedSessionId: UUID?
}
