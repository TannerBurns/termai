import Foundation
import SwiftUI

@MainActor
final class AppTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    /// Each app tab owns its own terminal instance
    let ptyModel: PTYModel
    /// Each app tab has its own chat tabs manager for multiple chat sessions
    let chatTabsManager: ChatTabsManager
    
    init(id: UUID = UUID(), title: String = "Tab", ptyModel: PTYModel = PTYModel(), chatTabsManager: ChatTabsManager? = nil) {
        self.id = id
        self.title = title
        self.ptyModel = ptyModel
        // Create a new ChatTabsManager or use the provided one (for restoration)
        self.chatTabsManager = chatTabsManager ?? ChatTabsManager(tabId: id)
    }
    
    var selectedChatSession: ChatSession? {
        chatTabsManager.selectedSession
    }
    
    func cleanup() {
        // Cancel any streaming chats
        chatTabsManager.sessions.forEach { $0.cancelStreaming() }
        // Save sessions before cleanup
        chatTabsManager.saveSessions()
        // Terminate the terminal process
        ptyModel.terminateProcess()
    }
}

@MainActor
final class TabsStore: ObservableObject {
    @Published var tabs: [AppTab]
    @Published var selectedId: UUID
    
    init() {
        // Try to restore previous tabs
        if let manifest = try? PersistenceService.loadJSON(TabsManifest.self, from: "tabs-manifest.json"),
           !manifest.tabIds.isEmpty {
            var restoredTabs: [AppTab] = []
            for tabId in manifest.tabIds {
                // Create a ChatTabsManager that loads its sessions for this tab
                let chatManager = ChatTabsManager(tabId: tabId)
                let tab = AppTab(id: tabId, title: manifest.tabTitles[tabId.uuidString] ?? "Tab", chatTabsManager: chatManager)
                restoredTabs.append(tab)
            }
            self.tabs = restoredTabs
            self.selectedId = manifest.selectedTabId ?? restoredTabs.first!.id
        } else {
            // Create first tab
            let first = AppTab(title: "Tab 1")
            self.tabs = [first]
            self.selectedId = first.id
        }
    }
    
    var selected: AppTab? { tabs.first(where: { $0.id == selectedId }) }
    
    var selectedIndex: Int {
        tabs.firstIndex(where: { $0.id == selectedId }) ?? 0
    }
    
    func selectTab(id: UUID) {
        if tabs.contains(where: { $0.id == id }) {
            selectedId = id
            saveManifest()
        }
    }
    
    func addTab(copySettingsFrom current: AppTab? = nil) {
        let newTab = AppTab(title: "Tab \(tabs.count + 1)")
        
        // Copy chat settings from current tab's selected session if available
        if let currentSession = current?.selectedChatSession {
            if let newSession = newTab.chatTabsManager.sessions.first {
                newSession.apiBaseURL = currentSession.apiBaseURL
                newSession.apiKey = currentSession.apiKey
                newSession.model = currentSession.model
                newSession.providerName = currentSession.providerName
                newSession.persistSettings()
            }
        }
        
        tabs.append(newTab)
        selectedId = newTab.id
        saveManifest()
    }
    
    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        
        // Cleanup the tab being closed
        tabs[idx].cleanup()
        tabs.remove(at: idx)
        
        if tabs.isEmpty {
            // Create a new tab if we closed the last one
            addTab(copySettingsFrom: nil)
        } else {
            // Reindex remaining tab titles
            reindexTabTitles()
            
            if selectedId == id {
                // Select adjacent tab
                selectedId = tabs[min(idx, tabs.count - 1)].id
            }
        }
        
        saveManifest()
    }
    
    /// Reindex tab titles after deletion to maintain sequential numbering
    private func reindexTabTitles() {
        for (index, tab) in tabs.enumerated() {
            // Only update tabs with default "Tab N" naming pattern
            if tab.title.hasPrefix("Tab ") {
                tab.title = "Tab \(index + 1)"
            }
        }
    }
    
    func closeCurrentTab() {
        closeTab(id: selectedId)
    }
    
    // Select next tab (for Cmd+Shift+])
    func selectNextTab() {
        guard tabs.count > 1 else { return }
        let currentIdx = selectedIndex
        let nextIdx = (currentIdx + 1) % tabs.count
        selectedId = tabs[nextIdx].id
    }
    
    // Select previous tab (for Cmd+Shift+[)
    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        let currentIdx = selectedIndex
        let prevIdx = currentIdx > 0 ? currentIdx - 1 : tabs.count - 1
        selectedId = tabs[prevIdx].id
    }
    
    // Select tab by number (1-indexed, for Cmd+1-9)
    func selectTabByNumber(_ num: Int) {
        let index = num - 1  // Convert to 0-indexed
        guard index >= 0 && index < tabs.count else { return }
        selectedId = tabs[index].id
    }
    
    // MARK: - Persistence
    func saveManifest() {
        var titles: [String: String] = [:]
        for tab in tabs {
            titles[tab.id.uuidString] = tab.title
        }
        let manifest = TabsManifest(
            tabIds: tabs.map { $0.id },
            selectedTabId: selectedId,
            tabTitles: titles
        )
        try? PersistenceService.saveJSON(manifest, to: "tabs-manifest.json")
        
        // Also save each tab's chat sessions
        for tab in tabs {
            tab.chatTabsManager.saveSessions()
        }
    }
    
    func saveAllSessions() {
        saveManifest()
    }
}

// MARK: - Supporting Types
private struct TabsManifest: Codable {
    let tabIds: [UUID]
    let selectedTabId: UUID?
    let tabTitles: [String: String]
}
