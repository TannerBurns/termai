import Foundation
import SwiftUI

/// Manages multiple chat tabs with complete isolation
@MainActor
final class ChatTabsManager: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionId: UUID?
    
    /// Optional tab ID for scoped persistence (when used within an AppTab)
    private let tabId: UUID?
    
    init(tabId: UUID? = nil) {
        self.tabId = tabId
        // Try to restore previous sessions
        loadSessions()
        
        // If no sessions were restored, create a new one
        if sessions.isEmpty {
            let firstSession = ChatSession()
            sessions = [firstSession]
            selectedSessionId = firstSession.id
            saveSessions()
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
        
        // If this is the only session, create a new one instead of removing
        if sessions.count == 1 {
            sessions[0].clearChat()
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
        try? PersistenceService.saveJSON(sessionData, to: manifestFileName)
        
        // Also make sure each session saves its settings
        for session in sessions {
            session.persistSettings()
            session.persistMessages()
        }
    }
    
    private func loadSessions() {
        guard let sessionData = try? PersistenceService.loadJSON(SessionsData.self, from: manifestFileName) else {
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
    }
}

// MARK: - Supporting Types
private struct SessionsData: Codable {
    let sessionIds: [UUID]
    let selectedSessionId: UUID?
}
