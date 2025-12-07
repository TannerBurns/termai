import SwiftUI
import AppKit

/// Represents a message or group of tool events for rendering
private enum GroupedMessage: Identifiable {
    case single(index: Int, message: ChatMessage)
    case toolGroup(messages: [(Int, ChatMessage)])
    
    var id: String {
        switch self {
        case .single(_, let msg): return msg.id.uuidString
        case .toolGroup(let msgs): return "group-\(msgs.first?.1.id.uuidString ?? "")"
        }
    }
}

/// Chat tab content view without the header (since header is in container)
struct ChatTabContentView: View {
    @ObservedObject var session: ChatSession
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var isNearBottom: Bool = true
    @State private var userHasScrolledUp: Bool = false
    
    let tabIndex: Int
    @ObservedObject var ptyModel: PTYModel
    
    /// Groups consecutive groupable events (tools, profile changes, commands, etc.) into single grouped items for compact display
    /// Also filters out internal events unless verbose mode is enabled
    private var groupedMessages: [GroupedMessage] {
        let showVerbose = AgentSettings.shared.showVerboseAgentEvents
        var result: [GroupedMessage] = []
        var currentGroup: [(Int, ChatMessage)] = []
        
        /// Check if an event is groupable (tools, profile changes, commands, and other categorized events)
        /// Pending approvals are NOT groupable - they need to be visible for user interaction
        func isGroupable(_ event: AgentEvent) -> Bool {
            // Pending approvals must stay visible for user interaction
            if event.pendingApprovalId != nil {
                return false
            }
            // Events with a category are groupable (once resolved)
            if event.eventCategory != nil {
                return true
            }
            // Legacy: tool events without explicit category
            if event.toolCallId != nil {
                return true
            }
            return false
        }
        
        for (index, msg) in session.messages.enumerated() {
            // Skip internal events unless verbose mode is on
            if let event = msg.agentEvent, event.isInternal == true, !showVerbose {
                continue
            }
            
            // Check if this event should be grouped
            if let event = msg.agentEvent, isGroupable(event) {
                currentGroup.append((index, msg))
            } else {
                // Flush any accumulated group
                if !currentGroup.isEmpty {
                    if currentGroup.count >= 2 {
                        // Only group if we have 2+ consecutive events
                        result.append(.toolGroup(messages: currentGroup))
                    } else {
                        // Single event - render normally
                        for (idx, m) in currentGroup {
                            result.append(.single(index: idx, message: m))
                        }
                    }
                    currentGroup = []
                }
                result.append(.single(index: index, message: msg))
            }
        }
        
        // Don't forget the final group
        if !currentGroup.isEmpty {
            if currentGroup.count >= 2 {
                result.append(.toolGroup(messages: currentGroup))
            } else {
                for (idx, m) in currentGroup {
                    result.append(.single(index: idx, message: m))
                }
            }
        }
        
        return result
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Per-chat agent controls bar
            AgentControlsBar(session: session)
            
            // Title generation error indicator
            if let error = session.titleGenerationError {
                ErrorBanner(
                    message: error.friendlyMessage,
                    fullDetails: error.fullDetails
                ) {
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
                            ForEach(Array(groupedMessages.enumerated()), id: \.element.id) { _, item in
                                switch item {
                                case .single(let index, let msg):
                                    ChatMessageBubble(
                                        message: msg,
                                        messageIndex: index,
                                        isStreaming: msg.id == session.streamingMessageId,
                                        checkpoint: session.checkpoint(forMessageIndex: index),
                                        ptyModel: ptyModel,
                                        session: session
                                    )
                                    .id(msg.id)
                                case .toolGroup(let messages):
                                    AgentEventGroupView(
                                        events: messages.compactMap { $0.1.agentEvent },
                                        ptyModel: ptyModel
                                    )
                                    .id("tool-group-\(messages.first?.1.id.uuidString ?? UUID().uuidString)")
                                }
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
        .onReceive(NotificationCenter.default.publisher(for: .TermAICWDUpdated)) { note in
            // Always sync CWD after every command (user or agent)
            // This ensures the session has accurate directory context
            if let cwd = note.userInfo?["cwd"] as? String, !cwd.isEmpty {
                session.lastKnownCwd = cwd
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
    var fullDetails: String? = nil
    let onDismiss: () -> Void
    
    @State private var isExpanded: Bool = false
    @State private var showCopied: Bool = false
    
    private var hasExpandableDetails: Bool {
        fullDetails != nil && fullDetails != message
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main error banner - entire area is clickable if expandable
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(isExpanded ? nil : 2)
                Spacer()
                
                // Show details button (only if there are full details)
                if hasExpandableDetails {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide" : "Details")
                            .font(.caption2)
                            .fontWeight(.medium)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                }
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasExpandableDetails {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }
            
            // Expanded details section
            if isExpanded, let details = fullDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Full Error Details")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(details, forType: .string)
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopied = false
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                    Text(showCopied ? "Copied!" : "Copy")
                                        .font(.caption2)
                                }
                                .foregroundColor(showCopied ? .green : .accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        ScrollView {
                            Text(details)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.7))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
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
    
    /// Whether this is a file context (vs terminal output)
    private var isFileContext: Bool {
        meta?.filePath != nil
    }
    
    private var displayTitle: String {
        if let filePath = meta?.filePath {
            return (filePath as NSString).lastPathComponent
        }
        return "Terminal Context"
    }
    
    private var displaySubtitle: String? {
        if let filePath = meta?.filePath {
            return shortenPath(filePath)
        }
        return meta?.cwd.flatMap { shortenPath($0) }
    }
    
    private var iconName: String {
        isFileContext ? "doc.text.fill" : "terminal.fill"
    }
    
    private var accentColor: Color {
        isFileContext ? .blue : .orange
    }
    
    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Icon with glow effect
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.2))
                        .frame(width: 24, height: 24)
                    Image(systemName: iconName)
                        .font(.system(size: 10))
                        .foregroundColor(accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                    if let subtitle = displaySubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                // Line count badge for files
                if isFileContext {
                    let lineCount = context.components(separatedBy: .newlines).count
                    Text("\(lineCount) lines")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                
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
                        colors: [accentColor.opacity(0.4), accentColor.opacity(0.1)],
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
    let messageIndex: Int
    let isStreaming: Bool
    let checkpoint: Checkpoint?
    let ptyModel: PTYModel
    @ObservedObject var session: ChatSession
    
    @State private var isHovering = false
    @State private var showCopied = false
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var showRollbackChoice = false
    
    /// Compact timestamp formatter showing date and time
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm a"  // e.g., "Dec 6 3:35 PM"
        formatter.timeZone = .current
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Role label with modern styling
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.purple.opacity(0.15))
                        .frame(width: 18, height: 18)
                    Image(systemName: message.role == "user" ? "person.fill" : "sparkles")
                        .font(.system(size: 8))
                        .foregroundColor(message.role == "user" ? .accentColor : .purple)
                }
                
                Text(message.role == "user" ? "You" : "Assistant")
                    .font(.system(size: 11))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary.opacity(0.7))

                // Checkpoint indicator for user messages with changes
                if message.role == "user", let cp = checkpoint, cp.hasChanges {
                    CheckpointBadge(checkpoint: cp)
                }

                Spacer()
                
                // Compact timezone-aware timestamp
                Text(message.timestamp, formatter: ChatMessageBubble.timestampFormatter)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary.opacity(0.5))
                    .monospacedDigit()
            }
            
            // Terminal context badge for user messages
            if message.role == "user", let meta = message.terminalContextMeta {
                HStack(spacing: 4) {
                    Label("rows \(meta.startRow)-\(meta.endRow)", systemImage: "terminal")
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.1))
                        )
                        .foregroundColor(.orange)
                    if let cwd = meta.cwd, !cwd.isEmpty {
                        Label(shortenPath(cwd), systemImage: "folder")
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
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
                    HStack(spacing: 4) {
                        ForEach(contexts) { context in
                            AttachedFileBadge(context: context)
                        }
                    }
                }
            }
            
            // Message content - either editing mode or display mode
            if let evt = message.agentEvent {
                // Special handling for plan_created events - show PlanReadyView
                if evt.kind == "plan_created", let planId = evt.planId {
                    PlanReadyView(
                        planId: planId,
                        planTitle: evt.title,
                        session: session,
                        onOpenPlan: { id in
                            // Post notification to open plan in editor
                            NotificationCenter.default.post(
                                name: .TermAIOpenPlanInEditor,
                                object: nil,
                                userInfo: ["planId": id]
                            )
                        }
                    )
                } else {
                    AgentEventView(event: evt, ptyModel: ptyModel)
                }
            } else if isEditing {
                // Inline editing mode with orange/amber tint (distinct edit indicator)
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $editedText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 200)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                        )
                    
                    HStack(spacing: 10) {
                        // Cancel button - red X
                        Button {
                            cancelEditing()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle()
                                        .fill(Color.red.opacity(0.9))
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel editing")
                        
                        Spacer()
                        
                        if let cp = checkpoint, cp.hasChanges {
                            Text("\(cp.modifiedFileCount) file(s) changed")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        
                        // Send button - blue arrow (matching main input)
                        Button {
                            submitEdit()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle()
                                        .fill(
                                            editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? Color.secondary.opacity(0.3)
                                                : Color.accentColor
                                        )
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send edited message")
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.12), Color.orange.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
            } else {
                // Normal display mode
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
                    .overlay(alignment: .bottomTrailing) {
                        // Edit button for user messages (inside bubble, bottom-right)
                        if message.role == "user" && isHovering && !isStreaming && !session.isAgentRunning {
                            Button {
                                startEditing()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(6)
                                    .background(
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Edit this message")
                            .padding(8)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
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
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            // Standard copy option
            if !message.content.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
            }
            
            // Edit option for user messages
            if message.role == "user" && !session.isAgentRunning {
                Button {
                    startEditing()
                } label: {
                    Label("Edit Message", systemImage: "pencil")
                }
            }
        }
        .popover(isPresented: $showRollbackChoice) {
            if let cp = checkpoint {
                RollbackChoicePopover(
                    checkpoint: cp,
                    session: session,
                    editedMessage: editedText,
                    isPresented: $showRollbackChoice,
                    onComplete: {
                        isEditing = false
                    }
                )
            }
        }
    }
    
    private func startEditing() {
        editedText = message.content
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = true
        }
    }
    
    private func cancelEditing() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = false
            editedText = ""
        }
    }
    
    private func submitEdit() {
        let trimmedMessage = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        
        // Check if there's a checkpoint with changes
        if let cp = checkpoint, cp.hasChanges {
            // Show rollback choice popover
            showRollbackChoice = true
        } else {
            // No checkpoint or no changes - just branch and send
            session.branchFromCheckpoint(
                Checkpoint(messageIndex: messageIndex, messagePreview: ""),
                newPrompt: ""
            )
            Task {
                await session.sendUserMessage(trimmedMessage)
            }
            isEditing = false
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
    @State private var approvalHandled: Bool = false
    let event: AgentEvent
    let ptyModel: PTYModel
    
    /// Check if this event has a pending approval that hasn't been handled
    private var hasPendingApproval: Bool {
        event.pendingApprovalId != nil && !approvalHandled
    }
    
    /// Check if this is a tool event with status
    private var isToolEvent: Bool {
        event.toolCallId != nil
    }
    
    /// Get the effective color based on tool status
    private var effectiveColor: Color {
        if let status = event.toolStatus {
            switch status {
            case "running": return .blue
            case "succeeded": return .green
            case "failed": return .red
            default: return colorForKind
            }
        }
        return colorForKind
    }
    
    /// Get the icon for tool status
    private var toolStatusIcon: String {
        if let status = event.toolStatus {
            switch status {
            case "running": return "arrow.triangle.2.circlepath"
            case "succeeded": return "checkmark"
            case "failed": return "xmark"
            default: return symbol(for: event.kind)
            }
        }
        return symbol(for: event.kind)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Icon - shows spinner for running tools, checkmark/X for completed
                ZStack {
                    Circle()
                        .fill(effectiveColor.opacity(0.15))
                        .frame(width: 24, height: 24)
                    
                    if isToolEvent && event.toolStatus == "running" {
                        // Spinning indicator for running tools
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: isToolEvent ? toolStatusIcon : symbol(for: event.kind))
                            .font(.system(size: 10, weight: isToolEvent ? .bold : .regular))
                            .foregroundColor(effectiveColor)
                    }
                }
                
                // Compact title for tool events
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(isToolEvent && event.toolStatus == "failed" ? .red : .primary)
                    
                    // Compact inline summary when collapsed
                    if !expanded {
                        if let fileChange = event.fileChange {
                            Text(fileChange.fileName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else if let cmd = event.command, !cmd.isEmpty {
                            Text(String(cmd.prefix(40)) + (cmd.count > 40 ? "..." : ""))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                // Inline approval buttons (shown for pending approvals)
                if hasPendingApproval, let approvalId = event.pendingApprovalId {
                    HStack(spacing: 8) {
                        // View Changes button (opens modal with approve/reject)
                        if let fileChange = event.fileChange {
                            ViewChangesButton(
                                fileChange: fileChange,
                                pendingApprovalId: approvalId,
                                toolName: event.pendingToolName,
                                onApprovalHandled: { approvalHandled = true }
                            )
                        }
                        
                        // Reject button (X)
                        Button(action: { rejectApproval(approvalId) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.red))
                        }
                        .buttonStyle(.plain)
                        .help("Reject")
                        
                        // Approve button (checkmark)
                        Button(action: { approveApproval(approvalId) }) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.green))
                        }
                        .buttonStyle(.plain)
                        .help("Approve")
                    }
                } else {
                    // View Changes button (shown when there's a file change but not pending)
                    if let fileChange = event.fileChange {
                        ViewChangesButton(fileChange: fileChange)
                    }
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
                        // Truncate details to 150 chars for compactness
                        let truncatedDetails = details.count > 150 ? String(details.prefix(150)) + "..." : details
                        Text(truncatedDetails)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    
                    if let output = event.output, !output.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            // Truncate output to first 500 chars with "show more" link
                            let truncatedOutput = output.count > 500 ? String(output.prefix(500)) + "..." : output
                            let lineCount = output.components(separatedBy: "\n").count
                            
                            ScrollView {
                                Text(truncatedOutput)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 40, maxHeight: 120)
                            
                            if output.count > 500 || lineCount > 8 {
                                Text("\(output.count) chars, \(lineCount) lines")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isToolEvent ? 10 : 12) // Slightly more compact for tool events
        .background(
            RoundedRectangle(cornerRadius: isToolEvent ? 10 : 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isToolEvent ? 10 : 14)
                .stroke(effectiveColor.opacity(0.2), lineWidth: 1)
        )
        .onAppear { expanded = !(event.collapsed ?? true) }
    }
    
    private var colorForKind: Color {
        switch event.kind.lowercased() {
        case "status": return .blue
        case "step": return .green
        case "summary": return .purple
        case "file_change":
            // Use red for destructive operations (delete file), orange for others
            if event.fileChange?.operationType == .deleteFile {
                return .red
            }
            return .orange
        case "command_approval": return .orange
        case "plan_created": return Color(red: 0.7, green: 0.4, blue: 0.9)  // Navigator purple
        case "mode_switch": return .cyan  // Distinctive color for mode switching
        default: return .gray
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "status": return "bolt.fill"
        case "step": return "play.fill"
        case "summary": return "checkmark"
        case "file_change":
            // Use trash icon for delete, doc icon for others
            if event.fileChange?.operationType == .deleteFile {
                return "trash.fill"
            }
            return "doc.text.fill"
        case "command_approval": return "exclamationmark.shield.fill"
        case "plan_created": return "map.fill"
        case "mode_switch": return "arrow.triangle.swap"
        default: return "info.circle"
        }
    }
    
    /// Check if this is a command approval (vs file change approval)
    private var isCommandApproval: Bool {
        event.kind.lowercased() == "command_approval"
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
    
    private func approveApproval(_ approvalId: UUID) {
        approvalHandled = true
        // Use different notification based on approval type
        let notificationName: Notification.Name = isCommandApproval 
            ? .TermAICommandApprovalResponse 
            : .TermAIFileChangeApprovalResponse
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                "approvalId": approvalId,
                "approved": true
            ]
        )
    }
    
    private func rejectApproval(_ approvalId: UUID) {
        approvalHandled = true
        // Use different notification based on approval type
        let notificationName: Notification.Name = isCommandApproval 
            ? .TermAICommandApprovalResponse 
            : .TermAIFileChangeApprovalResponse
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                "approvalId": approvalId,
                "approved": false
            ]
        )
    }
}

// MARK: - Plan Ready View (Navigator Mode)

/// Displays when a plan has been created in Navigator mode
/// Shows plan title and action buttons to view, build with Copilot, or build with Pilot
struct PlanReadyView: View {
    let planId: UUID
    let planTitle: String
    @ObservedObject var session: ChatSession
    let onOpenPlan: (UUID) -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    private let navigatorColor = Color(red: 0.7, green: 0.4, blue: 0.9)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with title and view button
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12))
                    .foregroundColor(navigatorColor)
                
                Text(planTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                // View Plan button (inline with title)
                Button(action: { onOpenPlan(planId) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("View")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(navigatorColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(navigatorColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .help("Open plan in file viewer")
            }
            
            // Build buttons row
            HStack(spacing: 8) {
                Text("Build with:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                // Build with Copilot button
                Button(action: { buildWithMode(.copilot) }) {
                    HStack(spacing: 4) {
                        Image(systemName: AgentMode.copilot.icon)
                            .font(.system(size: 10))
                        Text("Copilot")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AgentMode.copilot.color)
                    )
                }
                .buttonStyle(.plain)
                .help("File operations only")
                
                // Build with Pilot button
                Button(action: { buildWithMode(.pilot) }) {
                    HStack(spacing: 4) {
                        Image(systemName: AgentMode.pilot.icon)
                            .font(.system(size: 10))
                        Text("Pilot")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AgentMode.pilot.color)
                    )
                }
                .buttonStyle(.plain)
                .help("Full shell access")
                
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(navigatorColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func buildWithMode(_ mode: AgentMode) {
        // Add mode switch indicator to chat
        session.messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "mode_switch",
                title: "Navigator → \(mode.rawValue)",
                details: "Switching to \(mode.rawValue) mode to implement the plan",
                command: nil,
                output: nil,
                collapsed: true
            )
        ))
        session.messages = session.messages
        session.persistMessages()
        
        // Switch to the selected mode
        session.agentMode = mode
        session.persistSettings()
        
        // Load the plan content
        if let planContent = PlanManager.shared.getPlanContent(id: planId) {
            // Update plan status to implementing
            Task { @MainActor in
                PlanManager.shared.updatePlanStatus(id: planId, status: .implementing)
            }
            
            // Extract checklist from plan and set it directly (so agent doesn't recreate it)
            let checklistItems = extractChecklistFromPlan(planContent)
            if !checklistItems.isEmpty {
                session.agentChecklist = TaskChecklist(from: checklistItems, goal: "Implement: \(planTitle)")
                
                // Add a checklist message to the UI
                let checklistDisplay = session.agentChecklist!.displayString
                session.messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "checklist",
                        title: "Task Checklist (\(session.agentChecklist!.completedCount)/\(session.agentChecklist!.items.count) done)",
                        details: checklistDisplay,
                        command: nil,
                        output: nil,
                        collapsed: false,
                        checklistItems: session.agentChecklist!.items
                    )
                ))
                session.messages = session.messages
                session.persistMessages()
            }
            
            // Attach the plan as context and send implementation request
            let planContext = PinnedContext(
                type: .snippet,
                path: "plan://\(planId.uuidString)",
                displayName: "Implementation Plan: \(planTitle)",
                content: planContent
            )
            session.pendingAttachedContexts.append(planContext)
            
            // Track current plan
            session.currentPlanId = planId
            session.persistSettings()
            
            // Send the implementation message
            // Tell the agent the checklist is already set
            let implementationMessage = checklistItems.isEmpty
                ? "Please implement the attached implementation plan. Follow the checklist items in order."
                : "Please implement the attached implementation plan. The checklist has already been extracted and is shown above - use it to track your progress. Focus on completing each item in order. Do NOT call plan_and_track to create a new checklist."
            
            Task {
                await session.sendUserMessage(implementationMessage)
            }
        }
    }
    
    /// Extract checklist items from plan markdown content
    private func extractChecklistFromPlan(_ content: String) -> [String] {
        var items: [String] = []
        var inChecklistSection = false
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Look for Checklist header
            if trimmed.lowercased().contains("## checklist") || trimmed.lowercased() == "checklist" {
                inChecklistSection = true
                continue
            }
            
            // Stop at next section
            if inChecklistSection && trimmed.hasPrefix("##") && !trimmed.lowercased().contains("checklist") {
                break
            }
            
            // Extract checklist items (- [ ] format)
            if inChecklistSection && (trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")) {
                let item = trimmed
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .replacingOccurrences(of: "- [X] ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                if !item.isEmpty {
                    items.append(item)
                }
            }
        }
        
        return items
    }
}

// MARK: - Agent Event Group View (Compact grouped events: tools, profile changes, etc.)
private struct AgentEventGroupView: View {
    let events: [AgentEvent]
    let ptyModel: PTYModel
    
    @State private var expanded: Bool = false
    
    // Tool counts
    private var toolEvents: [AgentEvent] {
        events.filter { $0.eventCategory == "tool" || ($0.toolCallId != nil && $0.eventCategory != "command") }
    }
    
    private var succeededCount: Int {
        toolEvents.filter { $0.toolStatus == "succeeded" }.count
    }
    
    private var failedCount: Int {
        toolEvents.filter { $0.toolStatus == "failed" }.count
    }
    
    private var runningCount: Int {
        toolEvents.filter { $0.toolStatus == "running" }.count
    }
    
    // Command counts (shell commands that needed approval)
    private var commandEvents: [AgentEvent] {
        events.filter { $0.eventCategory == "command" }
    }
    
    private var commandSucceededCount: Int {
        commandEvents.filter { $0.toolStatus == "succeeded" }.count
    }
    
    private var commandFailedCount: Int {
        commandEvents.filter { $0.toolStatus == "failed" }.count
    }
    
    // Profile change counts
    private var profileChangeCount: Int {
        events.filter { $0.eventCategory == "profile" }.count
    }
    
    // Other status events
    private var otherStatusCount: Int {
        events.filter { 
            $0.eventCategory != "tool" && $0.eventCategory != "profile" && $0.eventCategory != "command" && $0.toolCallId == nil
        }.count
    }
    
    private var summaryParts: [(text: String, color: Color)] {
        var parts: [(text: String, color: Color)] = []
        
        // Tool summary
        let toolCount = toolEvents.count
        if toolCount > 0 {
            parts.append(("\(toolCount) tool\(toolCount == 1 ? "" : "s")", .secondary))
            if failedCount > 0 {
                parts.append(("(\(failedCount) failed)", .red))
            } else if runningCount > 0 {
                parts.append(("(\(runningCount) running)", .blue))
            }
        }
        
        // Command summary (shell commands)
        let cmdCount = commandEvents.count
        if cmdCount > 0 {
            parts.append(("\(cmdCount) cmd\(cmdCount == 1 ? "" : "s")", .cyan))
            if commandFailedCount > 0 {
                parts.append(("(\(commandFailedCount) failed)", .red))
            }
        }
        
        // Profile changes
        if profileChangeCount > 0 {
            parts.append(("\(profileChangeCount) profile Δ", .purple))
        }
        
        // Other status
        if otherStatusCount > 0 {
            parts.append(("\(otherStatusCount) status", .secondary))
        }
        
        return parts
    }
    
    private var hasRunning: Bool {
        runningCount > 0
    }
    
    /// Header color is neutral/blue - we don't want to alarm users with red
    /// Failures are shown in the summary text and individual rows
    private var headerColor: Color {
        if runningCount > 0 { return .blue }
        return .secondary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header
            Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(headerColor.opacity(0.15))
                            .frame(width: 22, height: 22)
                        
                        if hasRunning {
                            ProgressView()
                                .scaleEffect(0.45)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 9))
                                .foregroundColor(headerColor)
                        }
                    }
                    
                    // Dynamic title based on content
                    Text("Actions")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    // Summary badges - show each category with appropriate colors
                    HStack(spacing: 4) {
                        ForEach(Array(summaryParts.enumerated()), id: \.offset) { _, part in
                            Text(part.text)
                                .font(.system(size: 10))
                                .foregroundColor(part.color)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            
            // Expanded list of tool events
            if expanded {
                Divider()
                    .padding(.horizontal, 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        CompactToolRow(event: event, ptyModel: ptyModel)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(headerColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Compact Event Row (for grouped view - handles tools, profile changes, etc.)
private struct CompactToolRow: View {
    let event: AgentEvent
    let ptyModel: PTYModel
    
    @State private var showDetails: Bool = false
    
    /// Is this a tool event?
    private var isToolEvent: Bool {
        event.eventCategory == "tool" || (event.toolCallId != nil && event.eventCategory != "command")
    }
    
    /// Is this a command (shell) event?
    private var isCommandEvent: Bool {
        event.eventCategory == "command"
    }
    
    /// Is this a profile change event?
    private var isProfileChange: Bool {
        event.eventCategory == "profile"
    }
    
    private var statusColor: Color {
        if isProfileChange {
            return .purple
        }
        if isCommandEvent {
            switch event.toolStatus {
            case "running": return .blue
            case "succeeded": return .cyan
            case "failed": return .red
            default: return .orange
            }
        }
        switch event.toolStatus {
        case "running": return .blue
        case "succeeded": return .green
        case "failed": return .red
        default: return .gray
        }
    }
    
    private var statusIcon: String {
        if isProfileChange {
            return "person.crop.circle.badge.checkmark"
        }
        if isCommandEvent {
            switch event.toolStatus {
            case "running": return "terminal"
            case "succeeded": return "checkmark.circle"
            case "failed": return "xmark.circle"
            default: return "terminal"
            }
        }
        switch event.toolStatus {
        case "running": return "arrow.triangle.2.circlepath"
        case "succeeded": return "checkmark"
        case "failed": return "xmark"
        default: return "info.circle"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.spring(response: 0.25)) { showDetails.toggle() } }) {
                HStack(spacing: 6) {
                    // Status indicator
                    if isToolEvent && event.toolStatus == "running" {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(statusColor)
                            .frame(width: 12, height: 12)
                    }
                    
                    // Event title - different styling for different types
                    if isProfileChange {
                        Text("Profile: \(event.title)")
                            .font(.system(size: 11))
                            .foregroundColor(.purple)
                    } else if isCommandEvent {
                        // Show command with terminal styling
                        let cmdPreview = event.command.map { String($0.prefix(35)) + ($0.count > 35 ? "…" : "") } ?? event.title
                        Text("$ \(cmdPreview)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(event.toolStatus == "failed" ? .red : .cyan)
                    } else {
                        Text(event.title)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(event.toolStatus == "failed" ? .red : .primary)
                    }
                    
                    // File change indicator
                    if event.fileChange != nil {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                    
                    if event.output != nil || event.details != nil || event.fileChange != nil {
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showDetails ? Color.primary.opacity(0.04) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            
            // Expanded details
            if showDetails {
                VStack(alignment: .leading, spacing: 6) {
                    // File change preview
                    if let fileChange = event.fileChange {
                        InlineDiffPreview(fileChange: fileChange, maxLines: 4)
                    }
                    
                    // Details/reason
                    if let details = event.details, !details.isEmpty, event.fileChange == nil {
                        Text(details)
                            .font(.system(size: 10, design: isToolEvent ? .monospaced : .default))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    
                    // Output (truncated) - only for tool events
                    if isToolEvent, let output = event.output, !output.isEmpty, event.fileChange == nil {
                        Text(String(output.prefix(200)) + (output.count > 200 ? "..." : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
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

// MARK: - Agent Mode Selector

struct AgentModeSelector: View {
    @Binding var mode: AgentMode
    @State private var isHovering: Bool = false
    
    var body: some View {
        Menu {
            ForEach(AgentMode.allCases, id: \.self) { agentMode in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        mode = agentMode
                    }
                }) {
                    HStack {
                        Image(systemName: agentMode.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentMode.rawValue)
                            Text(agentMode.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if mode == agentMode {
                            Image(systemName: "checkmark")
                                .foregroundColor(agentMode.color)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Mode icon with glow
                ZStack {
                    // Subtle glow effect
                    Circle()
                        .fill(mode.color.opacity(0.25))
                        .frame(width: 14, height: 14)
                        .blur(radius: 2)
                    
                    // Icon background
                    Circle()
                        .fill(mode.color)
                        .frame(width: 12, height: 12)
                    
                    // Icon
                    Image(systemName: mode.icon)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 14, height: 14)
                
                // Mode label
                Text(mode.rawValue)
                    .font(.caption)
                    .foregroundColor(mode.color)
                
                // Dropdown chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(mode.color.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(mode.color.opacity(isHovering ? 0.2 : 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(mode.color.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
            )
            .shadow(
                color: mode.color.opacity(0.2),
                radius: isHovering ? 4 : 2,
                x: 0, y: 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(mode.detailedDescription)
    }
}

// MARK: - Agent Profile Selector

struct AgentProfileSelector: View {
    @Binding var profile: AgentProfile
    /// The active profile when in Auto mode (shows what profile is currently being used)
    var activeProfile: AgentProfile? = nil
    @State private var isHovering: Bool = false
    
    /// The display profile (active profile when in Auto mode, otherwise the selected profile)
    private var displayProfile: AgentProfile {
        if profile.isAuto, let active = activeProfile {
            return active
        }
        return profile
    }
    
    /// Whether we're in Auto mode with a different active profile
    private var isAutoWithActiveProfile: Bool {
        profile.isAuto && activeProfile != nil && activeProfile != .auto
    }
    
    var body: some View {
        Menu {
            ForEach(AgentProfile.allCases, id: \.self) { agentProfile in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        profile = agentProfile
                    }
                }) {
                    HStack {
                        Image(systemName: agentProfile.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentProfile.rawValue)
                            Text(agentProfile.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if profile == agentProfile {
                            Image(systemName: "checkmark")
                                .foregroundColor(agentProfile.color)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Profile icon with subtle background
                ZStack {
                    // Subtle glow effect
                    Circle()
                        .fill(displayProfile.color.opacity(0.25))
                        .frame(width: 14, height: 14)
                        .blur(radius: 2)
                    
                    // Icon background
                    Circle()
                        .fill(displayProfile.color)
                        .frame(width: 12, height: 12)
                    
                    // Icon
                    Image(systemName: displayProfile.icon)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white)
                    
                    // Small "auto" indicator when in Auto mode
                    if isAutoWithActiveProfile {
                        Circle()
                            .fill(AgentProfile.auto.color)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -5)
                    }
                }
                .frame(width: 14, height: 14)
                
                // Profile label - show "Auto (Coding)" style when in Auto mode
                if isAutoWithActiveProfile, let active = activeProfile {
                    Text("Auto")
                        .font(.caption)
                        .foregroundColor(profile.color)
                    Text("(\(active.rawValue))")
                        .font(.caption2)
                        .foregroundColor(active.color)
                } else {
                    Text(profile.rawValue)
                        .font(.caption)
                        .foregroundColor(profile.color)
                }
                
                // Dropdown chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(displayProfile.color.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(displayProfile.color.opacity(isHovering ? 0.2 : 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(displayProfile.color.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
            )
            .shadow(
                color: displayProfile.color.opacity(0.2),
                radius: isHovering ? 4 : 2,
                x: 0, y: 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(isAutoWithActiveProfile ? "Auto mode - currently using \(activeProfile?.rawValue ?? "General") profile" : profile.detailedDescription)
    }
}

// MARK: - Agent Summary Badge (Compact action summary during run)

private struct AgentSummaryBadge: View {
    @ObservedObject var session: ChatSession
    
    /// Count of tool events (excluding internal events and commands)
    private var toolEventCount: Int {
        session.messages.filter { msg in
            guard let event = msg.agentEvent else { return false }
            return (event.eventCategory == "tool" || (event.toolCallId != nil && event.eventCategory != "command")) && event.isInternal != true
        }.count
    }
    
    /// Count of command events (shell commands)
    private var commandEventCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.eventCategory == "command"
        }.count
    }
    
    /// Count of file changes
    private var fileChangeCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.fileChange != nil
        }.count
    }
    
    /// Count of profile changes
    private var profileChangeCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.eventCategory == "profile"
        }.count
    }
    
    var body: some View {
        if toolEventCount > 0 || fileChangeCount > 0 || profileChangeCount > 0 || commandEventCount > 0 {
            HStack(spacing: 4) {
                if toolEventCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "wrench")
                            .font(.system(size: 8))
                        Text("\(toolEventCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
                
                if commandEventCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "terminal")
                            .font(.system(size: 8))
                        Text("\(commandEventCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.cyan)
                }
                
                if fileChangeCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 8))
                        Text("\(fileChangeCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.orange)
                }
                
                if profileChangeCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 8))
                        Text("\(profileChangeCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.purple)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            )
        }
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
                    
                    // Compact summary badge
                    AgentSummaryBadge(session: session)
                    
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
                // Show agent mode selector when not running
                AgentModeSelector(
                    mode: Binding(
                        get: { session.agentMode },
                        set: { session.agentMode = $0; session.persistSettings() }
                    )
                )
                
                // Show agent profile selector
                AgentProfileSelector(
                    profile: Binding(
                        get: { session.agentProfile },
                        set: { session.agentProfile = $0; session.persistSettings() }
                    ),
                    activeProfile: session.agentProfile.isAuto ? session.activeProfile : nil
                )
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
                        .font(.system(size: 12))
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

// MARK: - Checkpoint Badge

/// Small badge indicating a checkpoint with changes exists at this message
private struct CheckpointBadge: View {
    let checkpoint: Checkpoint
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 10))
            
            Text(checkpoint.shortDescription)
                .font(.caption2)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.12))
        )
        .help("Checkpoint: \(checkpoint.shortDescription). Right-click to edit this message.")
    }
}

// MARK: - Rollback Choice Popover

/// Simple popover that appears when editing a message with a checkpoint
/// Asks user if they want to rollback files or keep current state
private struct RollbackChoicePopover: View {
    let checkpoint: Checkpoint
    @ObservedObject var session: ChatSession
    let editedMessage: String
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var isSubmitting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                Text("File Changes Detected")
                    .font(.headline)
            }
            
            Text("\(checkpoint.modifiedFileCount) file(s) were modified after this message.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if !checkpoint.shellCommandsRun.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("\(checkpoint.shellCommandsRun.count) shell command(s) cannot be undone")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            Divider()
            
            // Options
            VStack(spacing: 8) {
                Button {
                    submitWithRollback()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Rollback files")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                
                Button {
                    submitKeepFiles()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Keep current files")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            
            // Cancel
            Button("Cancel") {
                isPresented = false
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .foregroundColor(.secondary)
            .padding(.top, 4)
        }
        .padding()
        .frame(width: 280)
    }
    
    private func submitWithRollback() {
        isSubmitting = true
        let trimmed = editedMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rollback files and remove the original user message (we're replacing it)
        _ = session.rollbackToCheckpoint(checkpoint, removeUserMessage: true)

        // Send the edited message
        Task {
            await session.sendUserMessage(trimmed)
            await MainActor.run {
                isPresented = false
                onComplete()
            }
        }
    }
    
    private func submitKeepFiles() {
        isSubmitting = true
        let trimmed = editedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Branch without rollback
        session.branchFromCheckpoint(checkpoint, newPrompt: "")
        
        // Send the edited message
        Task {
            await session.sendUserMessage(trimmed)
            await MainActor.run {
                isPresented = false
                onComplete()
            }
        }
    }
}

/// Row showing a file snapshot in the rollback preview
private struct FileSnapshotRow: View {
    let snapshot: FileSnapshot
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.wasCreated ? "trash" : "arrow.counterclockwise")
                .foregroundColor(snapshot.wasCreated ? .red : .blue)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fileName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                
                Text(snapshot.wasCreated ? "Will be deleted" : "Will be restored")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let content = snapshot.contentBefore {
                Text("\(content.count) chars")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

