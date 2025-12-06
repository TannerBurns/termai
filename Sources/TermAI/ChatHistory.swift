import Foundation
import SwiftUI

// MARK: - Chat History Entry

struct ChatHistoryEntry: Identifiable, Codable {
    let id: UUID
    let title: String
    let savedDate: Date
    let messagePreview: String
    let messageCount: Int
    
    init(id: UUID, title: String, savedDate: Date = Date(), messagePreview: String, messageCount: Int) {
        self.id = id
        self.title = title
        self.savedDate = savedDate
        self.messagePreview = messagePreview
        self.messageCount = messageCount
    }
}

// MARK: - Chat History Manager

@MainActor
final class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()
    
    private static let maxEntries = 10
    private static let historyFileName = "chat-history.json"
    
    @Published private(set) var entries: [ChatHistoryEntry] = []
    
    private init() {
        loadEntries()
    }
    
    // MARK: - Public Methods
    
    /// Archive a chat session to history
    func addEntry(from session: ChatSession) {
        // Only archive sessions that have actual messages
        let userMessages = session.messages.filter { $0.role == "user" }
        guard !userMessages.isEmpty else { return }
        
        // Get preview from first user message
        let preview = userMessages.first?.content.prefix(100) ?? ""
        let title = session.sessionTitle.isEmpty ? "Untitled Chat" : session.sessionTitle
        
        let entry = ChatHistoryEntry(
            id: session.id,
            title: title,
            messagePreview: String(preview),
            messageCount: session.messages.count
        )
        
        // Remove existing entry with same ID if present (updating)
        entries.removeAll { $0.id == entry.id }
        
        // Add new entry at the beginning
        entries.insert(entry, at: 0)
        
        // Keep only the last N entries
        if entries.count > Self.maxEntries {
            // Get entries to remove
            let entriesToRemove = Array(entries.suffix(from: Self.maxEntries))
            entries = Array(entries.prefix(Self.maxEntries))
            
            // Clean up persisted files for removed entries
            for removed in entriesToRemove {
                cleanupSessionFiles(for: removed.id)
            }
        }
        
        saveEntries()
    }
    
    /// Remove an entry from history (keeps session files for potential restore)
    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        saveEntries()
    }
    
    /// Remove an entry and delete its session files permanently
    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        cleanupSessionFiles(for: id)
        saveEntries()
    }
    
    /// Clear all history entries and delete their session files permanently
    func clearAllEntries() {
        // Clean up all session files first
        for entry in entries {
            cleanupSessionFiles(for: entry.id)
        }
        entries.removeAll()
        saveEntries()
    }
    
    /// Check if a session ID exists in history
    func hasEntry(id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }
    
    // MARK: - Persistence
    
    private func loadEntries() {
        if let loaded = try? PersistenceService.loadJSON([ChatHistoryEntry].self, from: Self.historyFileName) {
            entries = loaded
        }
    }
    
    private func saveEntries() {
        try? PersistenceService.saveJSON(entries, to: Self.historyFileName)
    }
    
    /// Clean up session files when permanently removing from history
    private func cleanupSessionFiles(for sessionId: UUID) {
        guard let dir = try? PersistenceService.appSupportDirectory() else { return }
        
        let messagesFile = dir.appendingPathComponent("chat-session-\(sessionId.uuidString).json")
        let settingsFile = dir.appendingPathComponent("session-settings-\(sessionId.uuidString).json")
        let checkpointsFile = dir.appendingPathComponent("chat-checkpoints-\(sessionId.uuidString).json")
        
        try? FileManager.default.removeItem(at: messagesFile)
        try? FileManager.default.removeItem(at: settingsFile)
        try? FileManager.default.removeItem(at: checkpointsFile)
    }
}

