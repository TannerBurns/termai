import SwiftUI

/// A completely self-contained chat tab view with its own session
struct ChatTabView: View {
    @StateObject private var session: ChatSession
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var showSystemPrompt: Bool = false
    @State private var scrollViewHeight: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0
    
    let onClose: () -> Void
    let tabIndex: Int
    let ptyModel: PTYModel
    
    init(
        session: ChatSession? = nil,
        tabIndex: Int,
        ptyModel: PTYModel,
        onClose: @escaping () -> Void
    ) {
        self._session = StateObject(wrappedValue: session ?? ChatSession())
        self.tabIndex = tabIndex
        self.ptyModel = ptyModel
        self.onClose = onClose
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text(session.sessionTitle.isEmpty ? "Chat \(tabIndex + 1)" : session.sessionTitle)
                    .font(.headline)
                
                Label(session.providerName, systemImage: "network")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                
                Label(session.model, systemImage: "cpu")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                
                Spacer()
                
                Button(action: { showSystemPrompt.toggle() }) {
                    Label("System Prompt", systemImage: showSystemPrompt ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Chat")
            }
            .padding(8)
            
            // Terminal context indicator
            if let ctx = session.pendingTerminalContext, !ctx.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Terminal Context ready", systemImage: "paperclip")
                            .font(.caption)
                        Spacer()
                        Button("Remove") { session.clearPendingTerminalContext() }
                            .buttonStyle(.borderless)
                    }
                    if let meta = session.pendingTerminalMeta, let cwd = meta.cwd, !cwd.isEmpty {
                        Text("Current Working Directory - \(cwd)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(ctx)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25)))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            
            // System prompt editor
            if showSystemPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $session.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                        .onChange(of: session.systemPrompt) { _ in
                            session.persistSettings()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { msg in
                            ChatMessageBubble(
                                message: msg,
                                isStreaming: msg.id == session.streamingMessageId,
                                ptyModel: ptyModel
                            )
                            .id(msg.id)
                        }
                        BottomSentinel()
                    }
                    .padding(8)
                }
                .coordinateSpace(name: "chatScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollViewHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ScrollViewHeightKey.self) { h in
                    scrollViewHeight = h
                }
                .onPreferenceChange(BottomOffsetKey.self) { bottomY in
                    contentBottomY = bottomY
                }
                .onChange(of: session.messages) { _ in
                    let distanceFromBottom = contentBottomY - scrollViewHeight
                    guard distanceFromBottom <= 40 else { return }
                    guard let lastId = session.messages.last?.id else { return }
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            
            Divider()
            
            // Input area
            VStack(spacing: 2) {
                TextEditor(text: $messageText)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                    .disabled(sending)
                HStack {
                    Spacer()
                    Button(action: send) {
                        if sending { ProgressView() } else { Text("Send") }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(sending || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
        }
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
        messageText = ""  // Clear immediately for better UX
        Task {
            await session.sendUserMessage(text)
            await MainActor.run {
                sending = false
            }
        }
    }
}

// MARK: - Message Bubble
private struct ChatMessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let ptyModel: PTYModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.capitalized)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if message.role == "user", let meta = message.terminalContextMeta {
                HStack(spacing: 6) {
                    Label("Terminal context rows \(meta.startRow)-\(meta.endRow)", systemImage: "grid")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                    if let cwd = meta.cwd, !cwd.isEmpty {
                        Label("cwd: \(cwd)", systemImage: "folder")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                    }
                }
            }
            
            MarkdownRenderer(text: message.content)
                .environmentObject(ptyModel)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(message.role == "user" ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.12))
                )
                .overlay(alignment: .bottomLeading) {
                    if isStreaming {
                        CursorView().padding(.leading, 6).padding(.bottom, 6)
                    }
                }
        }
    }
}

// MARK: - Helper Views
private struct ScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BottomSentinel: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: BottomOffsetKey.self, value: proxy.frame(in: .named("chatScroll")).maxY)
        }
        .frame(height: 0)
    }
}

private struct CursorView: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.8))
            .frame(width: 6, height: 14)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}
