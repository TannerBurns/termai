import SwiftUI

struct SettingsRootView: View {
    var selectedSession: ChatSession?
    @ObservedObject var ptyModel: PTYModel
    @State private var selectedTab: SettingsTab = .chatModel
    @Environment(\.colorScheme) var colorScheme
    
    // Atom One themed sidebar background
    private var sidebarBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.14, blue: 0.17)  // #21252b - Atom One Dark header
            : Color(red: 0.91, green: 0.91, blue: 0.91)  // #e8e8e8 - Atom One Light header
    }
    
    enum SettingsTab: String, CaseIterable {
        case chatModel = "Chat & Model"
        case providers = "Providers"
        case agent = "Agent"
        case favorites = "Favorites"
        case appearance = "Appearance"
        case usage = "Usage"
        case data = "Data"
        
        var icon: String {
            switch self {
            case .chatModel: return "message.fill"
            case .providers: return "server.rack"
            case .agent: return "cpu"
            case .favorites: return "star.fill"
            case .appearance: return "paintbrush.fill"
            case .usage: return "chart.bar.fill"
            case .data: return "externaldrive.fill"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)
            .background(sidebarBackground)
            
            // Content
            Group {
                switch selectedTab {
                case .chatModel:
                    if let session = selectedSession {
                        SessionSettingsView(session: session)
                    } else {
                        NoSessionPlaceholder()
                    }
                case .providers:
                    ProvidersSettingsView()
                case .agent:
                    AgentSettingsView()
                case .favorites:
                    FavoritesSettingsView()
                case .appearance:
                    AppearanceSettingsView(ptyModel: ptyModel)
                case .usage:
                    UsageSettingsView()
                case .data:
                    DataSettingsView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
