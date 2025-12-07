import SwiftUI

// MARK: - Editor Tab Bar

/// Tab bar displaying terminal and open file tabs
struct EditorTabBar: View {
    @ObservedObject var tabsManager: EditorTabsManager
    @StateObject private var performanceMonitor = PerformanceMonitor.shared
    
    @Environment(\.colorScheme) var colorScheme
    @State private var hoveredTabId: UUID?
    
    private var theme: EditorTabTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Performance graphs (left side, same height as tabs)
            CompactPerformanceView(monitor: performanceMonitor)
                .padding(.horizontal, 6)
            
            // Subtle divider
            Rectangle()
                .fill(theme.divider)
                .frame(width: 1, height: 20)
            
            // Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabsManager.tabs) { tab in
                        EditorTabPill(
                            tab: tab,
                            isSelected: tabsManager.selectedTabId == tab.id,
                            isHovered: hoveredTabId == tab.id,
                            theme: theme,
                            onSelect: {
                                tabsManager.selectTab(id: tab.id)
                            },
                            onClose: {
                                tabsManager.closeTab(id: tab.id)
                            }
                        )
                        .onHover { hovering in
                            hoveredTabId = hovering ? tab.id : nil
                        }
                        .contextMenu {
                            tabContextMenu(for: tab)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            
            Spacer()
        }
        .frame(height: 32)
        .background(theme.barBackground)
        .onAppear {
            performanceMonitor.startMonitoring()
        }
    }
    
    @ViewBuilder
    private func tabContextMenu(for tab: EditorTab) -> some View {
        if tab.type.isFile {
            Button("Close") {
                tabsManager.closeTab(id: tab.id)
            }
            
            Button("Close Others") {
                tabsManager.closeOtherTabs(except: tab.id)
            }
            
            Button("Close All Files") {
                tabsManager.closeAllFileTabs()
            }
            
            Divider()
            
            if let path = tab.filePath {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            
            if tab.isPreview {
                Divider()
                Button("Keep Open") {
                    tabsManager.pinTab(id: tab.id)
                }
            }
        }
    }
}

// MARK: - Editor Tab Pill

struct EditorTabPill: View {
    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    let isHovered: Bool
    let theme: EditorTabTheme
    let onSelect: () -> Void
    let onClose: () -> Void
    
    @State private var closeHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? tab.iconColor : theme.inactiveIcon)
            
            // Title with dirty indicator
            HStack(spacing: 2) {
                if tab.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.activeText : theme.inactiveText)
                    .lineLimit(1)
                    .italic(tab.isPreview)
            }
            
            // Close button (not for terminal)
            if !tab.type.isTerminal && (isSelected || isHovered) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(closeHovered ? theme.activeText : theme.inactiveText)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(closeHovered ? theme.closeHoverBackground : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
            } else if !tab.type.isTerminal {
                // Spacer to maintain consistent width
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            tabBackground
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double tap to pin preview
            if tab.isPreview {
                tabsManager.pinTab(id: tab.id)
            }
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
    }
    
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var tabsManager: EditorTabsManager
    
    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            // Selected tab - prominent background
            VStack(spacing: 0) {
                Rectangle()
                    .fill(theme.activeBackground)
                Rectangle()
                    .fill(theme.activeIndicator)
                    .frame(height: 2)
            }
        } else if isHovered {
            theme.hoverBackground
        } else {
            theme.inactiveBackground
        }
    }
}

// MARK: - Editor Tab Theme

struct EditorTabTheme {
    let barBackground: Color
    let activeBackground: Color
    let inactiveBackground: Color
    let hoverBackground: Color
    let activeText: Color
    let inactiveText: Color
    let activeIcon: Color
    let inactiveIcon: Color
    let activeIndicator: Color
    let closeHoverBackground: Color
    let divider: Color
    
    static let dark = EditorTabTheme(
        barBackground: Color(white: 0.12),
        activeBackground: Color(white: 0.16),
        inactiveBackground: Color.clear,
        hoverBackground: Color(white: 0.14),
        activeText: Color(white: 0.95),
        inactiveText: Color(white: 0.55),
        activeIcon: Color.accentColor,
        inactiveIcon: Color(white: 0.45),
        activeIndicator: Color.accentColor,
        closeHoverBackground: Color(white: 0.25),
        divider: Color(white: 0.2)
    )
    
    static let light = EditorTabTheme(
        barBackground: Color(white: 0.94),
        activeBackground: Color.white,
        inactiveBackground: Color.clear,
        hoverBackground: Color(white: 0.96),
        activeText: Color(white: 0.1),
        inactiveText: Color(white: 0.45),
        activeIcon: Color.accentColor,
        inactiveIcon: Color(white: 0.5),
        activeIndicator: Color.accentColor,
        closeHoverBackground: Color(white: 0.85),
        divider: Color(white: 0.85)
    )
}

// MARK: - Preview

#if DEBUG
struct EditorTabBar_Previews: PreviewProvider {
    static var previews: some View {
        let manager = EditorTabsManager()
        manager.openFile(at: "/Users/test/project/App.swift")
        manager.openFile(at: "/Users/test/project/README.md", asPreview: true)
        
        return VStack(spacing: 0) {
            EditorTabBar(tabsManager: manager)
            Divider()
            Color.gray.opacity(0.1)
        }
        .frame(width: 600, height: 300)
        .environmentObject(manager)
    }
}
#endif

