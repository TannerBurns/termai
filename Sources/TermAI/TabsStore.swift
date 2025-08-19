import Foundation

@MainActor
final class AppTab: Identifiable, ObservableObject {
    let id: UUID = UUID()
    @Published var title: String
    let chatViewModel: ChatViewModel
    let ptyModel: PTYModel

    init(title: String = "Tab", chatViewModel: ChatViewModel, ptyModel: PTYModel = PTYModel()) {
        self.title = title
        self.chatViewModel = chatViewModel
        self.ptyModel = ptyModel
    }
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
            newVM.apiBaseURL = current.chatViewModel.apiBaseURL
            newVM.apiKey = current.chatViewModel.apiKey
            newVM.model = current.chatViewModel.model
            newVM.providerName = current.chatViewModel.providerName
            newVM.systemPrompt = current.chatViewModel.systemPrompt
        }
        let tab = AppTab(title: "Tab \(tabs.count+1)", chatViewModel: newVM)
        tabs.append(tab)
        selectedId = tab.id
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            addTab(copyFrom: nil)
        } else if selectedId == id {
            selectedId = tabs[min(idx, tabs.count-1)].id
        }
    }
}


