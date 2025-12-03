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
    let onSend: () -> Void
    let onStop: () -> Void
    
    @State private var isFocused: Bool = false
    
    /// Input should only be disabled during the brief sending moment, not during agent execution
    private var isInputDisabled: Bool {
        sending && !isAgentRunning
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Text input with modern styling
            ZStack(alignment: .topLeading) {
                if messageText.isEmpty {
                    Text(isAgentRunning ? "Add feedback for the agent..." : "Type your message...")
                        .font(.system(size: 13))
                        .foregroundColor(isAgentRunning ? Color.blue.opacity(0.6) : .secondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                
                ChatTextEditor(
                    text: $messageText,
                    isFocused: $isFocused,
                    isDisabled: isInputDisabled,
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

// MARK: - Custom Text Editor with Enter/Shift+Enter handling
private struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isDisabled: Bool
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
        textView.isRichText = false
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
        
        scrollView.documentView = textView
        context.coordinator.textView = textView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.onSubmit = onSubmit
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        weak var textView: NSTextView?
        
        init(_ parent: ChatTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
        
        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }
        
        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }
    }
}

// Custom NSTextView that handles Enter vs Shift+Enter
private class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    
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
            
            // Message content
            if let evt = message.agentEvent {
                AgentEventView(event: evt, ptyModel: ptyModel)
            } else {
                MarkdownRenderer(text: message.content)
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

