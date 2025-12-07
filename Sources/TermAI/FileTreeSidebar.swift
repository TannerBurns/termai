import SwiftUI

// MARK: - File Tree Sidebar

/// Collapsible sidebar showing the file tree synced to terminal CWD
struct FileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel
    let onFileSelected: (FileTreeNode) -> Void
    let onFileDoubleClicked: (FileTreeNode) -> Void
    let onFolderGoTo: ((FileTreeNode) -> Void)?
    let onNavigateUp: (() -> Void)?
    let onNavigateHome: (() -> Void)?
    
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText: String = ""
    @State private var hoveredNodeId: String?
    
    init(
        model: FileTreeModel,
        onFileSelected: @escaping (FileTreeNode) -> Void,
        onFileDoubleClicked: @escaping (FileTreeNode) -> Void,
        onFolderGoTo: ((FileTreeNode) -> Void)? = nil,
        onNavigateUp: (() -> Void)? = nil,
        onNavigateHome: (() -> Void)? = nil
    ) {
        self.model = model
        self.onFileSelected = onFileSelected
        self.onFileDoubleClicked = onFileDoubleClicked
        self.onFolderGoTo = onFolderGoTo
        self.onNavigateUp = onNavigateUp
        self.onNavigateHome = onNavigateHome
    }
    
    private var theme: FileTreeTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader
            
            Divider()
            
            // Search bar
            searchBar
            
            Divider()
            
            // Tree content
            if model.isLoading {
                loadingView
            } else if model.rootNode != nil {
                treeContent
            } else {
                emptyView
            }
        }
        .background(theme.background)
    }
    
    // MARK: - Header
    
    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.accent)
            
            Text("Explorer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            
            Spacer()
            
            // Navigate to home
            Button(action: { onNavigateHome?() }) {
                Image(systemName: "house")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Go to Home (~)")
            
            // Navigate up one directory
            Button(action: { onNavigateUp?() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Go Up One Directory (..)")
            
            // Refresh button
            Button(action: { model.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            
            // Collapse all button
            Button(action: collapseAll) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Collapse All")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.headerBackground)
    }
    
    // MARK: - Search
    
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
            
            TextField("Search files...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.searchBackground)
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - Tree Content
    
    private var treeContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let nodes = filteredNodes
                ForEach(nodes) { node in
                    FileTreeRow(
                        node: node,
                        isSelected: model.selectedNode?.id == node.id,
                        isHovered: hoveredNodeId == node.id,
                        theme: theme,
                        onTap: {
                            if node.isDirectory {
                                model.toggleExpansion(node)
                            } else {
                                model.selectedNode = node
                                onFileSelected(node)
                            }
                        },
                        onDoubleTap: {
                            if node.isDirectory {
                                // Double-click on folder = go to that folder
                                onFolderGoTo?(node)
                            } else {
                                onFileDoubleClicked(node)
                            }
                        },
                        onToggleExpand: {
                            model.toggleExpansion(node)
                        },
                        onGoToFolder: node.isDirectory ? { onFolderGoTo?(node) } : nil,
                        onRevealInFinder: {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.path)
                        }
                    )
                    .onHover { hovering in
                        hoveredNodeId = hovering ? node.id : nil
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var filteredNodes: [FileTreeNode] {
        let allNodes = model.flattenedNodes()
        
        guard !searchText.isEmpty else { return allNodes }
        
        let query = searchText.lowercased()
        return allNodes.filter { node in
            node.name.lowercased().contains(query)
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading files...")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(theme.secondaryText)
            Text("No folder open")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Actions
    
    private func collapseAll() {
        func collapse(_ node: FileTreeNode) {
            if node.isDirectory && node.isExpanded {
                node.isExpanded = false
            }
            node.children?.forEach { collapse($0) }
        }
        if let root = model.rootNode {
            root.children?.forEach { collapse($0) }
        }
    }
}

// MARK: - File Tree Row

struct FileTreeRow: View {
    @ObservedObject var node: FileTreeNode
    let isSelected: Bool
    let isHovered: Bool
    let theme: FileTreeTheme
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onToggleExpand: () -> Void
    let onGoToFolder: (() -> Void)?
    let onRevealInFinder: () -> Void
    
    private let indentWidth: CGFloat = 16
    private let iconSize: CGFloat = 14
    
    var body: some View {
        HStack(spacing: 4) {
            // Indent spacer
            Color.clear
                .frame(width: CGFloat(node.depth) * indentWidth)
            
            // Expand/collapse chevron for directories
            if node.isDirectory {
                Button(action: onToggleExpand) {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12)
            }
            
            // File/folder icon
            Image(systemName: node.icon)
                .font(.system(size: iconSize - 2))
                .foregroundColor(node.iconColor)
                .frame(width: iconSize, height: iconSize)
            
            // Name
            Text(node.name)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? theme.selectedText : theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Loading indicator for directories
            if node.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .contextMenu {
            if node.isDirectory {
                Button {
                    onGoToFolder?()
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                
                Divider()
            }
            
            Button {
                onRevealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
    
    private var backgroundColor: Color {
        if isSelected {
            return theme.selectedBackground
        } else if isHovered {
            return theme.hoverBackground
        }
        return Color.clear
    }
}

// MARK: - File Tree Theme

struct FileTreeTheme {
    let background: Color
    let headerBackground: Color
    let searchBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let selectedBackground: Color
    let selectedText: Color
    let hoverBackground: Color
    let accent: Color
    let divider: Color
    
    static let dark = FileTreeTheme(
        background: Color(white: 0.11),
        headerBackground: Color(white: 0.13),
        searchBackground: Color(white: 0.15),
        primaryText: Color(white: 0.9),
        secondaryText: Color(white: 0.5),
        selectedBackground: Color.accentColor.opacity(0.3),
        selectedText: Color.white,
        hoverBackground: Color(white: 0.16),
        accent: Color.accentColor,
        divider: Color(white: 0.2)
    )
    
    static let light = FileTreeTheme(
        background: Color(white: 0.96),
        headerBackground: Color(white: 0.94),
        searchBackground: Color(white: 0.92),
        primaryText: Color(white: 0.1),
        secondaryText: Color(white: 0.45),
        selectedBackground: Color.accentColor.opacity(0.2),
        selectedText: Color.accentColor,
        hoverBackground: Color(white: 0.9),
        accent: Color.accentColor,
        divider: Color(white: 0.85)
    )
}

// MARK: - Resizable File Tree Container

/// Container view that adds resize handle to the file tree sidebar
struct ResizableFileTreeSidebar: View {
    @ObservedObject var model: FileTreeModel
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onFileSelected: (FileTreeNode) -> Void
    let onFileDoubleClicked: (FileTreeNode) -> Void
    let onFolderGoTo: ((FileTreeNode) -> Void)?
    let onNavigateUp: (() -> Void)?
    let onNavigateHome: (() -> Void)?
    
    @State private var isDragging: Bool = false
    
    init(
        model: FileTreeModel,
        width: Binding<CGFloat>,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        onFileSelected: @escaping (FileTreeNode) -> Void,
        onFileDoubleClicked: @escaping (FileTreeNode) -> Void,
        onFolderGoTo: ((FileTreeNode) -> Void)? = nil,
        onNavigateUp: (() -> Void)? = nil,
        onNavigateHome: (() -> Void)? = nil
    ) {
        self.model = model
        self._width = width
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.onFileSelected = onFileSelected
        self.onFileDoubleClicked = onFileDoubleClicked
        self.onFolderGoTo = onFolderGoTo
        self.onNavigateUp = onNavigateUp
        self.onNavigateHome = onNavigateHome
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // File tree content
            FileTreeSidebar(
                model: model,
                onFileSelected: onFileSelected,
                onFileDoubleClicked: onFileDoubleClicked,
                onFolderGoTo: onFolderGoTo,
                onNavigateUp: onNavigateUp,
                onNavigateHome: onNavigateHome
            )
            .frame(width: width)
            
            // Resize handle
            FileTreeResizeHandle(isDragging: $isDragging)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let newWidth = width + value.translation.width
                            width = max(minWidth, min(newWidth, maxWidth))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
        }
    }
}

// MARK: - Resize Handle

struct FileTreeResizeHandle: View {
    @Binding var isDragging: Bool
    @State private var isHovered: Bool = false
    
    private var isActive: Bool { isDragging || isHovered }
    
    var body: some View {
        Rectangle()
            .fill(isActive ? Color.accentColor : Color.primary.opacity(0.1))
            .frame(width: isActive ? 3 : 1)
            .onHover { isHovered = $0 }
            .cursor(NSCursor.resizeLeftRight)
    }
}

// MARK: - Preview

#if DEBUG
struct FileTreeSidebar_Previews: PreviewProvider {
    static var previews: some View {
        FileTreeSidebar(
            model: FileTreeModel(),
            onFileSelected: { _ in },
            onFileDoubleClicked: { _ in }
        )
        .frame(width: 220, height: 400)
    }
}
#endif

