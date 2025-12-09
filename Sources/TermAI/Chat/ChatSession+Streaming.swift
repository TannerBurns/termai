import Foundation
import TermAIModels

// MARK: - Streaming

extension ChatSession {
    
    /// Route to appropriate streaming provider
    func requestChatCompletionStream(assistantIndex: Int) async throws -> String {
        if case .cloud(let cloudProvider) = providerType {
            switch cloudProvider {
            case .openai:
                return try await requestOpenAIStream(assistantIndex: assistantIndex)
            case .anthropic:
                return try await requestAnthropicStream(assistantIndex: assistantIndex)
            case .google:
                return try await requestGoogleStream(assistantIndex: assistantIndex)
            }
        } else {
            return try await requestLocalProviderStream(assistantIndex: assistantIndex)
        }
    }
    
    // MARK: - Local Provider Streaming (Ollama, LM Studio, vLLM)
    
    func requestLocalProviderStream(assistantIndex: Int) async throws -> String {
        let url = apiBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        // Build request body as dictionary
        let bodyDict: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens as Any
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        let promptText = allMessages.map { $0.content }.joined(separator: "\n")
        let estimatedPromptTokens = TokenEstimator.estimateTokens(promptText)
        
        return try await streamSSEResponse(
            request: request,
            assistantIndex: assistantIndex,
            provider: providerName,
            modelName: model,
            estimatedPromptTokens: estimatedPromptTokens
        )
    }
    
    // MARK: - OpenAI Streaming
    
    func requestOpenAIStream(assistantIndex: Int) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not found. Set OPENAI_API_KEY environment variable."])
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        var bodyDict: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        
        if currentModelSupportsReasoning {
            bodyDict["temperature"] = 1.0
            bodyDict["max_completion_tokens"] = maxTokens
            if let reasoningValue = reasoningEffort.openAIValue {
                bodyDict["reasoning_effort"] = reasoningValue
            }
        } else {
            bodyDict["temperature"] = temperature
            bodyDict["max_completion_tokens"] = maxTokens
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        let promptText = allMessages.map { $0.content }.joined(separator: "\n")
        let estimatedPromptTokens = TokenEstimator.estimateTokens(promptText)
        
        return try await streamSSEResponse(
            request: request,
            assistantIndex: assistantIndex,
            provider: "OpenAI",
            modelName: model,
            estimatedPromptTokens: estimatedPromptTokens
        )
    }
    
    // MARK: - Anthropic Streaming
    
    func requestAnthropicStream(assistantIndex: Int) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable."])
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        if currentModelSupportsReasoning && reasoningEffort != .none {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true
        ]
        
        bodyDict["system"] = sysPrompt
        
        let anthropicMessages = allMessages.filter { $0.role != "system" }.map { msg -> [String: Any] in
            return ["role": msg.role, "content": msg.content]
        }
        bodyDict["messages"] = anthropicMessages
        
        if !currentModelSupportsReasoning || reasoningEffort == .none {
            bodyDict["temperature"] = temperature
        }
        
        if currentModelSupportsReasoning, let budgetTokens = reasoningEffort.anthropicBudgetTokens {
            bodyDict["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        return try await streamAnthropicResponse(
            request: request,
            assistantIndex: assistantIndex,
            modelName: model,
            systemPromptUsed: sysPrompt
        )
    }
    
    // MARK: - Google AI Studio Streaming (Gemini)
    
    func requestGoogleStream(assistantIndex: Int) async throws -> String {
        let baseURL = CloudProvider.google.baseURL
        guard var urlComponents = URLComponents(url: baseURL.appendingPathComponent("models/\(model):streamGenerateContent"), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"])
        }
        urlComponents.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        
        guard let url = urlComponents.url else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Google API key not found. Set GOOGLE_API_KEY environment variable."])
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        var googleContents: [[String: Any]] = []
        for msg in allMessages.filter({ $0.role != "system" }) {
            let role = msg.role == "assistant" ? "model" : "user"
            googleContents.append([
                "role": role,
                "parts": [["text": msg.content]]
            ])
        }
        
        var bodyDict: [String: Any] = [
            "contents": googleContents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        
        if !sysPrompt.isEmpty {
            bodyDict["systemInstruction"] = [
                "parts": [["text": sysPrompt]]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        return try await streamGoogleResponse(
            request: request,
            assistantIndex: assistantIndex,
            modelName: model,
            systemPromptUsed: sysPrompt
        )
    }
    
    // MARK: - SSE Response Streaming (OpenAI-compatible)
    
    func streamSSEResponse(
        request: URLRequest,
        assistantIndex: Int,
        provider: String? = nil,
        modelName: String? = nil,
        estimatedPromptTokens: Int? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            if case .cloud(let cloudProvider) = providerType {
                let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: cloudProvider)
                throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
            }
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        
        let updateInterval: TimeInterval = 0.05
        var lastUpdateTime = Date.distantPast
        
        streamLoop: for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break streamLoop }
            guard let data = payload.data(using: .utf8) else { continue }
            
            var didAccumulate = false
            
            if let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    didAccumulate = true
                }
                if let usage = chunk.usage {
                    promptTokens = usage.prompt_tokens
                    completionTokens = usage.completion_tokens
                }
            } else if let ollama = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data) {
                if let content = ollama.message?.content ?? ollama.response {
                    accumulated += content
                    didAccumulate = true
                }
            }
            
            if didAccumulate {
                if Task.isCancelled { break streamLoop }
                
                let now = Date()
                if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                    messages[index].content = accumulated
                    messages = messages
                    lastUpdateTime = now
                }
            }
        }
        
        messages[index].content = accumulated
        messages = messages
        
        if let provider = provider, let modelName = modelName {
            let finalPromptTokens = promptTokens ?? estimatedPromptTokens ?? 0
            let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(accumulated)
            let isEstimated = promptTokens == nil || completionTokens == nil
            
            TokenUsageTracker.shared.recordUsage(
                provider: provider,
                model: modelName,
                promptTokens: finalPromptTokens,
                completionTokens: finalCompletionTokens,
                isEstimated: isEstimated
            )
        }
        
        return accumulated
    }
    
    // MARK: - Anthropic Response Streaming
    
    func streamAnthropicResponse(
        request: URLRequest,
        assistantIndex: Int,
        modelName: String,
        systemPromptUsed: String? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .anthropic)
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        
        let updateInterval: TimeInterval = 0.05
        var lastUpdateTime = Date.distantPast
        
        struct ContentBlockDelta: Decodable {
            struct Delta: Decodable {
                let type: String?
                let text: String?
                let thinking: String?
            }
            let delta: Delta?
        }
        
        streamLoop: for try await line in bytes.lines {
            if Task.isCancelled { break streamLoop }
            
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            
            if let messageStart = try? JSONDecoder().decode(AnthropicMessageStart.self, from: data),
               let usage = messageStart.message?.usage {
                inputTokens = usage.input_tokens
            }
            
            if let messageDelta = try? JSONDecoder().decode(AnthropicMessageDelta.self, from: data),
               let usage = messageDelta.usage {
                outputTokens = usage.output_tokens
            }
            
            if let event = try? JSONDecoder().decode(ContentBlockDelta.self, from: data),
               let delta = event.delta {
                var didAccumulate = false
                
                if let text = delta.text, !text.isEmpty {
                    accumulated += text
                    didAccumulate = true
                }
                
                if didAccumulate {
                    let now = Date()
                    if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                        messages[index].content = accumulated
                        messages = messages
                        lastUpdateTime = now
                    }
                }
            }
        }
        
        messages[index].content = accumulated
        messages = messages
        
        let sysPromptForEstimation = systemPromptUsed ?? systemPrompt
        let finalInputTokens = inputTokens ?? TokenEstimator.estimateTokens(sysPromptForEstimation + messages.map { $0.content }.joined())
        let finalOutputTokens = outputTokens ?? TokenEstimator.estimateTokens(accumulated)
        let isEstimated = inputTokens == nil || outputTokens == nil
        
        TokenUsageTracker.shared.recordUsage(
            provider: "Anthropic",
            model: modelName,
            promptTokens: finalInputTokens,
            completionTokens: finalOutputTokens,
            isEstimated: isEstimated
        )
        
        return accumulated
    }
    
    // MARK: - Google AI Studio Response Streaming
    
    func streamGoogleResponse(
        request: URLRequest,
        assistantIndex: Int,
        modelName: String,
        systemPromptUsed: String? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .google)
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        
        let updateInterval: TimeInterval = 0.05
        var lastUpdateTime = Date.distantPast
        
        struct Part: Decodable { let text: String? }
        struct Content: Decodable { let parts: [Part]?; let role: String? }
        struct Candidate: Decodable { let content: Content? }
        struct UsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
        struct GoogleStreamChunk: Decodable { let candidates: [Candidate]?; let usageMetadata: UsageMetadata? }
        
        streamLoop: for try await line in bytes.lines {
            if Task.isCancelled { break streamLoop }
            
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            
            if let chunk = try? JSONDecoder().decode(GoogleStreamChunk.self, from: data) {
                var didAccumulate = false
                
                if let candidate = chunk.candidates?.first,
                   let content = candidate.content,
                   let parts = content.parts {
                    for part in parts {
                        if let text = part.text, !text.isEmpty {
                            accumulated += text
                            didAccumulate = true
                        }
                    }
                }
                
                if let usage = chunk.usageMetadata {
                    promptTokens = usage.promptTokenCount
                    completionTokens = usage.candidatesTokenCount
                }
                
                if didAccumulate {
                    let now = Date()
                    if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                        messages[index].content = accumulated
                        messages = messages
                        lastUpdateTime = now
                    }
                }
            }
        }
        
        messages[index].content = accumulated
        messages = messages
        
        let sysPromptForEstimation = systemPromptUsed ?? systemPrompt
        let finalPromptTokens = promptTokens ?? TokenEstimator.estimateTokens(sysPromptForEstimation + messages.map { $0.content }.joined())
        let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(accumulated)
        let isEstimated = promptTokens == nil || completionTokens == nil
        
        TokenUsageTracker.shared.recordUsage(
            provider: "Google",
            model: modelName,
            promptTokens: finalPromptTokens,
            completionTokens: finalCompletionTokens,
            isEstimated: isEstimated
        )
        
        return accumulated
    }
}
