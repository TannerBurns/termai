import Foundation

@MainActor
final class AppTab: Identifiable, ObservableObject {
    let id: UUID = UUID()
    @Published var title: String
    // Multiple chat sessions per global tab
    @Published var chats: [ChatViewModel]
    @Published var selectedChatIndex: Int = 0
    let ptyModel: PTYModel

    init(title: String = "Tab", chatViewModel: ChatViewModel, ptyModel: PTYModel = PTYModel()) {
        self.title = title
        self.chats = [chatViewModel]
        self.ptyModel = ptyModel
    }

    var selectedChat: ChatViewModel { chats[max(0, min(selectedChatIndex, chats.count - 1))] }
}

@MainActor
final class TabsStore: ObservableObject {
    @Published var tabs: [AppTab]
    @Published var selectedId: UUID

    init() {
        let first = AppTab(title: "Tab 1", chatViewModel: ChatViewModel())
        self.tabs = [first]
        self.selectedId = first.id
    }

    var selected: AppTab? { tabs.first(where: { $0.id == selectedId }) }

    func addTab(copyFrom current: AppTab?) {
        let newVM = ChatViewModel()
        if let current {
            let source = current.selectedChat
            newVM.apiBaseURL = source.apiBaseURL
            newVM.apiKey = source.apiKey
            newVM.model = source.model
            newVM.providerName = source.providerName
            newVM.systemPrompt = source.systemPrompt
        }
        let tab = AppTab(title: "Tab \(tabs.count+1)", chatViewModel: newVM)
        tabs.append(tab)
        selectedId = tab.id
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Cancel any in-flight chat streams in the tab being closed
        tabs[idx].chats.forEach { $0.cancelStreaming() }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            addTab(copyFrom: nil)
        } else if selectedId == id {
            selectedId = tabs[min(idx, tabs.count-1)].id
        }
    }

    // MARK: - Per-tab chat management
    func addChatToSelectedTab(copyFrom currentChat: ChatViewModel?) {
        guard let currentTab = selected else { return }
        let newVM = ChatViewModel()
        // Copy only provider configuration; do not copy messages
        if let currentChat {
            newVM.apiBaseURL = currentChat.apiBaseURL
            newVM.apiKey = currentChat.apiKey
            newVM.model = currentChat.model
            newVM.providerName = currentChat.providerName
            newVM.systemPrompt = currentChat.systemPrompt
            // Do not reuse availableModels/modelFetchError references; fetch fresh on demand
        }
        currentTab.chats.append(newVM)
        currentTab.selectedChatIndex = currentTab.chats.count - 1
        // Optionally, initialize with a system message similar to clearChat()
    }
    func closeSelectedChat() {
        guard let currentTab = selected else { return }
        guard !currentTab.chats.isEmpty else { return }
        let idx = currentTab.selectedChatIndex
        let removed = currentTab.chats[idx]
        removed.cancelStreaming()
        currentTab.chats.remove(at: idx)
        currentTab.selectedChatIndex = max(0, min(idx, currentTab.chats.count - 1))
        if currentTab.chats.isEmpty {
            // Preserve provider/model settings when recreating the baseline chat
            let newVM = ChatViewModel()
            newVM.apiBaseURL = removed.apiBaseURL
            newVM.apiKey = removed.apiKey
            newVM.model = removed.model
            newVM.providerName = removed.providerName
            newVM.systemPrompt = removed.systemPrompt
            newVM.availableModels = removed.availableModels
            newVM.modelFetchError = removed.modelFetchError
            currentTab.chats = [newVM]
            currentTab.selectedChatIndex = 0
        }
    }

    func closeChatInSelectedTab(at index: Int) {
        guard let currentTab = selected else { return }
        guard index >= 0 && index < currentTab.chats.count else { return }
        // If this is the only chat, just clear its content instead of removing
        if currentTab.chats.count == 1 {
            currentTab.chats[index].clearChat()
            currentTab.selectedChatIndex = 0
            return
        }
        let removed = currentTab.chats[index]
        removed.cancelStreaming()
        currentTab.chats.remove(at: index)
        if currentTab.chats.isEmpty {
            // Recreate a fresh chat with the same provider/model configuration
            let newVM = ChatViewModel()
            newVM.apiBaseURL = removed.apiBaseURL
            newVM.apiKey = removed.apiKey
            newVM.model = removed.model
            newVM.providerName = removed.providerName
            newVM.systemPrompt = removed.systemPrompt
            newVM.availableModels = removed.availableModels
            newVM.modelFetchError = removed.modelFetchError
            currentTab.chats = [newVM]
            currentTab.selectedChatIndex = 0
        } else {
            if currentTab.selectedChatIndex >= currentTab.chats.count {
                currentTab.selectedChatIndex = currentTab.chats.count - 1
            }
            // If we closed the currently selected one, move selection to the next valid index
            if currentTab.selectedChatIndex == index {
                currentTab.selectedChatIndex = min(index, currentTab.chats.count - 1)
            }
        }
    }
}


