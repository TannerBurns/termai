import Foundation
import SwiftUI
import Combine

@MainActor
final class AppTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    /// Each app tab owns its own terminal instance
    let ptyModel: PTYModel
    /// Each app tab has its own chat tabs manager for multiple chat sessions
    let chatTabsManager: ChatTabsManager
    /// Each app tab has its own suggestion service to avoid cross-tab state leakage
    let suggestionService: TerminalSuggestionService
    /// File tree model synced to terminal CWD
    let fileTreeModel: FileTreeModel
    /// Editor tabs manager for terminal + file tabs
    let editorTabsManager: EditorTabsManager
    
    /// Tracks whether any agent was running in the previous check (for detecting completion)
    private var wasAgentRunning: Bool = false
    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    init(id: UUID = UUID(), title: String = "Tab", ptyModel: PTYModel = PTYModel(), chatTabsManager: ChatTabsManager? = nil, initialDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.ptyModel = ptyModel
        
        // Set initial directory if provided (for Services integration)
        if let dir = initialDirectory {
            ptyModel.initialDirectory = dir
        }
        
        // Create a new ChatTabsManager or use the provided one (for restoration)
        self.chatTabsManager = chatTabsManager ?? ChatTabsManager(tabId: id)
        // Create a per-tab suggestion service
        self.suggestionService = TerminalSuggestionService()
        // Create file tree model and editor tabs manager
        self.fileTreeModel = FileTreeModel()
        self.editorTabsManager = EditorTabsManager()
        
        // Wire up the agent running check - pause suggestions while chat agent is active
        self.suggestionService.checkAgentRunning = { [weak self] in
            guard let self = self else { return false }
            return self.chatTabsManager.sessions.contains { $0.isAgentRunning }
        }
        
        // Observe agent execution phase changes to resume suggestions when agent completes
        setupAgentCompletionObserver()
        
        // Sync file tree with terminal CWD
        setupFileTreeSync()
    }
    
    /// Sets up observation of terminal CWD to sync file tree
    private func setupFileTreeSync() {
        ptyModel.$currentWorkingDirectory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cwd in
                guard let self = self, !cwd.isEmpty else { return }
                self.fileTreeModel.updateRoot(to: cwd)
            }
            .store(in: &cancellables)
    }
    
    /// Sets up observation of chat sessions to detect when agent finishes
    private func setupAgentCompletionObserver() {
        // Observe the sessions array for changes
        chatTabsManager.$sessions
            .sink { [weak self] sessions in
                self?.observeSessionAgentStates(sessions)
            }
            .store(in: &cancellables)
        
        // Initial observation of existing sessions
        observeSessionAgentStates(chatTabsManager.sessions)
    }
    
    /// Observe agent execution phase for each session
    private func observeSessionAgentStates(_ sessions: [ChatSession]) {
        // Subscribe to each session's agent execution phase
        for session in sessions {
            session.$agentExecutionPhase
                .receive(on: DispatchQueue.main)
                .sink { [weak self] phase in
                    self?.checkAgentCompletion()
                }
                .store(in: &cancellables)
        }
    }
    
    /// Check if agent just completed and resume suggestions if so
    private func checkAgentCompletion() {
        let isAgentRunning = chatTabsManager.sessions.contains { $0.isAgentRunning }
        
        // Agent just finished (was running, now not running)
        if wasAgentRunning && !isAgentRunning {
            suggestionService.resumeSuggestionsAfterAgent()
        }
        
        wasAgentRunning = isAgentRunning
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
    @Published private(set) var isLoading: Bool = true
    
    /// Standard initializer - loads saved tabs or creates default
    init() {
        // Start with a temporary tab - will be replaced by async load
        // Note: If launched via Services, the pending directory is picked up
        // in SwiftTermView.makeNSView when the terminal is created
        let first = AppTab(title: "Tab 1")
        self.tabs = [first]
        self.selectedId = first.id
        
        // Load saved tabs asynchronously to avoid blocking main thread
        Task { @MainActor in
            await loadTabsAsync()
        }
    }
    
    /// Initializer for new windows with a specific starting directory
    /// When initialDirectory is provided, skips loading saved tabs and creates a fresh window
    init(initialDirectory: String?) {
        if let directory = initialDirectory {
            // Create a fresh tab at the specified directory (for dock menu "Open Recent")
            let first = AppTab(title: "Tab 1", initialDirectory: directory)
            self.tabs = [first]
            self.selectedId = first.id
            self.isLoading = false
            
            // Record to recent projects
            RecentProjectsStore.shared.addProject(path: directory)
        } else {
            // Standard initialization - load saved tabs
            let first = AppTab(title: "Tab 1")
            self.tabs = [first]
            self.selectedId = first.id
            
            Task { @MainActor in
                await loadTabsAsync()
            }
        }
    }
    
    /// Load saved tabs from disk asynchronously
    private func loadTabsAsync() async {
        // Load manifest on background thread
        let manifest: TabsManifest? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? PersistenceService.loadJSON(TabsManifest.self, from: "tabs-manifest.json")
                continuation.resume(returning: result)
            }
        }
        
        // Process on main actor
        if let manifest = manifest, !manifest.tabIds.isEmpty {
            // Clean up the temporary first tab
            if tabs.count == 1 && tabs.first?.chatTabsManager.sessions.isEmpty != false {
                tabs.first?.cleanup()
            }
            
            var restoredTabs: [AppTab] = []
            for tabId in manifest.tabIds {
                // Create a ChatTabsManager that loads its sessions for this tab
                let chatManager = ChatTabsManager(tabId: tabId)
                let tab = AppTab(id: tabId, title: manifest.tabTitles[tabId.uuidString] ?? "Tab", chatTabsManager: chatManager)
                restoredTabs.append(tab)
            }
            self.tabs = restoredTabs
            self.selectedId = manifest.selectedTabId ?? restoredTabs.first!.id
        }
        // else: keep the default tab created in init
        
        isLoading = false
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
    
    /// Create a new tab that starts directly at a specific directory
    /// Used by macOS Services integration for "New TermAI at Folder"
    /// The terminal starts at the specified directory immediately (no cd command needed)
    func addTab(atDirectory directory: String, copySettingsFrom current: AppTab? = nil) {
        // Record to recent projects for dock menu
        RecentProjectsStore.shared.addProject(path: directory)
        
        // Create tab with initialDirectory set - terminal will start there directly
        let newTab = AppTab(title: "Tab \(tabs.count + 1)", initialDirectory: directory)
        
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
