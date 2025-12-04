import SwiftUI
import AppKit

/// Chat tab content view without the header (since header is in container)
struct ChatTabContentView: View {
    @ObservedObject var session: ChatSession
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var isNearBottom: Bool = true
    @State private var userHasScrolledUp: Bool = false
    
    let tabIndex: Int
    @ObservedObject var ptyModel: PTYModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Per-chat agent controls bar
            AgentControlsBar(session: session)
            
            // Title generation error indicator
            if let error = session.titleGenerationError {
                ErrorBanner(message: "Title error: \(error)") {
                    session.titleGenerationError = nil
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            
            // Terminal context indicator
            if let ctx = session.pendingTerminalContext, !ctx.isEmpty {
                TerminalContextCard(context: ctx, meta: session.pendingTerminalMeta) {
                    session.clearPendingTerminalContext()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            
            // Attached files/contexts indicator
            if !session.pendingAttachedContexts.isEmpty {
                AttachedContextsBar(
                    contexts: session.pendingAttachedContexts,
                    onRemove: { id in session.removeAttachedContext(id: id) },
                    onUpdateLineRanges: { id, ranges in session.updateAttachedContextLineRanges(id: id, lineRanges: ranges) },
                    onClearAll: { session.clearAttachedContexts() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            
            // Messages with improved scroll behavior
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(session.messages) { msg in
                                ChatMessageBubble(
                                    message: msg,
                                    isStreaming: msg.id == session.streamingMessageId,
                                    ptyModel: ptyModel
                                )
                                .id(msg.id)
                            }
                            
                            // Bottom anchor for scroll detection
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onAppear { isNearBottom = true; userHasScrolledUp = false }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: session.messages) { _ in
                        // Only auto-scroll if user hasn't scrolled up
                        if !userHasScrolledUp && isNearBottom {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .simultaneousGesture(
                        DragGesture().onChanged { _ in
                            // User is scrolling - mark that they've scrolled up
                            if !isNearBottom {
                                userHasScrolledUp = true
                            }
                        }
                    )
                }
                
                // Scroll to bottom button (shows when scrolled up during streaming)
                if userHasScrolledUp && session.streamingMessageId != nil {
                    ScrollToBottomButton {
                        userHasScrolledUp = false
                        isNearBottom = true
                    }
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: userHasScrolledUp)
            
            // Modern input area
            ChatInputArea(
                messageText: $messageText,
                sending: sending,
                isStreaming: session.streamingMessageId != nil,
                isAgentRunning: session.isAgentRunning,
                cwd: effectiveCwd,
                gitInfo: ptyModel.gitInfo,
                session: session,
                onSend: send,
                onStop: { session.cancelStreaming() }
            )
        }
        .background(
            // Subtle gradient background
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.02),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            session.loadSettings()
            session.loadMessages()
            Task { await session.fetchOllamaModels() }
            // Initialize session CWD from terminal if not set
            if session.lastKnownCwd.isEmpty {
                session.lastKnownCwd = ptyModel.currentWorkingDirectory
            }
        }
        .onChange(of: ptyModel.currentWorkingDirectory) { newCwd in
            // Sync session CWD with terminal when not running agent
            // This allows the session to track user's manual cd commands
            if !session.isAgentRunning {
                session.lastKnownCwd = newCwd
            }
            // Index files for @ mention autocomplete
            if !newCwd.isEmpty {
                FilePickerService.shared.indexDirectory(newCwd)
            }
        }
        .onAppear {
            // Initialize file picker index on appear
            let cwd = ptyModel.currentWorkingDirectory
            if !cwd.isEmpty {
                FilePickerService.shared.indexDirectory(cwd)
            }
        }
    }
    
    /// The effective CWD to display - prefers session's tracked CWD, falls back to terminal
    private var effectiveCwd: String {
        if !session.lastKnownCwd.isEmpty {
            return session.lastKnownCwd
        }
        return ptyModel.currentWorkingDirectory
    }
    
    private func send() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        userHasScrolledUp = false  // Reset scroll state on new message
        
        // If agent is running, queue as feedback instead of starting new message
        if session.isAgentRunning {
            session.queueUserFeedback(text)
            return
        }
        
        // CRITICAL: Sync CWD from terminal before sending message
        // This ensures the agent has accurate context for decision-making
        if !ptyModel.currentWorkingDirectory.isEmpty {
            session.lastKnownCwd = ptyModel.currentWorkingDirectory
        }
        
        // Normal flow - start new message
        sending = true
        Task {
            await session.sendUserMessage(text)
            await MainActor.run {
                sending = false
            }
        }
    }
}

// MARK: - CWD Badge
private struct CwdBadge: View {
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
private struct GitInfoBadge: View {
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

// MARK: - Error Banner
private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Scroll to Bottom Button
private struct ScrollToBottomButton: View {
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text("New messages")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: isHovered ? 8 : 4, y: 2)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Chat Input Area
private struct ChatInputArea: View {
    @Binding var messageText: String
    let sending: Bool
    let isStreaming: Bool
    let isAgentRunning: Bool
    let cwd: String
    let gitInfo: GitInfo?
    @ObservedObject var session: ChatSession
    let onSend: () -> Void
    let onStop: () -> Void
    
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
                        .font(.system(size: 13))
                        .foregroundColor(isAgentRunning ? Color.blue.opacity(0.6) : .secondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
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
        .background(.ultraThinMaterial)
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
private struct ChatTextEditor: NSViewRepresentable {
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
        textView.font = NSFont.systemFont(ofSize: 13)
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
            .font: NSFont.systemFont(ofSize: 13),
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
                .font: NSFont.systemFont(ofSize: 13),
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
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
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
private class SubmitTextView: NSTextView {
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

// MARK: - Terminal Context Card
private struct TerminalContextCard: View {
    let context: String
    let meta: TerminalContextMeta?
    let onRemove: () -> Void
    
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Icon with glow effect
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 24, height: 24)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal Context")
                        .font(.caption)
                        .fontWeight(.semibold)
                    if let meta = meta, let cwd = meta.cwd, !cwd.isEmpty {
                        Text(cwd)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                Text(context)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.4), Color.orange.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Message Bubble
private struct ChatMessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let ptyModel: PTYModel
    
    @State private var isHovering = false
    @State private var showCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role label with modern styling
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.purple.opacity(0.15))
                        .frame(width: 22, height: 22)
                    Image(systemName: message.role == "user" ? "person.fill" : "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(message.role == "user" ? .accentColor : .purple)
                }
                
                Text(message.role == "user" ? "You" : "Assistant")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary.opacity(0.7))
            }
            
            // Terminal context badge for user messages
            if message.role == "user", let meta = message.terminalContextMeta {
                HStack(spacing: 6) {
                    Label("rows \(meta.startRow)-\(meta.endRow)", systemImage: "terminal")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.1))
                        )
                        .foregroundColor(.orange)
                    if let cwd = meta.cwd, !cwd.isEmpty {
                        Label(shortenPath(cwd), systemImage: "folder")
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.1))
                            )
                            .foregroundColor(.blue)
                    }
                }
            }
            
            // Attached files badges for user messages
            if message.role == "user", let contexts = message.attachedContexts, !contexts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(contexts) { context in
                            AttachedFileBadge(context: context)
                        }
                    }
                }
            }
            
            // Message content
            if let evt = message.agentEvent {
                AgentEventView(event: evt, ptyModel: ptyModel)
            } else {
                MessageContentWithMentions(
                    content: message.content,
                    attachedContexts: message.attachedContexts,
                    isUserMessage: message.role == "user"
                )
                .environmentObject(ptyModel)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                        Group {
                            if message.role == "user" {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.06)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            } else {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(.ultraThinMaterial)
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                message.role == "user" 
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.primary.opacity(0.06),
                                lineWidth: 1
                            )
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if isStreaming {
                            StreamingIndicator()
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if message.role != "user" && (isHovering || showCopied) && !isStreaming {
                            Button(action: copyRawContent) {
                                HStack(spacing: 4) {
                                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                    if showCopied {
                                        Text("Copied")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                }
                                .foregroundColor(showCopied ? .green : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Copy raw message")
                            .padding(8)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovering = hovering
                        }
                    }
            }
        }
    }
    
    private func copyRawContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopied = false
            }
        }
    }
    
    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Streaming Indicator
private struct StreamingIndicator: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                    .scaleEffect(dotScale(for: i))
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .onAppear { phase = 1 }
    }
    
    private func dotScale(for index: Int) -> CGFloat {
        phase > 0 ? 1.2 : 0.8
    }
}

// MARK: - Agent Event View
private struct AgentEventView: View {
    @State private var expanded: Bool = false
    @State private var showCopied: Bool = false
    @State private var showingDiffSheet: Bool = false
    let event: AgentEvent
    let ptyModel: PTYModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Icon
                ZStack {
                    Circle()
                        .fill(colorForKind.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: symbol(for: event.kind))
                        .font(.system(size: 10))
                        .foregroundColor(colorForKind)
                }
                
                Text(event.title)
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                // View Changes button (shown when there's a file change)
                if let fileChange = event.fileChange {
                    ViewChangesButton(fileChange: fileChange)
                }
                
                // Action buttons (shown when there's a command)
                if let cmd = event.command, !cmd.isEmpty {
                    HStack(spacing: 4) {
                        // Copy button
                        Button(action: { copyCommand(cmd) }) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(showCopied ? .green : .secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Copy command")
                        
                        // Re-run button
                        Button(action: { rerunCommand(cmd) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Re-run in terminal")
                    }
                }
                
                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // File change inline preview
                    if let fileChange = event.fileChange {
                        InlineDiffPreview(fileChange: fileChange, maxLines: 8)
                    }
                    
                    if let cmd = event.command, !cmd.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(cmd)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            // Inline action buttons
                            HStack(spacing: 8) {
                                Button(action: { copyCommand(cmd) }) {
                                    Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundColor(showCopied ? .green : .accentColor)
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { rerunCommand(cmd) }) {
                                    Label("Re-run", systemImage: "arrow.clockwise")
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                    
                    if let details = event.details, !details.isEmpty, event.fileChange == nil {
                        Text(details)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    
                    if let output = event.output, !output.isEmpty {
                        Divider()
                        ScrollView {
                            Text(output)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 40, maxHeight: 160)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(colorForKind.opacity(0.2), lineWidth: 1)
        )
        .onAppear { expanded = !(event.collapsed ?? true) }
    }
    
    private var colorForKind: Color {
        switch event.kind.lowercased() {
        case "status": return .blue
        case "step": return .green
        case "summary": return .purple
        case "file_change": return .orange
        default: return .gray
        }
    }
    
    private func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "status": return "bolt.fill"
        case "step": return "play.fill"
        case "summary": return "checkmark"
        case "file_change": return "doc.text.fill"
        default: return "info.circle"
        }
    }
    
    private func copyCommand(_ cmd: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        
        withAnimation {
            showCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopied = false
            }
        }
    }
    
    private func rerunCommand(_ cmd: String) {
        // Send command to terminal
        ptyModel.sendInput?(cmd + "\n")
    }
}

// MARK: - Progress Donut Chart

struct ProgressDonut: View {
    let completed: Int
    let total: Int
    let size: CGFloat
    let lineWidth: CGFloat
    
    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(Double(completed) / Double(total), 1.0)
    }
    
    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(
                    Color.secondary.opacity(0.2),
                    lineWidth: lineWidth
                )
            
            // Progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(0.7),
                            Color.blue,
                            Color.cyan.opacity(0.9)
                        ]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * progress)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Agent Mode Toggle

struct AgentModeToggle: View {
    @Binding var isEnabled: Bool
    @State private var isHovering: Bool = false
    
    private let activeColor = Color(red: 0.1, green: 0.85, blue: 0.65)  // Neon mint/cyan
    private let inactiveColor = Color.secondary.opacity(0.5)
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isEnabled.toggle()
            }
        }) {
            HStack(spacing: 4) {
                // Animated icon
                ZStack {
                    // Glow effect when active
                    if isEnabled {
                        Circle()
                            .fill(activeColor.opacity(0.35))
                            .frame(width: 14, height: 14)
                            .blur(radius: 3)
                    }
                    
                    // Icon background
                    Circle()
                        .fill(isEnabled ? activeColor : inactiveColor.opacity(0.3))
                        .frame(width: 12, height: 12)
                    
                    // Icon
                    Image(systemName: isEnabled ? "bolt.fill" : "bolt")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(isEnabled ? .black.opacity(0.8) : .secondary)
                        .scaleEffect(isEnabled ? 1.0 : 0.85)
                }
                .frame(width: 14, height: 14)
                
                // Label - matches .caption used in ChatTabPill
                Text("Agent")
                    .font(.caption)
                    .foregroundColor(isEnabled ? activeColor : .secondary)
                
                // Status indicator dot
                Circle()
                    .fill(isEnabled ? activeColor : inactiveColor)
                    .frame(width: 5, height: 5)
                    .opacity(isEnabled ? 1 : 0.5)
                    .scaleEffect(isEnabled ? 1 : 0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isEnabled 
                        ? activeColor.opacity(isHovering ? 0.2 : 0.15)
                        : Color.primary.opacity(isHovering ? 0.05 : 0)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isEnabled 
                            ? activeColor.opacity(isHovering ? 0.5 : 0.3)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isEnabled ? activeColor.opacity(0.2) : .clear,
                radius: isHovering ? 4 : 2,
                x: 0, y: 0
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - Agent Controls Bar (Per-Chat)

struct AgentControlsBar: View {
    @ObservedObject var session: ChatSession
    @State private var showingChecklistPopover: Bool = false
    @State private var isHoveringProgress: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            if session.isAgentRunning {
                // Show progress and stop button when agent is running
                HStack(spacing: 8) {
                    // Progress indicator - clickable to show checklist popover
                    Button(action: { showingChecklistPopover.toggle() }) {
                        HStack(spacing: 6) {
                            // Use unified step tracking from session (checklist when available, phase otherwise)
                            let totalSteps = session.agentEstimatedSteps
                            let completedSteps = session.agentChecklist?.completedCount ?? 0
                            
                            // Show donut chart when we have step info, otherwise show spinner
                            if totalSteps > 0 {
                                ProgressDonut(
                                    completed: completedSteps,
                                    total: totalSteps,
                                    size: 14,
                                    lineWidth: 2.5
                                )
                                
                                Text("\(completedSteps)/\(totalSteps)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                                
                                if session.agentCurrentStep > 0 {
                                    Text("Step \(session.agentCurrentStep)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if !session.agentPhase.isEmpty {
                                Text("·")
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text(session.agentPhase)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                            
                            // Chevron indicator for popover
                            if session.agentChecklist != nil {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isHoveringProgress ? Color.blue.opacity(0.18) : Color.blue.opacity(0.1))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isHoveringProgress ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringProgress = $0 }
                    .help("Click to view task checklist")
                    .popover(isPresented: $showingChecklistPopover, arrowEdge: .bottom) {
                        AgentChecklistPopover(
                            checklist: session.agentChecklist,
                            currentStep: session.agentCurrentStep,
                            estimatedSteps: session.agentEstimatedSteps,
                            phase: session.agentPhase
                        )
                    }
                    
                    // Stop button
                    Button(action: { session.cancelAgent() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text("Stop")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.15))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop agent execution")
                }
            } else {
                // Show agent toggle when not running
                AgentModeToggle(
                    isEnabled: Binding(
                        get: { session.agentModeEnabled },
                        set: { session.agentModeEnabled = $0; session.persistSettings() }
                    )
                )
                .help("When enabled, the assistant can run terminal commands automatically.")
            }
            
            Spacer()
            
            // Context usage indicator (per-chat) - always visible
            ContextUsageIndicator(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.5))
    }
}

// MARK: - File Mention Popover

/// Autocomplete popover for @ file mentions
private struct FileMentionPopover: View {
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
            .background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.95))
            
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
            .background(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
        }
        .frame(width: 320)
        .background(colorScheme == .dark ? Color(white: 0.1) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

// MARK: - File Mention Row

private struct FileMentionRow: View {
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
private struct AttachedContextsBar: View {
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
private struct AttachedContextChip: View {
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
private struct AttachedFileBadge: View {
    let context: PinnedContext
    
    @State private var showingViewer: Bool = false
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: { showingViewer = true }) {
            HStack(spacing: 4) {
                Image(systemName: context.icon)
                    .font(.system(size: 9))
                Text(context.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                if let range = context.lineRangeDescription {
                    Text("(\(range))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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

// MARK: - Message Content with Mentions

/// Renders message content with @filename mentions as clickable badges
private struct MessageContentWithMentions: View {
    let content: String
    let attachedContexts: [PinnedContext]?
    let isUserMessage: Bool
    
    @EnvironmentObject var ptyModel: PTYModel
    
    var body: some View {
        if isUserMessage, let contexts = attachedContexts, !contexts.isEmpty {
            // User message with attached files - render with inline mention badges
            MentionTextView(
                content: content,
                attachedContexts: contexts
            )
        } else {
            // Regular message - use markdown renderer
            MarkdownRenderer(text: content)
                .environmentObject(ptyModel)
        }
    }
}

// MARK: - Mention Text View

/// Renders text with @filename patterns as clickable badges
private struct MentionTextView: View {
    let content: String
    let attachedContexts: [PinnedContext]
    
    @State private var selectedContext: PinnedContext? = nil
    
    var body: some View {
        // Parse content and render with mention badges
        let segments = parseMentions(content)
        
        FlowLayout(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(.system(size: 13))
                case .mention(let filename):
                    InlineMentionBadge(
                        filename: filename,
                        context: findContext(for: filename),
                        onTap: { ctx in
                            selectedContext = ctx
                        }
                    )
                }
            }
        }
        .sheet(item: $selectedContext) { context in
            FileViewerSheet(context: context) {
                selectedContext = nil
            }
        }
    }
    
    /// Parse content into text and mention segments
    private func parseMentions(_ text: String) -> [MentionSegment] {
        var segments: [MentionSegment] = []
        var currentIndex = text.startIndex
        
        // Pattern to match @filename (alphanumeric, dots, underscores, hyphens)
        let pattern = "@([\\w\\-\\.]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(text)]
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in matches {
            let matchRange = Range(match.range, in: text)!
            let filenameRange = Range(match.range(at: 1), in: text)!
            
            // Add text before the match
            if currentIndex < matchRange.lowerBound {
                let textBefore = String(text[currentIndex..<matchRange.lowerBound])
                if !textBefore.isEmpty {
                    segments.append(.text(textBefore))
                }
            }
            
            // Add the mention
            let filename = String(text[filenameRange])
            segments.append(.mention(filename))
            
            currentIndex = matchRange.upperBound
        }
        
        // Add remaining text
        if currentIndex < text.endIndex {
            let remainingText = String(text[currentIndex...])
            if !remainingText.isEmpty {
                segments.append(.text(remainingText))
            }
        }
        
        return segments.isEmpty ? [.text(text)] : segments
    }
    
    /// Find the attached context that matches a filename
    private func findContext(for filename: String) -> PinnedContext? {
        attachedContexts.first { ctx in
            ctx.displayName == filename ||
            ctx.displayName.hasPrefix(filename) ||
            filename.hasPrefix(ctx.displayName.components(separatedBy: ".").first ?? "")
        }
    }
}

/// Segment type for mention parsing
private enum MentionSegment {
    case text(String)
    case mention(String)
}

// MARK: - Inline Mention Badge

/// Clickable badge for @filename in message text - matches AttachedFileBadge styling
private struct InlineMentionBadge: View {
    let filename: String
    let context: PinnedContext?
    let onTap: (PinnedContext) -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        if let ctx = context {
            Button(action: { onTap(ctx) }) {
                HStack(spacing: 4) {
                    Image(systemName: ctx.icon)
                        .font(.system(size: 9))
                    Text(ctx.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    if let range = ctx.lineRangeDescription {
                        Text("(\(range))")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor.opacity(0.7))
                    }
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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
            .help("Click to view \(ctx.displayName)")
        } else {
            // No matching context - show as plain text badge (still styled like attached badge)
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(filename)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - Flow Layout

/// A simple flow layout that wraps content to multiple lines
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> ArrangementResult {
        let maxWidth = proposal.width ?? .infinity
        
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            
            // Check if we need to wrap to next line
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineWidth = max(maxLineWidth, currentX - spacing)
        }
        
        totalHeight = currentY + lineHeight
        
        return ArrangementResult(
            positions: positions,
            sizes: sizes,
            size: CGSize(width: maxLineWidth, height: totalHeight)
        )
    }
    
    private struct ArrangementResult {
        var positions: [CGPoint]
        var sizes: [CGSize]
        var size: CGSize
    }
}

