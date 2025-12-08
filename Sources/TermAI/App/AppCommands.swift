import SwiftUI

@MainActor
struct AppCommands: Commands {
    @ObservedObject var focusedTracker = FocusedStoreTracker.shared
    
    /// Get the current focused TabsStore, or nil if none
    private var tabsStore: TabsStore? {
        focusedTracker.focusedStore
    }
    
    var body: some Commands {
        CommandGroup(replacing: .textFormatting) { }
        
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                guard let store = tabsStore else { return }
                store.addTab(copySettingsFrom: store.selected)
            }
            .keyboardShortcut("t", modifiers: [.command])
            
            Button("New Chat Session") {
                guard let store = tabsStore else { return }
                // Ensure we have a selected tab; if not, create one first
                if store.selected == nil && !store.tabs.isEmpty {
                    store.selectedId = store.tabs[0].id
                }
                if let chatManager = store.selected?.chatTabsManager {
                    _ = chatManager.createNewSession(copySettingsFrom: chatManager.selectedSession)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Close Tab") {
                tabsStore?.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            
            Button("Close Chat Session") {
                if let chatManager = tabsStore?.selected?.chatTabsManager {
                    chatManager.closeSession(at: chatManager.selectedIndex)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        
        CommandGroup(after: .windowArrangement) {
            Button("Next Tab") {
                tabsStore?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            
            Button("Previous Tab") {
                tabsStore?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            
            Divider()
            
            // Quick tab access with Cmd+1-9
            ForEach(1...9, id: \.self) { num in
                Button("Tab \(num)") {
                    tabsStore?.selectTabByNumber(num)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(num)")), modifiers: [.command])
            }
        }
    }
}
