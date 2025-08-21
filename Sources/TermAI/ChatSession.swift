import Foundation
import SwiftUI

/// A completely self-contained chat session with its own state, messages, and streaming
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id: UUID
    
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
    @Published var availableModels: [String] = []
    @Published var modelFetchError: String? = nil
    @Published var titleGenerationError: String? = nil
    
    // System info and prompt
    private let systemInfo: SystemInfo = SystemInfo.gather()
    var systemPrompt: String {
        return systemInfo.injectIntoPrompt()
    }
    
    // Private streaming state
    private var streamingTask: Task<Void, Never>? = nil
    
    init(
        apiBaseURL: URL = URL(string: "http://localhost:11434/v1")!,
        apiKey: String? = nil,
        model: String = "",
        providerName: String = "Ollama",
        restoredId: UUID? = nil
    ) {
        self.id = restoredId ?? UUID()
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.model = model
        self.providerName = providerName
        
        // Don't auto-fetch models here - wait until after settings are loaded
        // This prevents overriding the persisted model selection
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
        sessionTitle = ""  // Reset title when clearing chat
        persistMessages()
        persistSettings()  // Persist the cleared title
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
        
        // Check if this is the first user message and generate title if needed
        let isFirstUserMessage = messages.filter { $0.role == "user" }.isEmpty
        
        messages.append(ChatMessage(role: "user", content: text, terminalContext: ctx, terminalContextMeta: meta))
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: "assistant", content: ""))
        streamingMessageId = messages[assistantIndex].id
        
        // Force UI update
        messages = messages
        
        // Generate title for the first user message
        if isFirstUserMessage && sessionTitle.isEmpty {
            Task { [weak self] in
                await self?.generateTitle(from: text)
            }
        }
        
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
    
    // MARK: - Title Generation
    private func generateTitle(from userMessage: String) async {
        // Clear any previous error
        await MainActor.run { [weak self] in
            self?.titleGenerationError = nil
        }
        
        // Skip if model is not set
        guard !model.isEmpty else {
            await MainActor.run { [weak self] in
                self?.titleGenerationError = "Cannot generate title: No model selected"
            }
            return
        }
        
        // Run title generation in a separate task
        let titleTask = Task { [weak self] in
            guard let self = self else { return }
            
            struct RequestBody: Encodable {
                struct Message: Codable { let role: String; let content: String }
                let model: String
                let messages: [Message]
                let stream: Bool
                let max_tokens: Int
                let temperature: Double
            }
            
            let titlePrompt = """
            Generate a concise 2-5 word title for a chat conversation that starts with this user message. \
            The title should capture the main topic or intent. \
            Only respond with the title itself, no quotes, no explanation.
            
            User message: \(userMessage)
            """
            
            // Use the same endpoint configuration as regular chat
            let url = self.apiBaseURL.appendingPathComponent("chat/completions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60.0  // 60 second timeout for slow models
            if let apiKey = self.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            let messages = [
                RequestBody.Message(role: "system", content: "You are a helpful assistant that generates concise titles."),
                RequestBody.Message(role: "user", content: titlePrompt)
            ]
            
            let req = RequestBody(
                model: self.model,
                messages: messages,
                stream: false,
                max_tokens: 256,
                temperature: 1.0
            )
            
            do {
                request.httpBody = try JSONEncoder().encode(req)
                
                // Use a custom URLSession with longer timeout configuration
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60.0
                config.timeoutIntervalForResource = 60.0
                let session = URLSession(configuration: config)
                
                let (data, response) = try await session.data(for: request)
                
                guard !Task.isCancelled else { 
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Title generation was cancelled"
                    }
                    return 
                }
                
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Invalid response from server"
                    }
                    return
                }
                
                guard (200..<300).contains(http.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Title generation failed (HTTP \(http.statusCode)): \(errorBody)"
                    }
                    return
                }
                
                // Try to decode OpenAI-style response first
                struct OpenAIChoice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                struct OpenAIResponse: Decodable { let choices: [OpenAIChoice] }
                
                // Try Ollama-style response with delta (for streaming compatibility)
                struct OllamaChoice: Decodable {
                    struct Delta: Decodable { let content: String? }
                    let delta: Delta?
                    let message: OpenAIChoice.Message?
                }
                struct OllamaResponseWithDelta: Decodable { let choices: [OllamaChoice] }
                
                // Try Ollama-style response
                struct OllamaResponse: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message?
                    let response: String?
                }
                
                var generatedTitle: String? = nil
                
                // Try OpenAI format
                do {
                    let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                    if let title = decoded.choices.first?.message.content {
                        generatedTitle = title
                    }
                } catch {
                    // Try Ollama format
                    do {
                        let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
                        generatedTitle = decoded.message?.content ?? decoded.response
                    } catch {
                        // Failed to decode both formats
                    }
                }
                
                if let title = generatedTitle {
                    await MainActor.run { [weak self] in
                        self?.sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.titleGenerationError = nil  // Clear any error on success
                        self?.persistSettings()
                    }
                } else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Could not parse title from response. Response: \(responseBody)"
                    }
                }
            } catch {
                let errorMessage: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut:
                        errorMessage = "Request timed out (URLError)"
                    case .notConnectedToInternet:
                        errorMessage = "No internet connection"
                    case .cannotConnectToHost:
                        errorMessage = "Cannot connect to host: \(self.apiBaseURL.host ?? "unknown")"
                    default:
                        errorMessage = "Network error: \(urlError.localizedDescription)"
                    }
                } else {
                    errorMessage = "Title generation error: \(error.localizedDescription)"
                }
                
                await MainActor.run { [weak self] in
                    self?.titleGenerationError = errorMessage
                }
            }
        }
        
        // Cancel the task if it takes more than 90 seconds (extra buffer beyond URLSession timeout)
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)  // 90 seconds
            if !titleTask.isCancelled {
                titleTask.cancel()
                await MainActor.run { [weak self] in
                    // Only set timeout error if we still don't have a title
                    if self?.sessionTitle.isEmpty == true {
                        self?.titleGenerationError = "Title generation timed out after 90 seconds"
                    }
                }
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
                    
                    // Only auto-select first model if truly no model is set
                    // Don't override a persisted model selection
                    if self.model.isEmpty && !names.isEmpty {
                        self.model = names[0]
                        self.persistSettings()
                    }
                    // Don't automatically change the model if it's not in the list
                    // The user may have a valid model that's not currently running
                    // or there may be a timing issue with fetching models
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
            systemPrompt: nil,  // No longer used
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
            // Note: systemPrompt is no longer loaded from settings - using hard-coded prompt
            sessionTitle = settings.sessionTitle ?? ""
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
    let systemPrompt: String? // Kept for backward compatibility but no longer used
    let sessionTitle: String?
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
