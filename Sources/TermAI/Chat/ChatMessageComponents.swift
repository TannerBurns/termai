import SwiftUI
import AppKit
import TermAIModels

// MARK: - Chat Message Bubble

struct ChatMessageBubble: View {
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
                    originalMessage: message,
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
            // Preserve terminal context from the original message
            if let ctx = message.terminalContext {
                session.setPendingTerminalContext(ctx, meta: message.terminalContextMeta)
            }
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

struct StreamingIndicator: View {
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

// MARK: - Message Content with Mentions

/// Renders message content with @filename mentions as clickable badges
struct MessageContentWithMentions: View {
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
struct MentionTextView: View {
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
enum MentionSegment {
    case text(String)
    case mention(String)
}

// MARK: - Inline Mention Badge

/// Clickable badge for @filename in message text - matches AttachedFileBadge styling
struct InlineMentionBadge: View {
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
