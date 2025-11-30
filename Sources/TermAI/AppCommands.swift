import SwiftUI

@MainActor
struct AppCommands: Commands {
    @ObservedObject var tabsStore: TabsStore
    
    var body: some Commands {
        CommandGroup(replacing: .textFormatting) { }
        
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                tabsStore.addTab(copySettingsFrom: tabsStore.selected)
            }
            .keyboardShortcut("t", modifiers: [.command])
            
            Button("New Chat Session") {
                _ = tabsStore.selected?.chatTabsManager.createNewSession(
                    copySettingsFrom: tabsStore.selected?.chatTabsManager.selectedSession
                )
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Close Tab") {
                tabsStore.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            
            Button("Close Chat Session") {
                if let chatManager = tabsStore.selected?.chatTabsManager {
                    chatManager.closeSession(at: chatManager.selectedIndex)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        
        CommandGroup(after: .windowArrangement) {
            Button("Next Tab") {
                tabsStore.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            
            Button("Previous Tab") {
                tabsStore.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            
            Divider()
            
            // Quick tab access with Cmd+1-9
            ForEach(1...9, id: \.self) { num in
                Button("Tab \(num)") {
                    tabsStore.selectTabByNumber(num)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(num)")), modifiers: [.command])
            }
        }
    }
}
