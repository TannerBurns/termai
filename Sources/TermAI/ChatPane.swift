import SwiftUI

struct ChatPane: View {
    @EnvironmentObject private var model: ChatViewModel
    @EnvironmentObject private var currentTab: AppTab
    @EnvironmentObject private var tabsStore: TabsStore
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var showSystemPrompt: Bool = false
    @State private var scrollViewHeight: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chat")
                    .font(.headline)
                // Provider/model chips (view-only)
                Label(model.providerName, systemImage: "network")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                Label(model.model, systemImage: "cpu")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                    .overlay(
                        Group {
                            if let err = model.modelFetchError {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.leading, 6)
                            }
                        }, alignment: .trailing
                    )
                // Context chip moved below tabs
                Spacer()
                Button(action: { showSystemPrompt.toggle() }) {
                    Label("System Prompt", systemImage: showSystemPrompt ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
            }
            .padding(8)

            // Tabs row under Chat header
            if let selectedTab = tabsStore.selected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedTab.chats.indices, id: \.self) { idx in
                            let isSelected = idx == selectedTab.selectedChatIndex
                            HStack(spacing: 6) {
                                Button(action: { currentTab.selectedChatIndex = idx }) {
                                    Text(selectedTab.chats[idx].sessionTitle.isEmpty ? "Chat \(idx+1)" : selectedTab.chats[idx].sessionTitle)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                Button(action: { tabsStore.closeChatInSelectedTab(at: idx) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Close Chat")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15)))
                        }
                        Button(action: {
                            let source = currentTab.selectedChat
                            tabsStore.addChatToSelectedTab(copyFrom: source)
                        }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Chat Tab")
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }

            // Show terminal context chip below the tabs for more space
            if let ctx = model.pendingTerminalContext, !ctx.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Terminal Context ready", systemImage: "paperclip")
                            .font(.caption)
                        Spacer()
                        Button("Remove") { model.clearPendingTerminalContext() }
                            .buttonStyle(.borderless)
                    }
                    if let meta = model.pendingTerminalMeta, let cwd = meta.cwd, !cwd.isEmpty {
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

            if showSystemPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $model.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                        .onChange(of: model.systemPrompt) { _ in
                            model.persistSettings()
                        }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { msg in
                            MarkdownMessageBubble(message: msg, isStreaming: msg.id == model.streamingMessageId)
                                .id(msg.id)
                        }
                        // Bottom sentinel to detect proximity to bottom
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
                .onChange(of: model.messages) { _ in
                    let distanceFromBottom = contentBottomY - scrollViewHeight
                    guard distanceFromBottom <= 40 else { return }
                    guard let lastId = model.messages.last?.id else { return }
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            Divider()

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
    }

    private func send() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            await model.sendUserMessage(text)
            await MainActor.run {
                messageText = ""
                sending = false
            }
        }
    }
}

// Preference keys and helper views for non-intrusive auto-scroll detection
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

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.capitalized)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(message.content)
                .font(.system(.body, design: .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(message.role == "user" ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.12))
                )
        }
    }
}

private struct MarkdownMessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
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
            // Hide terminalContext for user messages to save space, but still included in request
            let display = message.role == "user" ? message.content : message.content
            MarkdownRenderer(text: display)
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


