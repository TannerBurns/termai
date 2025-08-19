import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var terminalContext: String? = nil
    var terminalContextMeta: TerminalContextMeta? = nil
}

@MainActor
final class ChatViewModel: ObservableObject {
    let id: UUID = UUID()
    @Published private(set) var messages: [ChatMessage] = []

    // Configurable for Ollama or OpenAI-compatible providers
    @Published var apiBaseURL: URL = URL(string: "http://localhost:11434/v1")! // Ollama default
    @Published var apiKey: String? = nil // Optional; Ollama does not require
    @Published var model: String = "llama3.1" // A common default Ollama model name; change as needed
    @Published var providerName: String = "Ollama"
    @Published var pendingTerminalContext: String? = nil
    @Published var pendingTerminalMeta: TerminalContextMeta? = nil
    @Published var systemPrompt: String = "You are a helpful terminal assistant. When given pasted terminal outputs, analyze them and provide guidance."
    @Published var streamingMessageId: UUID? = nil
    @Published var availableModels: [String] = []
    @Published var modelFetchError: String? = nil
    @Published var sessionTitle: String = ""
    private var streamingTask: Task<Void, Never>? = nil

    init() {}

    func appendUserMessage(_ text: String) {
        messages.append(ChatMessage(role: "user", content: text))
        persistMessages()
    }

    func clearChat() {
        // Cancel any in-flight stream to avoid updating invalid indices
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        messages = [ChatMessage(role: "system", content: "You are a helpful terminal assistant. When given pasted terminal outputs, analyze them and provide guidance.")]
        persistMessages()
    }

    func replaceMessages(_ newMessages: [ChatMessage]) {
        messages = newMessages
    }

    func useOllamaDefaults() {
        apiBaseURL = URL(string: "http://localhost:11434/v1")!
        apiKey = nil
        // Pick a model you have pulled in Ollama, e.g. llama3.1 or mistral
        if model.isEmpty { model = "llama3.1" }
        providerName = "Ollama"
        persistSettings()
    }

    func useOpenAIDefaults() {
        apiBaseURL = URL(string: "https://api.openai.com/v1")!
        // apiKey should be set in Settings
        if model.isEmpty { model = "gpt-4o-mini" }
        providerName = "OpenAI"
        persistSettings()
    }

    func setPendingTerminalContext(_ text: String, meta: TerminalContextMeta?) {
        pendingTerminalContext = text
        pendingTerminalMeta = meta
    }

    func clearPendingTerminalContext() {
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
    }

    func sendUserMessage(_ text: String) async {
        let ctx = pendingTerminalContext
        let meta = pendingTerminalMeta
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
        messages.append(ChatMessage(role: "user", content: text, terminalContext: ctx, terminalContextMeta: meta))
        // Create assistant placeholder immediately so UI shows separate bubbles right away
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: "assistant", content: ""))
        streamingMessageId = messages[assistantIndex].id
        // Cancel any previous stream for this chat
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await self.requestChatCompletionStream(assistantIndex: assistantIndex)
            } catch is CancellationError {
                // ignore
            } catch {
                await MainActor.run { self.messages.append(ChatMessage(role: "assistant", content: "Error: \(error.localizedDescription)")) }
            }
            await MainActor.run {
                self.streamingMessageId = nil
                self.persistMessages()
            }
        }
    }

    // MARK: - Models
    func initializeModelsOnStartup() async {
        guard isLocalOllama else { return }
        await fetchOllamaModels()
    }

    private var isLocalOllama: Bool {
        let host = apiBaseURL.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1"
    }

    func fetchOllamaModels() async {
        modelFetchError = nil
        availableModels = []
        do {
            let base = apiBaseURL.absoluteString
            let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/api/tags")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let (data, _) = try await URLSession.shared.data(for: req)
            struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
            if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                let names = decoded.models.map { $0.name }
                await MainActor.run {
                    self.availableModels = names
                    if self.availableModels.isEmpty {
                        self.modelFetchError = "No models found on local Ollama."
                    } else if !self.availableModels.contains(self.model) || self.model.isEmpty {
                        self.model = self.availableModels.first ?? self.model
                    }
                    self.persistSettings()
                }
            } else {
                await MainActor.run { self.modelFetchError = "Unable to decode models list." }
            }
        } catch {
            await MainActor.run { self.modelFetchError = "Failed to fetch models from Ollama." }
        }
    }

    private func requestChatCompletion() async throws -> String {
        struct RequestBody: Encodable {
            struct Message: Codable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool?
        }

        struct Choice: Decodable { let message: RequestBody.Message }
        struct ResponseBody: Decodable { let choices: [Choice]?; let error: APIError? }
        struct APIError: Decodable { let message: String? }

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
        let req = RequestBody(
            model: model,
            messages: allMessages,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(req)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data), let msg = decoded.error?.message {
                throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)\n\(body)"])
        }

        if let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data), let reply = decoded.choices?.first?.message.content {
            return reply
        }
        // Ollama might return a different structure when not using pure OpenAI route. Fall back gracefully.
        if let reply = try? decodeOllamaStyle(data: data) {
            return reply
        }
        return String(data: data, encoding: .utf8) ?? "(empty)"
    }

    // Streaming support for OpenAI-compatible endpoints (SSE-like JSON chunks)
    private func requestChatCompletionStream(assistantIndex: Int? = nil) async throws -> String {
        struct RequestBody: Encodable {
            struct Message: Codable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
        }

        // Prevent calling a non-existent model on local Ollama
        if isLocalOllama {
            if let err = modelFetchError { throw NSError(domain: "ChatAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: err]) }
            if !availableModels.isEmpty && !availableModels.contains(model) {
                throw NSError(domain: "ChatAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "Model '\(model)' not found on Ollama."])
            }
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
        let req = RequestBody(
            model: model,
            messages: allMessages,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(req)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }

        // Determine which assistant message to stream into
        var accumulated = ""
        let index: Int
        if let idx = assistantIndex, idx >= 0, idx < messages.count, messages[idx].role == "assistant" {
            index = idx
        } else if let last = messages.last, last.role == "assistant" && last.content.isEmpty {
            index = messages.count - 1
            streamingMessageId = messages[index].id
        } else {
            messages.append(ChatMessage(role: "assistant", content: ""))
            index = messages.count - 1
            streamingMessageId = messages[index].id
        }

        streamLoop: for try await line in bytes.lines {
            // OpenAI-compatible streaming sends lines like: "data: {json}\n" and ends with "data: [DONE]"
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break streamLoop }
            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    if Task.isCancelled { break streamLoop }
                    messages[index].content = accumulated
                } else if let content = chunk.choices.first?.message?.content, !content.isEmpty {
                    accumulated += content
                    if Task.isCancelled { break streamLoop }
                    messages[index].content = accumulated
                }
            } else if let ollama = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data) {
                if let content = ollama.message?.content ?? ollama.response { // various shapes
                    accumulated += content
                    if Task.isCancelled { break streamLoop }
                    messages[index].content = accumulated
                }
            }
        }

        return accumulated
    }

    private struct OpenAIStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            struct Message: Decodable { let content: String }
            let delta: Delta?
            let message: Message?
        }
        let choices: [Choice]
    }

    private struct OllamaStreamChunk: Decodable {
        struct Message: Decodable { let role: String?; let content: String? }
        let message: Message?
        let response: String?
        let done: Bool?
    }

    // MARK: - Persistence
    private var messagesFileName: String { "messages-\(id.uuidString).json" }
    func persistSettings() {
        let s = AppSettings(apiBaseURLString: apiBaseURL.absoluteString, apiKey: apiKey, model: model, providerName: providerName, systemPrompt: systemPrompt)
        try? PersistenceService.saveJSON(s, to: "settings.json")
    }

    func loadSettings() {
        if let s = try? PersistenceService.loadJSON(AppSettings.self, from: "settings.json") {
            if let url = URL(string: s.apiBaseURLString) { apiBaseURL = url }
            apiKey = s.apiKey
            model = s.model
            if let pn = s.providerName { providerName = pn }
            if let sp = s.systemPrompt { systemPrompt = sp }
        }
    }

    func persistMessages() {
        try? PersistenceService.saveJSON(messages, to: messagesFileName)
    }

    func loadMessages() {
        if let m = try? PersistenceService.loadJSON([ChatMessage].self, from: messagesFileName) {
            messages = m.filter { $0.role != "system" }
        }
    }
    private func decodeOllamaStyle(data: Data) throws -> String {
        struct OllamaChatResponse: Decodable {
            struct Message: Decodable { let role: String; let content: String }
            let message: Message?
            let response: String? // some endpoints may use this
        }
        if let obj = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) {
            if let content = obj.message?.content { return content }
            if let content = obj.response { return content }
        }
        throw NSError(domain: "ChatAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to decode response"])
    }
}


