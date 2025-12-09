import SwiftUI
import AppKit
import TermAIModels

// MARK: - CWD Badge

struct CwdBadge: View {
    let path: String
    let displayPath: String
    
    @State private var isHovered: Bool = false
    @State private var showCopied: Bool = false
    
    var body: some View {
        Button(action: copyPath) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                Text(showCopied ? "Copied!" : displayPath)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundColor(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(path)  // Shows full path tooltip on hover (after ~1s)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: showCopied)
    }
    
    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

// MARK: - Git Info Badge

struct GitInfoBadge: View {
    let gitInfo: GitInfo
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 4) {
            // Branch icon and name
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text(gitInfo.branch)
                    .lineLimit(1)
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            
            // Dirty indicator
            if gitInfo.isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .help("Uncommitted changes")
            }
            
            // Ahead/behind counts
            if gitInfo.hasUpstreamDelta {
                HStack(spacing: 2) {
                    if gitInfo.ahead > 0 {
                        HStack(spacing: 1) {
                            Text("↑")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(gitInfo.ahead)")
                        }
                        .foregroundColor(.green)
                        .help("\(gitInfo.ahead) commit(s) ahead of upstream")
                    }
                    if gitInfo.behind > 0 {
                        HStack(spacing: 1) {
                            Text("↓")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(gitInfo.behind)")
                        }
                        .foregroundColor(.red)
                        .help("\(gitInfo.behind) commit(s) behind upstream")
                    }
                }
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Chat Input Area

struct ChatInputArea: View {
    @Binding var messageText: String
    let sending: Bool
    let isStreaming: Bool
    let isAgentRunning: Bool
    let cwd: String
    let gitInfo: GitInfo?
    @ObservedObject var session: ChatSession
    let onSend: () -> Void
    let onStop: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFocused: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var fileQuery: String = ""
    @State private var mentionStartIndex: String.Index? = nil
    @StateObject private var filePicker = FilePickerService.shared
    
    /// Input should only be disabled during the brief sending moment, not during agent execution
    private var isInputDisabled: Bool {
        sending && !isAgentRunning
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Text input with modern styling
            ZStack(alignment: .topLeading) {
                if messageText.isEmpty {
                    Text(isAgentRunning ? "Add feedback for the agent..." : "Type @ to attach files, then your message...")
                        .font(.system(size: 11.5))
                        .foregroundColor(isAgentRunning ? Color.blue.opacity(0.6) : .secondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                
                ChatTextEditor(
                    text: $messageText,
                    isFocused: $isFocused,
                    isDisabled: isInputDisabled,
                    onMentionTrigger: { triggered in
                        if triggered {
                            showFilePicker = true
                            fileQuery = ""
                            mentionStartIndex = messageText.endIndex
                        }
                    },
                    onSubmit: {
                        if !isInputDisabled && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }
                )
                .frame(minHeight: 60, maxHeight: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isAgentRunning
                            ? Color.blue.opacity(isFocused ? 0.6 : 0.3)
                            : (isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .popover(isPresented: $showFilePicker, arrowEdge: .top) {
                FileMentionPopover(
                    query: $fileQuery,
                    files: filePicker.search(query: fileQueryWithoutRanges),
                    isLoading: filePicker.isIndexing,
                    onSelect: { file in
                        attachFile(file)
                        showFilePicker = false
                    },
                    onDismiss: {
                        showFilePicker = false
                        // Remove the @ from the message if user cancelled without selecting
                        if let startIdx = mentionStartIndex,
                           startIdx <= messageText.endIndex,
                           messageText.index(before: startIdx) >= messageText.startIndex {
                            let atIndex = messageText.index(before: startIdx)
                            if atIndex < messageText.endIndex && messageText[atIndex] == "@" {
                                // Only remove if nothing was typed after @
                                let afterAt = String(messageText[startIdx...]).trimmingCharacters(in: .whitespaces)
                                if afterAt.isEmpty {
                                    messageText.remove(at: atIndex)
                                }
                            }
                        }
                    }
                )
            }
            .onChange(of: messageText) { newValue in
                // Update file query when typing after @
                if showFilePicker, let startIdx = mentionStartIndex {
                    if startIdx <= newValue.endIndex {
                        fileQuery = String(newValue[startIdx...])
                        // Close picker if user deleted the @
                        if let atIdx = newValue.index(startIdx, offsetBy: -1, limitedBy: newValue.startIndex),
                           atIdx >= newValue.startIndex,
                           atIdx < newValue.endIndex {
                            if newValue[atIdx] != "@" {
                                showFilePicker = false
                            }
                        } else if startIdx > newValue.endIndex {
                            showFilePicker = false
                        }
                    } else {
                        showFilePicker = false
                    }
                }
            }
            // Bottom bar with CWD, git info, stop button, and send button
            HStack(spacing: 8) {
                // Current working directory with hover tooltip
                if !cwd.isEmpty {
                    CwdBadge(path: cwd, displayPath: displayPath(cwd))
                }
                
                // Git info badge (synced with session directory)
                if let gitInfo = gitInfo {
                    GitInfoBadge(gitInfo: gitInfo)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                
                Spacer()
                
                // Keyboard hint - shows feedback mode when agent is running
                Text(isAgentRunning ? "⏎ send feedback · ⇧⏎ newline" : "⏎ send · ⇧⏎ newline")
                    .font(.caption2)
                    .foregroundColor(isAgentRunning ? .blue.opacity(0.6) : .secondary.opacity(0.5))
                
                // Stop button (visible during streaming)
                if isStreaming {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.red.opacity(0.9))
                            )
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Stop generation (Esc)")
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Send button
                Button(action: onSend) {
                    Group {
                        if isInputDisabled && !isStreaming {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: isAgentRunning ? "arrow.up.message" : "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(
                                messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInputDisabled
                                    ? Color.secondary.opacity(0.3)
                                    : Color.accentColor
                            )
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(isInputDisabled || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .animation(.easeInOut(duration: 0.15), value: messageText.isEmpty)
            }
            .animation(.easeInOut(duration: 0.2), value: isStreaming)
            .animation(.easeInOut(duration: 0.2), value: gitInfo?.branch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)  // #282c34
            : Color(red: 0.98, green: 0.98, blue: 0.98)) // #fafafa
    }
    
    /// Attach a file to the pending context
    /// Supports line range syntax in fileQuery: "filename:10-50" or "filename:10-50,80-100"
    /// Line ranges can be edited later through the attached file viewer
    private func attachFile(_ file: FileEntry) {
        // Check if there's a line range specification in the query
        let lineRanges = parseLineRangesFromQuery()
        
        // Always just show @filename in the text (line ranges managed via attached badge)
        if let startIdx = mentionStartIndex,
           let atIdx = messageText.index(startIdx, offsetBy: -1, limitedBy: messageText.startIndex),
           atIdx >= messageText.startIndex {
            messageText.replaceSubrange(atIdx..<messageText.endIndex, with: "@\(file.name) ")
        }
        
        if !lineRanges.isEmpty {
            // Read file with specific line ranges
            guard let result = filePicker.readFileWithRanges(at: file.path, ranges: lineRanges) else { return }
            session.attachFileWithRanges(path: file.path, selectedContent: result.selected, fullContent: result.full, lineRanges: lineRanges)
        } else {
            // No line ranges - attach entire file (but store full content for later range editing)
            guard let content = filePicker.readFile(at: file.path) else { return }
            // Store with fullContent so line ranges can be edited later
            session.attachFileWithRanges(path: file.path, selectedContent: content, fullContent: content, lineRanges: [])
        }
    }
    
    /// Get the file query without the line range specification (for file search)
    private var fileQueryWithoutRanges: String {
        guard let colonIndex = fileQuery.lastIndex(of: ":") else { return fileQuery }
        // Check if what follows the colon looks like a line range (starts with a digit)
        let afterColon = fileQuery[fileQuery.index(after: colonIndex)...]
        if let firstChar = afterColon.first, firstChar.isNumber {
            return String(fileQuery[..<colonIndex])
        }
        return fileQuery
    }
    
    /// Parse line ranges from the current file query (e.g., "file:10-50,80-100")
    private func parseLineRangesFromQuery() -> [LineRange] {
        // Check if query contains a colon followed by line numbers
        guard let colonIndex = fileQuery.lastIndex(of: ":") else { return [] }
        
        let afterColon = fileQuery[fileQuery.index(after: colonIndex)...]
        // Verify it looks like a line range (starts with a digit)
        guard let firstChar = afterColon.first, firstChar.isNumber else { return [] }
        
        let rangeStr = String(afterColon)
        return LineRange.parseMultiple(rangeStr)
    }
    
    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    /// Display path with smart truncation - shows last directory component with ellipsis prefix if long
    private func displayPath(_ path: String) -> String {
        // Remove trailing slash (from tab completion) before processing
        let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let shortened = shortenPath(trimmedPath)
        let maxLength = 35
        
        if shortened.count <= maxLength {
            return shortened
        }
        
        // Show ellipsis + last portion of path
        // Filter out empty components (handles paths with trailing slashes)
        let components = shortened.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count > 1 {
            // Try to show last 2 components
            let lastTwo = components.suffix(2).joined(separator: "/")
            if lastTwo.count <= maxLength - 3 {
                return "…/" + lastTwo
            }
            // Otherwise just show last component
            if let last = components.last {
                if last.count <= maxLength - 3 {
                    return "…/" + last
                }
                // Truncate even the last component if too long
                return "…/" + String(last.prefix(maxLength - 4)) + "…"
            }
        } else if let single = components.first {
            // Single component (like "~" or root directory name)
            if single.count <= maxLength {
                return single
            }
            return String(single.prefix(maxLength - 1)) + "…"
        }
        
        // Fallback: truncate with ellipsis
        return String(shortened.prefix(maxLength - 1)) + "…"
    }
}

// MARK: - Custom Text Editor with Enter/Shift+Enter handling and @mention styling

struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isDisabled: Bool
    var onMentionTrigger: ((Bool) -> Void)? = nil
    let onSubmit: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onMentionTrigger = onMentionTrigger
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 11.5)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        
        // Set default typing attributes
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.labelColor
        ]
        
        scrollView.documentView = textView
        context.coordinator.textView = textView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            context.coordinator.applyMentionStyling(to: textView)
            // Restore cursor position
            if selectedRange.location <= textView.string.count {
                textView.setSelectedRange(selectedRange)
            }
        }
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.onSubmit = onSubmit
        textView.onMentionTrigger = onMentionTrigger
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        weak var textView: NSTextView?
        private var isApplyingStyling = false
        
        init(_ parent: ChatTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Update the binding first
            parent.text = textView.string
            
            // Apply mention styling
            if !isApplyingStyling {
                applyMentionStyling(to: textView)
            }
        }
        
        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }
        
        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }
        
        /// Apply badge-like styling to @filename mentions (visual only, not clickable)
        func applyMentionStyling(to textView: NSTextView) {
            isApplyingStyling = true
            defer { isApplyingStyling = false }
            
            let text = textView.string
            guard !text.isEmpty else { return }
            
            // Save cursor position
            let selectedRange = textView.selectedRange()
            
            // Create attributed string with default styling
            let attributedString = NSMutableAttributedString(string: text)
            let defaultAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.labelColor
            ]
            attributedString.addAttributes(defaultAttrs, range: NSRange(location: 0, length: text.count))
            
            // Pattern for @mentions: @filename.ext (line ranges are managed via attached badge, not in text)
            let pattern = "@[\\w\\-\\.]+"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
                
                for match in matches {
                    // Apply badge-like styling (visual only)
                    let mentionAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                        .foregroundColor: NSColor.controlAccentColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.15)
                    ]
                    attributedString.addAttributes(mentionAttrs, range: match.range)
                }
            }
            
            // Apply the attributed string
            textView.textStorage?.setAttributedString(attributedString)
            
            // Restore cursor position
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
            
            // Ensure typing attributes are reset for new input
            textView.typingAttributes = defaultAttrs
        }
    }
}

// Custom NSTextView that handles Enter vs Shift+Enter and @ mentions
class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onMentionTrigger: ((Bool) -> Void)?
    
    override func keyDown(with event: NSEvent) {
        // Check for Enter key (keyCode 36)
        if event.keyCode == 36 {
            // If Shift is NOT held, submit
            if !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            // Shift+Enter: insert newline (default behavior)
        }
        super.keyDown(with: event)
    }
    
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        
        // Check if @ was typed
        if let str = string as? String, str == "@" {
            onMentionTrigger?(true)
        }
    }
}

// MARK: - File Mention Popover

/// Autocomplete popover for @ file mentions
struct FileMentionPopover: View {
    @Binding var query: String
    let files: [FileEntry]
    let isLoading: Bool
    let onSelect: (FileEntry) -> Void
    let onDismiss: () -> Void
    
    @State private var selectedIndex: Int = 0
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.accentColor)
                Text("Attach File")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(colorScheme == .dark
                ? Color(red: 0.17, green: 0.19, blue: 0.23)  // #2c313a Atom One Dark elevated
                : Color(red: 0.94, green: 0.94, blue: 0.94)) // #f0f0f0 Atom One Light
            
            Divider()
            
            // File list
            if files.isEmpty {
                if query.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Type to search files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("e.g., main.swift or src/utils")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No matching files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                            FileMentionRow(
                                file: file,
                                isSelected: index == selectedIndex,
                                onSelect: { onSelect(file) }
                            )
                            .onHover { hovering in
                                if hovering {
                                    selectedIndex = index
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 250)
            }
            
            // Hint
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                    Text("navigate")
                        .font(.caption2)
                }
                .foregroundColor(.secondary.opacity(0.7))
                
                HStack(spacing: 4) {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                    Text("select")
                        .font(.caption2)
                }
                .foregroundColor(.secondary.opacity(0.7))
                
                HStack(spacing: 4) {
                    Text("esc")
                        .font(.caption2)
                    Text("cancel")
                        .font(.caption2)
                }
                .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(colorScheme == .dark
                ? Color(red: 0.13, green: 0.15, blue: 0.17)  // #21252b Atom One Dark secondary
                : Color(red: 0.90, green: 0.90, blue: 0.90)) // #e5e5e6 Atom One Light
        }
        .frame(width: 320)
        .background(colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)  // #282c34 Atom One Dark
            : Color(red: 0.98, green: 0.98, blue: 0.98)) // #fafafa Atom One Light
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

// MARK: - File Mention Row

struct FileMentionRow: View {
    let file: FileEntry
    let isSelected: Bool
    let onSelect: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // File icon
                Image(systemName: file.icon)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20)
                
                // File info
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(file.relativePath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                // Language badge
                if let lang = file.language {
                    Text(lang)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.1))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Attached Contexts Bar

/// Horizontal scrolling bar showing attached files/contexts
struct AttachedContextsBar: View {
    let contexts: [PinnedContext]
    let onRemove: (UUID) -> Void
    let onUpdateLineRanges: (UUID, [LineRange]) -> Void
    let onClearAll: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Label
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text("Attached (\(contexts.count))")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundColor(.secondary)
                
                // Scrollable chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(contexts) { context in
                            AttachedContextChip(
                                context: context,
                                onRemove: { onRemove(context.id) },
                                onUpdateLineRanges: { ranges in onUpdateLineRanges(context.id, ranges) }
                            )
                        }
                    }
                }
                
                Spacer()
                
                // Clear all button
                if contexts.count > 1 {
                    Button(action: onClearAll) {
                        Text("Clear all")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - Attached Context Chip

/// Compact chip showing an attached file/context - clickable to edit line ranges
struct AttachedContextChip: View {
    let context: PinnedContext
    let onRemove: () -> Void
    let onUpdateLineRanges: ([LineRange]) -> Void
    
    @State private var isHovered: Bool = false
    @State private var showingEditor: Bool = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        HStack(spacing: 4) {
            // Icon
            Image(systemName: context.icon)
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            
            // Name
            Text(context.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            
            // Line range if applicable
            if let range = context.lineRangeDescription {
                Text("(\(range))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            // Large content indicator
            if context.isLargeContent {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .help("Large file - will be summarized")
            }
            
            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isHovered ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.1))
        )
        .overlay(
            Capsule()
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onTapGesture {
            showingEditor = true
        }
        .sheet(isPresented: $showingEditor) {
            FileViewerSheet(
                context: context,
                onDismiss: { showingEditor = false },
                onUpdateLineRanges: { ranges in
                    onUpdateLineRanges(ranges)
                    showingEditor = false
                }
            )
        }
        .help("Click to edit line selection for \(context.displayName)")
    }
}

// MARK: - Attached File Badge (for message history)

/// Badge shown in message history for attached files
struct AttachedFileBadge: View {
    let context: PinnedContext
    
    @State private var showingViewer: Bool = false
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: { showingViewer = true }) {
            HStack(spacing: 3) {
                Image(systemName: context.icon)
                    .font(.system(size: 8))
                Text(context.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                if let range = context.lineRangeDescription {
                    Text("(\(range))")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Click to view \(context.displayName)")
        .sheet(isPresented: $showingViewer) {
            FileViewerSheet(context: context) {
                showingViewer = false
            }
        }
    }
}
