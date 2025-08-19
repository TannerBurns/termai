import Foundation
import SwiftUI

/// A completely self-contained chat session with its own state, messages, and streaming
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    
    // Chat state
    @Published var messages: [ChatMessage] = []
    @Published var sessionTitle: String = ""
    @Published var streamingMessageId: UUID? = nil
    @Published var pendingTerminalContext: String? = nil
    @Published var pendingTerminalMeta: TerminalContextMeta? = nil
    
    // Configuration (each session has its own copy)
    @Published var apiBaseURL: URL
    @Published var apiKey: String?
    @Published var model: String
    @Published var providerName: String
    @Published var systemPrompt: String
    @Published var availableModels: [String] = []
    @Published var modelFetchError: String? = nil
    
    // Private streaming state
    private var streamingTask: Task<Void, Never>? = nil
    
    init(
        apiBaseURL: URL = URL(string: "http://localhost:11434/v1")!,
        apiKey: String? = nil,
        model: String = "",
        providerName: String = "Ollama",
        systemPrompt: String = "You are a helpful terminal assistant. When given pasted terminal outputs, analyze them and provide guidance."
    ) {
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.model = model
        self.providerName = providerName
        self.systemPrompt = systemPrompt
        
        // Auto-fetch models if connected to local Ollama
        Task {
            await fetchOllamaModels()
        }
    }
    
    deinit {
        streamingTask?.cancel()
    }
    
    func setPendingTerminalContext(_ text: String, meta: TerminalContextMeta?) {
        pendingTerminalContext = text
        pendingTerminalMeta = meta
    }
    
    func clearPendingTerminalContext() {
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
    }
    
    func clearChat() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        messages = []
        persistMessages()
    }
    
    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
    }
    
    func sendUserMessage(_ text: String) async {
        // Validate model is selected
        guard !model.isEmpty else {
            messages.append(ChatMessage(role: "assistant", content: "⚠️ No model selected. Please go to Settings (⌘,) and select a model."))
            return
        }
        
        let ctx = pendingTerminalContext
        let meta = pendingTerminalMeta
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
        
        messages.append(ChatMessage(role: "user", content: text, terminalContext: ctx, terminalContextMeta: meta))
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: "assistant", content: ""))
        streamingMessageId = messages[assistantIndex].id
        
        // Force UI update
        messages = messages
        
        // Cancel any previous stream
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await self.requestChatCompletionStream(assistantIndex: assistantIndex)
            } catch is CancellationError {
                // ignore
            } catch {
                await MainActor.run { 
                    self.messages.append(ChatMessage(role: "assistant", content: "Error: \(error.localizedDescription)")) 
                }
            }
            await MainActor.run {
                self.streamingMessageId = nil
                self.persistMessages()
            }
        }
    }
    
    // MARK: - Streaming
    private func requestChatCompletionStream(assistantIndex: Int) async throws -> String {
        struct RequestBody: Encodable {
            struct Message: Codable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
        }
        
        let url = apiBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let userMessages = messages.filter { $0.role != "system" }
        let allMessages: [RequestBody.Message] = [RequestBody.Message(role: "system", content: systemPrompt)] + userMessages.map {
            var prefix = ""
            if let ctx = $0.terminalContext, !ctx.isEmpty {
                var header = "Terminal Context:"
                if let meta = $0.terminalContextMeta, let cwd = meta.cwd, !cwd.isEmpty {
                    header += "\nCurrent Working Directory - \(cwd)"
                }
                prefix = "\(header)\n```\n\(ctx)\n```\n\n"
            }
            return RequestBody.Message(role: $0.role, content: prefix + $0.content)
        }
        
        let req = RequestBody(model: model, messages: allMessages, stream: true)
        request.httpBody = try JSONEncoder().encode(req)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        streamLoop: for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break streamLoop }
            guard let data = payload.data(using: .utf8) else { continue }
            
            if let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    if Task.isCancelled { break streamLoop }
                    messages[index].content = accumulated
                    // Force UI update on each chunk
                    messages = messages
                }
            } else if let ollama = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data) {
                if let content = ollama.message?.content ?? ollama.response {
                    accumulated += content
                    if Task.isCancelled { break streamLoop }
                    messages[index].content = accumulated
                    // Force UI update on each chunk
                    messages = messages
                }
            }
        }
        
        return accumulated
    }
    
    // MARK: - Models
    func fetchOllamaModels() async {
        modelFetchError = nil
        let host = apiBaseURL.host?.lowercased() ?? ""
        guard host == "localhost" || host == "127.0.0.1" else { return }
        
        do {
            let base = apiBaseURL.absoluteString
            let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/api/tags")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 5 // Quick timeout for auto-fetch
            
            let (data, response) = try await URLSession.shared.data(for: req)
            
            // Check for valid response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return // Silently fail for auto-fetch
            }
            
            struct TagsResponse: Decodable { 
                struct Model: Decodable { let name: String }
                let models: [Model] 
            }
            if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                let names = decoded.models.map { $0.name }.sorted()
                await MainActor.run {
                    self.availableModels = names
                    
                    // Auto-select first model if none selected
                    if self.model.isEmpty && !names.isEmpty {
                        self.model = names[0]
                        self.persistSettings()
                    }
                    // Update to valid model if current one doesn't exist
                    else if !self.model.isEmpty && !names.contains(self.model) && !names.isEmpty {
                        self.model = names[0]
                        self.persistSettings()
                    }
                }
            }
        } catch {
            // Silently fail for auto-fetch on init
            // User can manually fetch in settings if needed
        }
    }
    
    // MARK: - Persistence
    private var messagesFileName: String { "chat-session-\(id.uuidString).json" }
    
    func persistMessages() {
        try? PersistenceService.saveJSON(messages, to: messagesFileName)
    }
    
    func loadMessages() {
        if let m = try? PersistenceService.loadJSON([ChatMessage].self, from: messagesFileName) {
            messages = m
        }
    }
    
    func persistSettings() {
        let settings = SessionSettings(
            apiBaseURL: apiBaseURL.absoluteString,
            apiKey: apiKey,
            model: model,
            providerName: providerName,
            systemPrompt: systemPrompt,
            sessionTitle: sessionTitle
        )
        try? PersistenceService.saveJSON(settings, to: "session-settings-\(id.uuidString).json")
    }
    
    func loadSettings() {
        if let settings = try? PersistenceService.loadJSON(SessionSettings.self, from: "session-settings-\(id.uuidString).json") {
            if let url = URL(string: settings.apiBaseURL) { apiBaseURL = url }
            apiKey = settings.apiKey
            model = settings.model
            providerName = settings.providerName
            systemPrompt = settings.systemPrompt
            sessionTitle = settings.sessionTitle
        }
        
        // After loading settings, fetch models if connected to Ollama
        Task {
            await fetchOllamaModels()
        }
    }
}

// MARK: - Supporting Types
private struct SessionSettings: Codable {
    let apiBaseURL: String
    let apiKey: String?
    let model: String
    let providerName: String
    let systemPrompt: String
    let sessionTitle: String
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]
}

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let response: String?
}
