import SwiftUI

struct ChatPane: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var messageText: String = ""
    @State private var sending: Bool = false
    @State private var showSystemPrompt: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chat")
                    .font(.headline)
                Spacer()
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
                if let ctx = model.pendingTerminalContext, !ctx.isEmpty {
                    HStack(spacing: 6) {
                        Label("Terminal Context ready", systemImage: "paperclip")
                            .font(.caption)
                        Button("Remove") { model.clearPendingTerminalContext() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
                Button(action: { showSystemPrompt.toggle() }) {
                    Label("System Prompt", systemImage: showSystemPrompt ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
            }
            .padding(8)

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
                    }
                    .padding(8)
                }
                .onChange(of: model.messages) { _ in
                    guard let lastId = model.messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
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


