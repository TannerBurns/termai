import SwiftUI
import AppKit
import TermAIModels

/// Represents a message or group of tool events for rendering
enum GroupedMessage: Identifiable {
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
