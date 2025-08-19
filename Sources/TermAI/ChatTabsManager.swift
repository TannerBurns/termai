import Foundation
import SwiftUI

/// Manages multiple chat tabs with complete isolation
@MainActor
final class ChatTabsManager: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionId: UUID?
    
    init() {
        // Start with one empty session
        let firstSession = ChatSession()
        sessions = [firstSession]
        selectedSessionId = firstSession.id
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
            newSession.systemPrompt = source.systemPrompt
        }
        
        sessions.append(newSession)
        selectedSessionId = newSession.id
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
    }
    
    func closeSession(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            closeSession(at: index)
        }
    }
    
    func selectSession(id: UUID) {
        if sessions.contains(where: { $0.id == id }) {
            selectedSessionId = id
        }
    }
}
