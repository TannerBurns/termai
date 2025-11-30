import SwiftUI

/// Chat tab content view without the header (since header is in container)
struct ChatTabContentView: View {
    @ObservedObject var session: ChatSession
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var isNearBottom: Bool = true
    @State private var userHasScrolledUp: Bool = false
    
    let tabIndex: Int
    let ptyModel: PTYModel
    
    var body: some View {
        VStack(spacing: 0) {
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
                cwd: ptyModel.currentWorkingDirectory,
                onSend: send
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
        }
    }
    
    private func send() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        messageText = ""
        userHasScrolledUp = false  // Reset scroll state on new message
        Task {
            await session.sendUserMessage(text)
            await MainActor.run {
                sending = false
            }
        }
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
    let cwd: String
    let onSend: () -> Void
    
    @State private var isFocused: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            // Text input with modern styling
            ZStack(alignment: .topLeading) {
                if messageText.isEmpty {
                    Text("Type your message...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                
                TextEditor(text: $messageText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .disabled(sending)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .onTapGesture { isFocused = true }
            
            // Bottom bar with CWD and send button
            HStack(spacing: 12) {
                // Current working directory
                if !cwd.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(shortenPath(cwd))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                
                Spacer()
                
                // Send button
                Button(action: onSend) {
                    Group {
                        if sending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(
                                messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending
                                    ? Color.secondary.opacity(0.3)
                                    : Color.accentColor
                            )
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(sending || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .animation(.easeInOut(duration: 0.15), value: messageText.isEmpty)
            }
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
                AgentEventView(event: evt)
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
    let event: AgentEvent
    
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
                    if let cmd = event.command, !cmd.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(cmd)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                    
                    if let details = event.details, !details.isEmpty {
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
        default: return .gray
        }
    }
    
    private func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "status": return "bolt.fill"
        case "step": return "play.fill"
        case "summary": return "checkmark"
        default: return "info.circle"
        }
    }
}

