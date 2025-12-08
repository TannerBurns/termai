import SwiftUI
import AppKit

// MARK: - Native Tooltip Modifier

/// A view modifier that adds native AppKit tooltips
struct NativeTooltip: ViewModifier {
    let text: String
    
    func body(content: Content) -> some View {
        content
            .background(TooltipView(text: text))
    }
}

/// NSViewRepresentable that adds a native tooltip
private struct TooltipView: NSViewRepresentable {
    let text: String
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// Adds a native AppKit tooltip that works reliably
    func nativeTooltip(_ text: String) -> some View {
        modifier(NativeTooltip(text: text))
    }
}

// MARK: - File Viewer Tab

/// File viewer/editor with syntax highlighting, line numbers, and search
struct FileViewerTab: View {
    @ObservedObject var tab: EditorTab
    let onAddToChat: (String, String?, [LineRange]?) -> Void  // (content, filePath, lineRanges)
    
    @Environment(\.colorScheme) var colorScheme
    @State private var fileContent: String = ""
    @State private var originalContent: String = ""  // For tracking changes
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var searchText: String = ""
    @State private var showSearch: Bool = false
    @State private var searchMatches: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = 0
    @State private var searchCaseSensitive: Bool = false
    @State private var searchWholeWord: Bool = false
    @State private var searchUseRegex: Bool = false
    @State private var selectedRange: NSRange?
    @State private var selectedText: String = ""
    @State private var selectedLineRange: (start: Int, end: Int)?
    @State private var imageData: NSImage?
    @State private var showMarkdownPreview: Bool = false
    @State private var showUnsavedAlert: Bool = false
    @State private var showExternalChangeAlert: Bool = false
    @State private var externallyModified: Bool = false
    @FocusState private var isSearchFocused: Bool
    
    private var theme: FileViewerTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    /// Check if this is an image file
    private var isImageFile: Bool {
        guard let ext = tab.fileExtension else { return false }
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "ico", "svg"].contains(ext)
    }
    
    /// Check if this is a markdown file
    private var isMarkdownFile: Bool {
        guard let ext = tab.fileExtension else { return false }
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }
    
    /// Check if file has unsaved changes
    private var isDirty: Bool {
        fileContent != originalContent
    }
    
    /// Save the file
    private func saveFile() {
        guard let path = tab.filePath else { return }
        
        do {
            try fileContent.write(toFile: path, atomically: true, encoding: .utf8)
            originalContent = fileContent
            tab.isDirty = false
        } catch {
            print("[FileViewerTab] Failed to save: \(error)")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // File header with actions
            fileHeader
            
            Divider()
            
            // Search bar (when visible, not for images)
            if showSearch && !isImageFile {
                searchBar
                Divider()
            }
            
            // Content area
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if isImageFile {
                imageView
            } else if isMarkdownFile && showMarkdownPreview {
                markdownPreviewView
            } else {
                codeView
            }
        }
        .background(theme.background)
        .onAppear {
            loadFile()
        }
        .onChange(of: tab.filePath) { _ in
            loadFile()
        }
        .onChange(of: isDirty) { dirty in
            tab.isDirty = dirty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FileViewerFind"))) { _ in
            if !isImageFile {
                showSearch = true
                isSearchFocused = true
            }
        }
        // Cmd+S to save
        .background(
            Button("") { saveFile() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
        )
        // Listen for file modifications from agent tools
        .onReceive(NotificationCenter.default.publisher(for: .TermAIFileModifiedOnDisk)) { notification in
            handleExternalFileChange(notification)
        }
        // External change alert
        .alert("File Modified Externally", isPresented: $showExternalChangeAlert) {
            Button("Reload from Disk", role: .destructive) {
                loadFile()
                externallyModified = false
            }
            Button("Keep My Version") {
                // User wants to keep their version - mark that we've seen the change
                externallyModified = false
            }
            if isDirty {
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if isDirty {
                Text("This file was modified by the agent. You have unsaved changes. Reloading will discard your changes.")
            } else {
                Text("This file was modified by the agent. Would you like to reload it?")
            }
        }
    }
    
    // MARK: - File Header
    
    private var fileHeader: some View {
        HStack(spacing: 8) {
            // File icon and name
            Image(systemName: isImageFile ? "photo" : tab.icon)
                .font(.system(size: 12))
                .foregroundColor(isImageFile ? .purple : tab.iconColor)
            
            Text(tab.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            
            if let path = tab.filePath {
                Text("—")
                    .foregroundColor(theme.secondaryText)
                Text(shortenedPath(path))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            
            // Image dimensions badge
            if isImageFile, let image = imageData {
                Text("\(Int(image.size.width))×\(Int(image.size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            
            Spacer(minLength: 8)
            
            // Actions - use fixedSize to prevent wrapping
            HStack(spacing: 8) {
                // Save button (show when dirty)
                if isDirty && !isImageFile {
                    Button(action: saveFile) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.borderless)
                    .nativeTooltip("Save changes (⌘S)")
                }
                
                // Markdown preview toggle (for markdown files only)
                if isMarkdownFile {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMarkdownPreview.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showMarkdownPreview ? "doc.text" : "eye")
                                .font(.system(size: 11))
                            Text(showMarkdownPreview ? "Code" : "Preview")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(showMarkdownPreview ? .purple : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(showMarkdownPreview ? Color.purple.opacity(0.15) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.borderless)
                    .nativeTooltip(showMarkdownPreview ? "Show source code" : "Preview rendered markdown")
                }
                
                // Search toggle (not for images or markdown preview)
                if !isImageFile && !(isMarkdownFile && showMarkdownPreview) {
                    Button(action: {
                        showSearch.toggle()
                        if showSearch {
                            isSearchFocused = true
                        }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(showSearch ? theme.accent : theme.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .nativeTooltip("Search in File (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)
                }
                
                // Add to chat button (show selected text or full file)
                if !isImageFile {
                    Button(action: {
                        let contentToAdd = selectedText.isEmpty ? fileContent : selectedText
                        let ranges: [LineRange]? = selectedLineRange.map { [LineRange(start: $0.start, end: $0.end)] }
                        onAddToChat(contentToAdd, tab.filePath, ranges)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.right.fill")
                                .font(.system(size: 9))
                            if let range = selectedLineRange {
                                Text("L\(range.start)-\(range.end)")
                                    .font(.system(size: 10, weight: .medium))
                            } else {
                                Text(selectedText.isEmpty ? "Chat" : "Add")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(selectedText.isEmpty ? Color.accentColor : Color.green)
                        )
                    }
                    .fixedSize()
                    .buttonStyle(.borderless)
                    .nativeTooltip(selectedText.isEmpty ? "Add file content to chat context" : "Add selected lines to chat context")
                }
                
                // Copy button
                Button(action: copyContent) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .nativeTooltip("Copy Content")
            }
            .fixedSize(horizontal: true, vertical: false)  // Prevent buttons from wrapping
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.headerBackground)
    }
    
    // MARK: - Search Bar
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .focused($isSearchFocused)
                    .onSubmit {
                        findNext()
                    }
                    .onChange(of: searchText) { _ in
                        updateSearchMatches()
                    }
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.borderless)
                    .nativeTooltip("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.searchFieldBackground)
            )
            .frame(maxWidth: 300)
            
            // Search options
            HStack(spacing: 4) {
                // Case sensitive
                SearchOptionButton(
                    icon: "textformat",
                    label: "Aa",
                    isActive: searchCaseSensitive,
                    help: "Case Sensitive"
                ) {
                    searchCaseSensitive.toggle()
                    updateSearchMatches()
                }
                
                // Whole word
                SearchOptionButton(
                    icon: nil,
                    label: "W",
                    isActive: searchWholeWord,
                    help: "Whole Word"
                ) {
                    searchWholeWord.toggle()
                    updateSearchMatches()
                }
                
                // Regex
                SearchOptionButton(
                    icon: nil,
                    label: ".*",
                    isActive: searchUseRegex,
                    help: "Use Regular Expression"
                ) {
                    searchUseRegex.toggle()
                    updateSearchMatches()
                }
            }
            
            // Match count
            if !searchText.isEmpty {
                Text(matchCountText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                
                // Navigation buttons
                Button(action: findPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .disabled(searchMatches.isEmpty)
                .nativeTooltip("Previous Match (⇧Enter)")
                
                Button(action: findNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .disabled(searchMatches.isEmpty)
                .nativeTooltip("Next Match (Enter)")
            }
            
            Spacer()
            
            // Close search
            Button(action: { showSearch = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.borderless)
            .nativeTooltip("Close Search (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.searchBarBackground)
    }
    
    // MARK: - Search Option Button
    
    struct SearchOptionButton: View {
        let icon: String?
        let label: String
        let isActive: Bool
        let help: String
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                Group {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                    } else {
                        Text(label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
                .foregroundColor(isActive ? .white : .secondary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? Color.accentColor : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.borderless)
            .nativeTooltip(help)
        }
    }
    
    // MARK: - Code View
    
    @State private var scrollOffset: CGFloat = 0
    
    // Computed line count to ensure SwiftUI detects changes
    private var lineCount: Int {
        fileContent.components(separatedBy: .newlines).count
    }
    
    private var codeView: some View {
        HStack(spacing: 0) {
            // Line numbers gutter (SwiftUI) - synced with editor scroll
            LineNumberGutter(
                lineCount: lineCount,
                content: fileContent,
                originalContent: originalContent,
                theme: theme,
                scrollOffset: scrollOffset
            )
            
            // Editor (NSTextView)
            SimpleEditableTextView(
                content: $fileContent,
                language: tab.language,
                theme: theme,
                colorScheme: colorScheme,
                searchText: searchText,
                currentMatchIndex: currentMatchIndex,
                searchCaseSensitive: searchCaseSensitive,
                searchWholeWord: searchWholeWord,
                searchUseRegex: searchUseRegex,
                onSelectionChanged: { selection, lineRange in
                    selectedText = selection
                    selectedLineRange = lineRange
                },
                onScrollChanged: { offset in
                    scrollOffset = offset
                },
                onMatchesFound: { count in
                    // Update search matches count
                    updateSearchMatches()
                }
            )
        }
    }
    
    // MARK: - Image View
    
    private var imageView: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let image = imageData {
                    ZStack {
                        // Checkerboard background for transparency
                        CheckerboardBackground()
                        
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    }
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                        Text("Unable to load image")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    
    // MARK: - Markdown Preview View
    
    private var markdownPreviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownRenderer(text: fileContent)
                    .textSelection(.enabled)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colorScheme == .dark ? Color(white: 0.1) : Color.white)
    }
    
    // MARK: - Loading/Error Views
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading file...")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Error loading file")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                loadFile()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helpers
    
    private func loadFile() {
        guard let path = tab.filePath else {
            errorMessage = "No file path"
            isLoading = false
            return
        }
        
        isLoading = true
        errorMessage = nil
        imageData = nil
        
        Task {
            if isImageFile {
                // Load image
                if let image = NSImage(contentsOfFile: path) {
                    await MainActor.run {
                        self.imageData = image
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.errorMessage = "Unable to load image"
                        self.isLoading = false
                    }
                }
            } else {
                // Load text file
                do {
                    let content = try String(contentsOfFile: path, encoding: .utf8)
                    await MainActor.run {
                        self.fileContent = content
                        self.originalContent = content  // Track original for dirty detection
                        self.isLoading = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                    }
                }
            }
        }
    }
    
    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileContent, forType: .string)
    }
    
    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    private var matchCountText: String {
        if searchMatches.isEmpty {
            return "No matches"
        } else if searchMatches.count == 1 {
            return "1 match"
        } else {
            return "\(currentMatchIndex + 1) of \(searchMatches.count)"
        }
    }
    
    private func updateSearchMatches() {
        guard !searchText.isEmpty else {
            searchMatches = []
            return
        }
        
        var matches: [Range<String.Index>] = []
        
        // Build the regex pattern
        let pattern: String
        if searchUseRegex {
            pattern = searchWholeWord ? "\\b\(searchText)\\b" : searchText
        } else {
            let escapedSearch = NSRegularExpression.escapedPattern(for: searchText)
            pattern = searchWholeWord ? "\\b\(escapedSearch)\\b" : escapedSearch
        }
        
        // Set regex options
        var regexOptions: NSRegularExpression.Options = []
        if !searchCaseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        
        // Find all matches using regex
        if let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) {
            let nsRange = NSRange(fileContent.startIndex..., in: fileContent)
            let results = regex.matches(in: fileContent, range: nsRange)
            
            for result in results {
                if let range = Range(result.range, in: fileContent) {
                    matches.append(range)
                }
            }
        }
        
        searchMatches = matches
        currentMatchIndex = matches.isEmpty ? 0 : 0
    }
    
    private func findNext() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
    }
    
    private func findPrevious() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = currentMatchIndex > 0 ? currentMatchIndex - 1 : searchMatches.count - 1
    }
    
    private func lineForMatch(_ index: Int) -> Int {
        guard index < searchMatches.count else { return 0 }
        let match = searchMatches[index]
        let prefix = fileContent[..<match.lowerBound]
        return prefix.components(separatedBy: .newlines).count - 1
    }
    
    // MARK: - External File Change Handling
    
    /// Handle notification that a file was modified externally (by agent tools)
    private func handleExternalFileChange(_ notification: Notification) {
        guard let modifiedPath = notification.userInfo?["path"] as? String,
              let currentPath = tab.filePath else { return }
        
        // Normalize paths for comparison
        let normalizedModified = URL(fileURLWithPath: modifiedPath).standardized.path
        let normalizedCurrent = URL(fileURLWithPath: currentPath).standardized.path
        
        guard normalizedModified == normalizedCurrent else { return }
        
        // This file was modified
        if isDirty {
            // User has unsaved changes - show conflict alert
            externallyModified = true
            showExternalChangeAlert = true
        } else {
            // No local changes - auto-reload
            loadFile()
        }
    }
}

// MARK: - File Viewer Theme

struct FileViewerTheme {
    let background: Color
    let headerBackground: Color
    let searchBarBackground: Color
    let searchFieldBackground: Color
    let searchHighlight: Color
    let primaryText: Color
    let secondaryText: Color
    let lineNumber: Color
    let gutterBackground: Color
    let accent: Color
    
    // Atom One Dark colors
    static let dark = FileViewerTheme(
        background: Color(red: 0.16, green: 0.17, blue: 0.20),           // #282c34
        headerBackground: Color(red: 0.13, green: 0.15, blue: 0.17),     // #21252b
        searchBarBackground: Color(red: 0.13, green: 0.15, blue: 0.17),  // #21252b
        searchFieldBackground: Color(red: 0.24, green: 0.27, blue: 0.32), // #3e4451
        searchHighlight: Color(red: 0.90, green: 0.75, blue: 0.48),      // #e5c07b
        primaryText: Color(red: 0.67, green: 0.70, blue: 0.75),          // #abb2bf
        secondaryText: Color(red: 0.36, green: 0.39, blue: 0.44),        // #5c6370
        lineNumber: Color(red: 0.39, green: 0.43, blue: 0.51),           // #636d83
        gutterBackground: Color(red: 0.13, green: 0.15, blue: 0.17),     // #21252b
        accent: Color(red: 0.38, green: 0.69, blue: 0.94)                // #61afef
    )
    
    // Atom One Light colors
    static let light = FileViewerTheme(
        background: Color(red: 0.98, green: 0.98, blue: 0.98),           // #fafafa
        headerBackground: Color(red: 0.94, green: 0.94, blue: 0.94),     // #f0f0f0
        searchBarBackground: Color(red: 0.94, green: 0.94, blue: 0.94),  // #f0f0f0
        searchFieldBackground: Color(red: 0.90, green: 0.90, blue: 0.90), // #e5e5e6
        searchHighlight: Color(red: 0.76, green: 0.52, blue: 0.00),      // #c18401
        primaryText: Color(red: 0.22, green: 0.23, blue: 0.26),          // #383a42
        secondaryText: Color(red: 0.63, green: 0.63, blue: 0.65),        // #a0a1a7
        lineNumber: Color(red: 0.62, green: 0.62, blue: 0.62),           // #9d9d9f
        gutterBackground: Color(red: 0.94, green: 0.94, blue: 0.94),     // #f0f0f0
        accent: Color(red: 0.25, green: 0.47, blue: 0.95)                // #4078f2
    )
}

// MARK: - Line Number Gutter (SwiftUI)

/// SwiftUI view showing line numbers with diff indicators, synced with editor scroll
struct LineNumberGutter: View {
    let lineCount: Int  // Explicit line count to trigger updates
    let content: String
    let originalContent: String
    let theme: FileViewerTheme
    let scrollOffset: CGFloat
    
    private var lines: [String] {
        content.components(separatedBy: .newlines)
    }
    
    private var originalLines: [String] {
        originalContent.components(separatedBy: .newlines)
    }
    
    private func lineState(at index: Int) -> LineState {
        if index >= originalLines.count {
            return .added
        } else if index < lines.count && lines[index] != originalLines[index] {
            return .modified
        }
        return .unchanged
    }
    
    enum LineState {
        case unchanged, modified, added
    }
    
    private let lineHeight: CGFloat = 17
    private let topPadding: CGFloat = 8
    
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .trailing, spacing: 0) {
                // Use lineCount to ensure view updates when lines change
                ForEach(0..<max(lineCount, 1), id: \.self) { index in
                    HStack(spacing: 4) {
                        // Diff indicator
                        let state = lineState(at: index)
                        if state != .unchanged {
                            Rectangle()
                                .fill(state == .added ? Color.green : Color.orange)
                                .frame(width: 3)
                        } else {
                            Color.clear.frame(width: 3)
                        }
                        
                        // Line number
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.lineNumber)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .frame(height: lineHeight)
                }
            }
            .padding(.top, topPadding)
            .offset(y: -scrollOffset)  // Sync with editor scroll
        }
        .clipped()  // Hide content that scrolls out of view
        .frame(width: 50)
        .background(theme.gutterBackground)
    }
}

// MARK: - Simple Editable Text View

/// A simple editable text view without ruler complications
struct SimpleEditableTextView: NSViewRepresentable {
    @Binding var content: String
    let language: String?
    let theme: FileViewerTheme
    let colorScheme: ColorScheme
    let searchText: String
    let currentMatchIndex: Int
    let searchCaseSensitive: Bool
    let searchWholeWord: Bool
    let searchUseRegex: Bool
    let onSelectionChanged: (String, (start: Int, end: Int)?) -> Void
    let onScrollChanged: (CGFloat) -> Void
    let onMatchesFound: (Int) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        // Configure for editing
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        
        // Colors
        textView.backgroundColor = NSColor(theme.background)
        textView.insertionPointColor = NSColor(colorScheme == .dark ? .white : .black)
        
        // Set initial content
        textView.string = content
        
        // Delegate
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        
        // Apply syntax highlighting
        applySyntaxHighlighting(to: textView)
        
        // Scroll view config
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        
        // Observe scroll changes
        if let clipView = scrollView.contentView as? NSClipView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.scrollViewDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        // Update content if changed externally
        let contentChanged = !context.coordinator.isEditing && textView.string != content
        if contentChanged {
            textView.string = content
        }
        
        // Update colors when theme/colorScheme changes
        textView.backgroundColor = NSColor(theme.background)
        textView.insertionPointColor = NSColor(colorScheme == .dark ? .white : .black)
        
        // Re-apply syntax highlighting when content or theme changes
        // We do this outside the coordinator's editing check to handle theme changes
        if contentChanged || context.coordinator.lastColorScheme != colorScheme {
            context.coordinator.lastColorScheme = colorScheme
            applySyntaxHighlighting(to: textView)
        }
        
        // Apply or clear search highlighting
        if !searchText.isEmpty {
            applySearchHighlighting(
                to: textView,
                searchText: searchText,
                currentMatchIndex: currentMatchIndex,
                caseSensitive: searchCaseSensitive,
                wholeWord: searchWholeWord,
                useRegex: searchUseRegex
            )
        } else {
            // Clear search highlights when search is empty
            clearSearchHighlighting(from: textView)
        }
    }
    
    private func clearSearchHighlighting(from textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
    }
    
    private func applySearchHighlighting(
        to textView: NSTextView,
        searchText: String,
        currentMatchIndex: Int,
        caseSensitive: Bool,
        wholeWord: Bool,
        useRegex: Bool
    ) {
        guard let textStorage = textView.textStorage else { return }
        let text = textView.string
        guard !text.isEmpty && !searchText.isEmpty else { return }
        
        // Remove existing search highlights
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
        
        // Build the regex pattern
        let pattern: String
        if useRegex {
            pattern = wholeWord ? "\\b\(searchText)\\b" : searchText
        } else {
            let escapedSearch = NSRegularExpression.escapedPattern(for: searchText)
            pattern = wholeWord ? "\\b\(escapedSearch)\\b" : escapedSearch
        }
        
        // Set regex options
        var regexOptions: NSRegularExpression.Options = []
        if !caseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        
        // Find all matches
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return }
        let matches = regex.matches(in: text, range: fullRange)
        
        // Highlight all matches
        let highlightColor = NSColor.yellow.withAlphaComponent(0.4)
        let currentHighlightColor = NSColor.orange.withAlphaComponent(0.6)
        
        for (index, match) in matches.enumerated() {
            let color = index == currentMatchIndex ? currentHighlightColor : highlightColor
            textStorage.addAttribute(.backgroundColor, value: color, range: match.range)
        }
        
        // Scroll to current match
        if currentMatchIndex < matches.count {
            let matchRange = matches[currentMatchIndex].range
            textView.scrollRangeToVisible(matchRange)
            textView.showFindIndicator(for: matchRange)
        }
    }
    
    private func applySyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let syntaxTheme = colorScheme == .dark ? SyntaxTheme.dark : SyntaxTheme.light
        let plainColor = NSColor(syntaxTheme.plain)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        
        textStorage.addAttributes([
            .foregroundColor: plainColor,
            .font: font
        ], range: fullRange)
        
        if let lang = language?.lowercased() {
            applyKeywordHighlighting(to: textStorage, language: lang, theme: syntaxTheme)
        }
    }
    
    private func applyKeywordHighlighting(to textStorage: NSTextStorage, language: String, theme: SyntaxTheme) {
        let text = textStorage.string
        guard !text.isEmpty else { return }
        
        let keywords: Set<String>
        switch language {
        case "swift":
            keywords = ["func", "var", "let", "class", "struct", "enum", "protocol", "import", "return", "if", "else", "for", "while", "guard", "switch", "case", "default", "break", "continue", "true", "false", "nil", "self", "Self", "init", "public", "private", "static", "async", "await"]
        case "python":
            keywords = ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "try", "except", "with", "as", "True", "False", "None", "and", "or", "not", "in", "is"]
        case "javascript", "typescript":
            keywords = ["function", "const", "let", "var", "class", "import", "export", "return", "if", "else", "for", "while", "switch", "case", "true", "false", "null", "undefined", "this", "new", "async", "await"]
        default:
            keywords = []
        }
        
        let keywordColor = NSColor(theme.keyword)
        let stringColor = NSColor(theme.string)
        let commentColor = NSColor(theme.comment)
        
        // Highlight keywords
        for keyword in keywords {
            if let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b") {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    textStorage.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                }
            }
        }
        
        // Highlight strings
        if let regex = try? NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                textStorage.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }
        
        // Highlight comments
        if let regex = try? NSRegularExpression(pattern: "//.*$|#.*$", options: .anchorsMatchLines) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                textStorage.addAttribute(.foregroundColor, value: commentColor, range: match.range)
            }
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SimpleEditableTextView
        weak var textView: NSTextView?
        var isEditing = false
        var isHighlighting = false  // Prevent recursive highlighting
        var lastColorScheme: ColorScheme?  // Track color scheme changes
        
        init(parent: SimpleEditableTextView) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isHighlighting else { return }  // Skip if we're in the middle of highlighting
            
            isEditing = true
            parent.content = textView.string
            isEditing = false
            
            // Debounce syntax highlighting to avoid performance issues
            // Apply highlighting after a short delay
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyHighlightingDelayed), object: nil)
            perform(#selector(applyHighlightingDelayed), with: nil, afterDelay: 0.1)
        }
        
        @objc private func applyHighlightingDelayed() {
            guard let textView = textView, !isHighlighting else { return }
            isHighlighting = true
            parent.applySyntaxHighlighting(to: textView)
            isHighlighting = false
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            
            if selectedRange.length > 0 {
                let text = textView.string as NSString
                let selectedText = text.substring(with: selectedRange)
                
                let fullText = textView.string
                let beforeSelection = String(fullText.prefix(selectedRange.location))
                let startLine = beforeSelection.components(separatedBy: .newlines).count
                var selectedLines = selectedText.components(separatedBy: .newlines).count
                // If selection ends with newline, the last component is empty - don't count it
                if selectedText.last?.isNewline == true {
                    selectedLines -= 1
                }
                let endLine = startLine + max(selectedLines, 1) - 1
                
                parent.onSelectionChanged(selectedText, (start: startLine, end: endLine))
            } else {
                parent.onSelectionChanged("", nil)
            }
        }
        
        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            let scrollOffset = clipView.bounds.origin.y
            // Update immediately without async to prevent lag
            parent.onScrollChanged(scrollOffset)
        }
    }
}

// MARK: - Selectable Code View (Legacy - for read-only mode)

/// A code view that supports multi-line text selection and optional editing using NSTextView
struct SelectableCodeView: NSViewRepresentable {
    let content: String
    let originalContent: String
    let language: String?
    let searchText: String
    let searchMatches: [Range<String.Index>]
    let theme: FileViewerTheme
    let colorScheme: ColorScheme
    let isEditable: Bool
    let onSelectionChanged: (String, (start: Int, end: Int)?) -> Void
    let onContentChanged: ((String) -> Void)?
    
    init(content: String, originalContent: String = "", language: String?, searchText: String, searchMatches: [Range<String.Index>], theme: FileViewerTheme, colorScheme: ColorScheme, isEditable: Bool = false, onSelectionChanged: @escaping (String, (start: Int, end: Int)?) -> Void, onContentChanged: ((String) -> Void)? = nil) {
        self.content = content
        self.originalContent = originalContent
        self.language = language
        self.searchText = searchText
        self.searchMatches = searchMatches
        self.theme = theme
        self.colorScheme = colorScheme
        self.isEditable = isEditable
        self.onSelectionChanged = onSelectionChanged
        self.onContentChanged = onContentChanged
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, originalContent: originalContent, onSelectionChanged: onSelectionChanged, onContentChanged: onContentChanged)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        // Configure text view
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = !isEditable  // Plain text for editing mode
        textView.allowsUndo = isEditable
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        
        // Set background
        textView.backgroundColor = NSColor(theme.background)
        textView.drawsBackground = true
        textView.insertionPointColor = NSColor(colorScheme == .dark ? .white : .black)
        
        // Set initial content
        if isEditable {
            textView.string = content
            applySimpleSyntaxHighlighting(to: textView)
        } else {
            let attributedString = buildAttributedContent()
            textView.textStorage?.setAttributedString(attributedString)
        }
        
        // Set delegate for selection and text changes
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        
        // Configure scroll view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        
        // Add line number ruler with diff indicators
        let lineNumberView = LineNumberRulerView(textView: textView, theme: theme, colorScheme: colorScheme, originalContent: originalContent)
        scrollView.verticalRulerView = lineNumberView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.lineNumberView = lineNumberView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        // Update editable state
        textView.isEditable = isEditable
        
        if isEditable {
            // For editable mode, set plain text content (no line numbers in content)
            if !context.coordinator.isEditing && textView.string != content {
                textView.string = content
                applySimpleSyntaxHighlighting(to: textView)
            }
        } else {
            // For read-only mode, build attributed string with line numbers
            let attributedString = buildAttributedContent()
            if textView.attributedString() != attributedString {
                textView.textStorage?.setAttributedString(attributedString)
            }
        }
        
        // Update background color
        textView.backgroundColor = NSColor(theme.background)
        
        // Update line number view
        if let lineNumberView = scrollView.verticalRulerView as? LineNumberRulerView {
            lineNumberView.updateTheme(theme: theme, colorScheme: colorScheme)
            lineNumberView.updateOriginalContent(originalContent)
        }
    }
    
    private func applySimpleSyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let syntaxTheme = colorScheme == .dark ? SyntaxTheme.dark : SyntaxTheme.light
        let plainColor = NSColor(syntaxTheme.plain)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttributes([
            .foregroundColor: plainColor,
            .font: font
        ], range: fullRange)
        
        if let lang = language?.lowercased() {
            applyKeywordHighlighting(to: textStorage, language: lang, theme: syntaxTheme)
        }
    }
    
    private func buildAttributedContent() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = content.components(separatedBy: .newlines)
        let highlighter = MultiLanguageHighlighter(colorScheme: colorScheme)
        
        let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineNumberColor = NSColor(theme.lineNumber)
        let plainColor = NSColor(colorScheme == .dark ? SyntaxTheme.dark.plain : SyntaxTheme.light.plain)
        
        for (index, line) in lines.enumerated() {
            // Line number
            let lineNumber = "\(index + 1)".padding(toLength: 5, withPad: " ", startingAt: 0)
            let lineNumberAttrs: [NSAttributedString.Key: Any] = [
                .font: lineNumberFont,
                .foregroundColor: lineNumberColor
            ]
            result.append(NSAttributedString(string: lineNumber + "  ", attributes: lineNumberAttrs))
            
            // Syntax highlighted code
            let highlightedLine = buildHighlightedLine(line, highlighter: highlighter, font: codeFont, plainColor: plainColor)
            result.append(highlightedLine)
            
            // Add newline (except for last line)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: codeFont, .foregroundColor: plainColor]))
            }
        }
        
        return result
    }
    
    private func buildHighlightedLine(_ line: String, highlighter: MultiLanguageHighlighter, font: NSFont, plainColor: NSColor) -> NSAttributedString {
        // Get SwiftUI Text and extract colors (simplified approach - just use plain color for now with keywords highlighted)
        let syntaxTheme = colorScheme == .dark ? SyntaxTheme.dark : SyntaxTheme.light
        let result = NSMutableAttributedString(string: line, attributes: [
            .font: font,
            .foregroundColor: plainColor
        ])
        
        // Apply simple keyword highlighting based on language
        if let lang = language?.lowercased() {
            applyKeywordHighlighting(to: result, language: lang, theme: syntaxTheme)
        }
        
        return result
    }
    
    private func applyKeywordHighlighting(to attributedString: NSMutableAttributedString, language: String, theme: SyntaxTheme) {
        let text = attributedString.string
        
        // Define keywords based on language
        let keywords: Set<String>
        switch language {
        case "swift":
            keywords = ["func", "var", "let", "class", "struct", "enum", "protocol", "import", "return", "if", "else", "for", "while", "guard", "switch", "case", "default", "break", "continue", "true", "false", "nil", "self", "Self", "init", "deinit", "public", "private", "internal", "fileprivate", "open", "static", "final", "override", "mutating", "throws", "throw", "try", "catch", "async", "await", "actor", "some", "any"]
        case "python":
            keywords = ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "as", "lambda", "True", "False", "None", "and", "or", "not", "in", "is", "pass", "break", "continue", "raise", "yield", "async", "await"]
        case "javascript", "typescript":
            keywords = ["function", "const", "let", "var", "class", "import", "export", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "true", "false", "null", "undefined", "this", "new", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof"]
        case "rust":
            keywords = ["fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "use", "mod", "pub", "return", "if", "else", "for", "while", "loop", "match", "true", "false", "self", "Self", "async", "await", "move", "ref", "where", "type", "dyn", "unsafe"]
        case "go":
            keywords = ["func", "var", "const", "type", "struct", "interface", "import", "package", "return", "if", "else", "for", "switch", "case", "default", "break", "continue", "true", "false", "nil", "go", "defer", "chan", "select", "range", "map"]
        default:
            keywords = []
        }
        
        let keywordColor = NSColor(theme.keyword)
        let stringColor = NSColor(theme.string)
        let commentColor = NSColor(theme.comment)
        let numberColor = NSColor(theme.number)
        
        // Highlight keywords
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    attributedString.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                }
            }
        }
        
        // Highlight strings (double quotes)
        if let regex = try? NSRegularExpression(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                attributedString.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }
        
        // Highlight single-quoted strings
        if let regex = try? NSRegularExpression(pattern: "'[^'\\\\]*(?:\\\\.[^'\\\\]*)*'") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                attributedString.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }
        
        // Highlight comments (// style)
        if let regex = try? NSRegularExpression(pattern: "//.*$", options: .anchorsMatchLines) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                attributedString.addAttribute(.foregroundColor, value: commentColor, range: match.range)
            }
        }
        
        // Highlight # comments (Python, shell)
        if language == "python" || language == "shell" || language == "bash" || language == "sh" {
            if let regex = try? NSRegularExpression(pattern: "#.*$", options: .anchorsMatchLines) {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    attributedString.addAttribute(.foregroundColor, value: commentColor, range: match.range)
                }
            }
        }
        
        // Highlight numbers
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                attributedString.addAttribute(.foregroundColor, value: numberColor, range: match.range)
            }
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var content: String
        var originalContent: String
        let onSelectionChanged: (String, (start: Int, end: Int)?) -> Void
        let onContentChanged: ((String) -> Void)?
        weak var textView: NSTextView?
        weak var lineNumberView: LineNumberRulerView?
        var isEditing = false
        
        init(content: String, originalContent: String, onSelectionChanged: @escaping (String, (start: Int, end: Int)?) -> Void, onContentChanged: ((String) -> Void)?) {
            self.content = content
            self.originalContent = originalContent
            self.onSelectionChanged = onSelectionChanged
            self.onContentChanged = onContentChanged
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            isEditing = true
            onContentChanged?(textView.string)
            isEditing = false
            
            // Update line numbers with diff
            lineNumberView?.updateCurrentContent(textView.string)
            lineNumberView?.needsDisplay = true
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            
            if selectedRange.length > 0 {
                let text = textView.string as NSString
                let selectedText = text.substring(with: selectedRange)
                
                // Calculate line range from position
                let fullText = textView.string
                let beforeSelection = String(fullText.prefix(selectedRange.location))
                let startLine = beforeSelection.components(separatedBy: .newlines).count
                var selectedLines = selectedText.components(separatedBy: .newlines).count
                // If selection ends with newline, the last component is empty - don't count it
                if selectedText.last?.isNewline == true {
                    selectedLines -= 1
                }
                let endLine = startLine + max(selectedLines, 1) - 1
                
                onSelectionChanged(selectedText, (start: startLine, end: endLine))
            } else {
                onSelectionChanged("", nil)
            }
        }
    }
}

// MARK: - Line Number Ruler View

/// A ruler view that displays line numbers with diff indicators
class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var theme: FileViewerTheme
    private var colorScheme: ColorScheme
    private var originalLines: [String] = []
    private var currentLines: [String] = []
    private var lineStates: [LineState] = []
    
    enum LineState {
        case unchanged
        case modified
        case added
        case deleted  // Shown as a marker between lines
    }
    
    init(textView: NSTextView, theme: FileViewerTheme, colorScheme: ColorScheme, originalContent: String) {
        self.textView = textView
        self.theme = theme
        self.colorScheme = colorScheme
        self.originalLines = originalContent.components(separatedBy: .newlines)
        self.currentLines = textView.string.components(separatedBy: .newlines)
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        
        self.clientView = textView
        self.ruleThickness = 50  // Wider for diff indicators
        
        computeLineStates()
        
        // Observe text changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateTheme(theme: FileViewerTheme, colorScheme: ColorScheme) {
        self.theme = theme
        self.colorScheme = colorScheme
        needsDisplay = true
    }
    
    func updateOriginalContent(_ content: String) {
        self.originalLines = content.components(separatedBy: .newlines)
        computeLineStates()
    }
    
    func updateCurrentContent(_ content: String) {
        self.currentLines = content.components(separatedBy: .newlines)
        computeLineStates()
    }
    
    private func computeLineStates() {
        // Simple diff: compare line by line
        lineStates = []
        
        let maxLines = max(originalLines.count, currentLines.count)
        
        for i in 0..<currentLines.count {
            if i >= originalLines.count {
                // New line added
                lineStates.append(.added)
            } else if currentLines[i] != originalLines[i] {
                // Line modified
                lineStates.append(.modified)
            } else {
                lineStates.append(.unchanged)
            }
        }
    }
    
    @objc private func textDidChange(_ notification: Notification) {
        if let textView = textView {
            updateCurrentContent(textView.string)
        }
        needsDisplay = true
    }
    
    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        
        // Draw background
        NSColor(theme.gutterBackground).setFill()
        rect.fill()
        
        // Draw separator line
        let separatorRect = NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)
        NSColor(theme.lineNumber).withAlphaComponent(0.3).setFill()
        separatorRect.fill()
        
        let content = textView.string
        guard !content.isEmpty else { return }
        
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(theme.lineNumber)
        ]
        
        // Get visible range
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        // Calculate starting line number
        let textBeforeVisible = String(content.prefix(charRange.location))
        var lineNumber = textBeforeVisible.components(separatedBy: .newlines).count
        
        // Colors for diff indicators
        let addedColor = NSColor.systemGreen
        let modifiedColor = NSColor.systemOrange
        let deletedColor = NSColor.systemRed
        
        // Draw line numbers
        var index = charRange.location
        while index <= min(charRange.location + charRange.length, content.count) {
            let lineRange: NSRange
            if index < content.count {
                lineRange = (content as NSString).lineRange(for: NSRange(location: index, length: 0))
            } else {
                break
            }
            
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height
            
            // Draw diff indicator
            let lineIndex = lineNumber - 1
            if lineIndex >= 0 && lineIndex < lineStates.count {
                let state = lineStates[lineIndex]
                if state != .unchanged {
                    let indicatorColor: NSColor
                    switch state {
                    case .added:
                        indicatorColor = addedColor
                    case .modified:
                        indicatorColor = modifiedColor
                    case .deleted:
                        indicatorColor = deletedColor
                    case .unchanged:
                        indicatorColor = .clear
                    }
                    
                    // Draw colored bar on the left edge
                    let indicatorRect = NSRect(x: 2, y: lineRect.origin.y, width: 3, height: lineRect.height)
                    indicatorColor.setFill()
                    indicatorRect.fill()
                }
            }
            
            // Draw line number
            let lineString = "\(lineNumber)"
            let size = lineString.size(withAttributes: attrs)
            let yPos = lineRect.origin.y + (lineRect.height - size.height) / 2
            let xPos = ruleThickness - size.width - 8
            
            lineString.draw(at: NSPoint(x: xPos, y: yPos), withAttributes: attrs)
            
            lineNumber += 1
            index = lineRange.location + lineRange.length
            
            // Safety check
            if index == lineRange.location { break }
        }
        
        // Show indicator if lines were deleted at the end
        if currentLines.count < originalLines.count {
            // Draw a red marker at the bottom to indicate deleted lines
            let deletedCount = originalLines.count - currentLines.count
            if deletedCount > 0 {
                let y = rect.maxY - 20
                let indicatorRect = NSRect(x: 2, y: y, width: 3, height: 2)
                deletedColor.setFill()
                indicatorRect.fill()
            }
        }
    }
}

// MARK: - Checkerboard Background (for transparent images)

struct CheckerboardBackground: View {
    let squareSize: CGFloat = 10
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let rows = Int(ceil(size.height / squareSize))
                let cols = Int(ceil(size.width / squareSize))
                
                for row in 0..<rows {
                    for col in 0..<cols {
                        let isLight = (row + col) % 2 == 0
                        let color = isLight ? Color(white: 0.9) : Color(white: 0.8)
                        let rect = CGRect(
                            x: CGFloat(col) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FileViewerTab_Previews: PreviewProvider {
    static var previews: some View {
        let tab = EditorTab(type: .file(path: "/Users/test/project/App.swift"))
        FileViewerTab(tab: tab) { content, path, lineRanges in
            print("Add to chat: \(path ?? "nil"), lines: \(lineRanges?.description ?? "all")")
        }
        .frame(width: 600, height: 400)
    }
}
#endif

