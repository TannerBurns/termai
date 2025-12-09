import Foundation
import os.log
import TermAIModels

private let llmLogger = Logger(subsystem: "com.termai.app", category: "LLMClient")

// MARK: - Completion Result with Usage

/// Result of an LLM completion that includes token usage for real-time tracking
struct LLMCompletionResult {
    let content: String
    let promptTokens: Int
    let completionTokens: Int
    let isEstimated: Bool
    
    var totalTokens: Int { promptTokens + completionTokens }
}

/// Lightweight client for one-shot LLM text completions
/// Uses ModelDefinition for model capabilities (reasoning, context size)
/// Shared across ChatSession and TerminalSuggestionService to avoid code duplication
actor LLMClient {
    static let shared = LLMClient()
    
    private init() {}
    
    // MARK: - Public API
    
    /// Perform a one-shot text completion
    /// - Parameters:
    ///   - systemPrompt: System prompt for the model
    ///   - userPrompt: User prompt/query
    ///   - provider: The provider type (cloud or local)
    ///   - modelId: Model identifier
    ///   - reasoningEffort: Reasoning effort level (for models that support it)
    ///   - temperature: Temperature for generation (ignored for reasoning models)
    ///   - maxTokens: Maximum tokens to generate
    ///   - timeout: Request timeout in seconds
    ///   - requestType: Type of request for usage tracking
    /// - Returns: The model's text response
    func complete(
        systemPrompt: String,
        userPrompt: String,
        provider: ProviderType,
        modelId: String,
        reasoningEffort: ReasoningEffort = .none,
        temperature: Double = 0.3,
        maxTokens: Int = 500,
        timeout: TimeInterval = 30,
        requestType: UsageRequestType = .chat
    ) async throws -> String {
        let result = try await completeWithUsage(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            provider: provider,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: timeout,
            requestType: requestType
        )
        return result.content
    }
    
    /// Perform a one-shot text completion and return token usage for real-time tracking
    /// - Parameters:
    ///   - systemPrompt: System prompt for the model
    ///   - userPrompt: User prompt/query
    ///   - provider: The provider type (cloud or local)
    ///   - modelId: Model identifier
    ///   - reasoningEffort: Reasoning effort level (for models that support it)
    ///   - temperature: Temperature for generation (ignored for reasoning models)
    ///   - maxTokens: Maximum tokens to generate
    ///   - timeout: Request timeout in seconds
    ///   - requestType: Type of request for usage tracking
    /// - Returns: LLMCompletionResult containing the response content and token usage
    func completeWithUsage(
        systemPrompt: String,
        userPrompt: String,
        provider: ProviderType,
        modelId: String,
        reasoningEffort: ReasoningEffort = .none,
        temperature: Double = 0.3,
        maxTokens: Int = 500,
        timeout: TimeInterval = 30,
        requestType: UsageRequestType = .chat
    ) async throws -> LLMCompletionResult {
        // Check for cancellation before making network request
        try Task.checkCancellation()
        
        switch provider {
        case .cloud(let cloudProvider):
            switch cloudProvider {
            case .openai:
                return try await completeOpenAI(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    modelId: modelId,
                    reasoningEffort: reasoningEffort,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    timeout: timeout,
                    requestType: requestType
                )
            case .anthropic:
                return try await completeAnthropic(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    modelId: modelId,
                    reasoningEffort: reasoningEffort,
                    maxTokens: maxTokens,
                    timeout: timeout,
                    requestType: requestType
                )
            case .google:
                return try await completeGoogle(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    modelId: modelId,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    timeout: timeout,
                    requestType: requestType
                )
            }
        case .local(let localProvider):
            return try await completeLocal(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                localProvider: localProvider,
                modelId: modelId,
                temperature: temperature,
                timeout: timeout,
                requestType: requestType
            )
        }
    }
    
    // MARK: - OpenAI
    
    private func completeOpenAI(
        systemPrompt: String,
        userPrompt: String,
        modelId: String,
        reasoningEffort: ReasoningEffort,
        temperature: Double,
        maxTokens: Int,
        timeout: TimeInterval,
        requestType: UsageRequestType
    ) async throws -> LLMCompletionResult {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
            throw LLMClientError.missingAPIKey(provider: "OpenAI")
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Check if model supports reasoning using CuratedModels
        let supportsReasoning = CuratedModels.supportsReasoning(modelId: modelId)
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "stream": false
        ]
        
        // Configure based on reasoning support
        if supportsReasoning {
            // Reasoning models require temperature = 1.0
            bodyDict["temperature"] = 1.0
            bodyDict["max_completion_tokens"] = maxTokens
            // Add reasoning effort if not "none"
            if let reasoningValue = reasoningEffort.openAIValue {
                bodyDict["reasoning_effort"] = reasoningValue
            }
        } else {
            bodyDict["temperature"] = temperature
            bodyDict["max_tokens"] = maxTokens
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("OpenAI request: model=\(modelId), reasoning=\(supportsReasoning)")
        
        let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPrompt + userPrompt)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .openai)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse response
        struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        struct Resp: Decodable { let choices: [Choice]; let usage: Usage? }
        
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LLMClientError.emptyResponse
        }
        
        // Calculate token usage
        let promptTokens = decoded.usage?.prompt_tokens ?? estimatedPromptTokens
        let completionTokens = decoded.usage?.completion_tokens ?? TokenEstimator.estimateTokens(content)
        let isEstimated = decoded.usage == nil
        
        // Record to historical tracker
        await TokenUsageTracker.shared.recordUsage(
            provider: "OpenAI",
            model: modelId,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated,
            requestType: requestType
        )
        
        return LLMCompletionResult(
            content: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated
        )
    }
    
    // MARK: - Anthropic
    
    private func completeAnthropic(
        systemPrompt: String,
        userPrompt: String,
        modelId: String,
        reasoningEffort: ReasoningEffort,
        maxTokens: Int,
        timeout: TimeInterval,
        requestType: UsageRequestType
    ) async throws -> LLMCompletionResult {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) else {
            throw LLMClientError.missingAPIKey(provider: "Anthropic")
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        // Check if model supports extended thinking using CuratedModels
        let supportsReasoning = CuratedModels.supportsReasoning(modelId: modelId)
        let useThinking = supportsReasoning && reasoningEffort != .none
        
        // Add beta header for extended thinking
        if useThinking {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        
        // Configure max_tokens and thinking
        if useThinking, let budgetTokens = reasoningEffort.anthropicBudgetTokens {
            // Extended thinking requires higher max_tokens to accommodate thinking + response
            bodyDict["max_tokens"] = max(maxTokens, budgetTokens + 1000)
            bodyDict["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens
            ]
            llmLogger.info("Anthropic extended thinking enabled: budget=\(budgetTokens)")
        } else {
            bodyDict["max_tokens"] = maxTokens
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Anthropic request: model=\(modelId), thinking=\(useThinking)")
        
        let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPrompt + userPrompt)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            llmLogger.error("Anthropic API error: \(errorBody.prefix(200))")
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .anthropic)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse response (handles both regular and thinking responses)
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        struct ContentBlock: Decodable { 
            let type: String
            let text: String?
            let thinking: String?
        }
        struct Resp: Decodable { let content: [ContentBlock]; let usage: Usage? }
        
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        
        // Log thinking if present (for debugging)
        for block in decoded.content {
            if block.type == "thinking", let thinking = block.thinking {
                llmLogger.debug("Model reasoning: \(thinking.prefix(200))...")
            }
        }
        
        // Get the text response (not the thinking block)
        guard let textBlock = decoded.content.first(where: { $0.type == "text" }),
              let content = textBlock.text else {
            throw LLMClientError.emptyResponse
        }
        
        // Calculate token usage
        let promptTokens = decoded.usage?.input_tokens ?? estimatedPromptTokens
        let completionTokens = decoded.usage?.output_tokens ?? TokenEstimator.estimateTokens(content)
        let isEstimated = decoded.usage == nil
        
        // Record to historical tracker
        await TokenUsageTracker.shared.recordUsage(
            provider: "Anthropic",
            model: modelId,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated,
            requestType: requestType
        )
        
        return LLMCompletionResult(
            content: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated
        )
    }
    
    // MARK: - Google AI Studio (Gemini)
    
    private func completeGoogle(
        systemPrompt: String,
        userPrompt: String,
        modelId: String,
        temperature: Double,
        maxTokens: Int,
        timeout: TimeInterval,
        requestType: UsageRequestType
    ) async throws -> LLMCompletionResult {
        // Google AI Studio uses a different URL format: /models/{model}:generateContent
        let baseURL = CloudProvider.google.baseURL
        let url = baseURL.appendingPathComponent("models/\(modelId):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) else {
            throw LLMClientError.missingAPIKey(provider: "Google")
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        // Google AI Studio request format
        // System instruction is separate from contents
        var bodyDict: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": userPrompt]]]
            ],
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        
        // Add system instruction if provided
        if !systemPrompt.isEmpty {
            bodyDict["systemInstruction"] = [
                "parts": [["text": systemPrompt]]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Google AI request: model=\(modelId)")
        
        let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPrompt + userPrompt)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            llmLogger.error("Google AI API error: \(errorBody.prefix(200))")
            // Parse user-friendly error message using unified error handling
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .google)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse Google AI response format
        struct Part: Decodable { let text: String? }
        struct Content: Decodable { let parts: [Part]?; let role: String? }
        struct Candidate: Decodable { let content: Content? }
        struct UsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
        struct Resp: Decodable { let candidates: [Candidate]?; let usageMetadata: UsageMetadata? }
        
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        
        // Extract text from first candidate's content parts
        guard let candidate = decoded.candidates?.first,
              let content = candidate.content,
              let parts = content.parts,
              let textPart = parts.first(where: { $0.text != nil }),
              let text = textPart.text else {
            throw LLMClientError.emptyResponse
        }
        
        // Calculate token usage
        let promptTokens = decoded.usageMetadata?.promptTokenCount ?? estimatedPromptTokens
        let completionTokens = decoded.usageMetadata?.candidatesTokenCount ?? TokenEstimator.estimateTokens(text)
        let isEstimated = decoded.usageMetadata == nil
        
        // Record to historical tracker
        await TokenUsageTracker.shared.recordUsage(
            provider: "Google",
            model: modelId,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated,
            requestType: requestType
        )
        
        return LLMCompletionResult(
            content: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated
        )
    }
    
    // MARK: - Local LLM
    
    private func completeLocal(
        systemPrompt: String,
        userPrompt: String,
        localProvider: LocalLLMProvider,
        modelId: String,
        temperature: Double,
        timeout: TimeInterval,
        requestType: UsageRequestType
    ) async throws -> LLMCompletionResult {
        // Use the URL from global AgentSettings
        let baseURL = AgentSettings.shared.baseURL(for: localProvider)
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        let bodyDict: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Local request: provider=\(localProvider.rawValue), model=\(modelId)")
        
        let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPrompt + userPrompt)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMClientError.apiError(statusCode: http.statusCode, message: errorBody)
        }
        
        // Try OpenAI-compatible format first, then Ollama format
        struct OAIUsage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        struct OAIChoice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        struct OAIResp: Decodable { let choices: [OAIChoice]; let usage: OAIUsage? }
        
        struct OllamaResp: Decodable { 
            struct Message: Decodable { let content: String? }
            let message: Message?
            let response: String?
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        
        var content: String = ""
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        
        if let oai = try? JSONDecoder().decode(OAIResp.self, from: data),
           let text = oai.choices.first?.message.content {
            content = text
            promptTokens = oai.usage?.prompt_tokens
            completionTokens = oai.usage?.completion_tokens
        } else if let ollama = try? JSONDecoder().decode(OllamaResp.self, from: data) {
            content = ollama.message?.content ?? ollama.response ?? ""
            promptTokens = ollama.prompt_eval_count
            completionTokens = ollama.eval_count
        } else {
            content = String(data: data, encoding: .utf8) ?? ""
        }
        
        if content.isEmpty {
            throw LLMClientError.emptyResponse
        }
        
        // Calculate token usage
        let finalPromptTokens = promptTokens ?? estimatedPromptTokens
        let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(content)
        let isEstimated = promptTokens == nil || completionTokens == nil
        
        // Record to historical tracker
        await TokenUsageTracker.shared.recordUsage(
            provider: localProvider.rawValue,
            model: modelId,
            promptTokens: finalPromptTokens,
            completionTokens: finalCompletionTokens,
            isEstimated: isEstimated,
            requestType: requestType
        )
        
        return LLMCompletionResult(
            content: content,
            promptTokens: finalPromptTokens,
            completionTokens: finalCompletionTokens,
            isEstimated: isEstimated
        )
    }
}

// MARK: - Errors

enum LLMClientError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, message: String)
    case toolsNotSupported(model: String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not configured"
        case .invalidResponse:
            return "Invalid response from server"
        case .emptyResponse:
            return "Empty response from model"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .toolsNotSupported(let model):
            return "Agent mode is not available with '\(model)'. This model does not support tool/function calling. Please select a different model or use chat mode instead."
        }
}
}

// MARK: - Tool Support Checking

extension LLMClient {
    /// Check if a local model supports tool/function calling
    /// Returns nil to indicate unknown - we assume the user has chosen a capable model
    /// If tool calling fails at runtime, the error will be handled gracefully
    func checkToolSupport(provider: LocalLLMProvider, modelId: String) async -> Bool? {
        // Don't try to detect tool support - assume the user knows their model
        // Runtime errors will be caught and reported if the model doesn't support tools
        return nil
    }
}

// MARK: - Streaming Tool Calling Support

extension LLMClient {
    
    /// Perform a streaming completion with tool calling support
    /// Returns an AsyncThrowingStream of LLMStreamEvent for real-time updates
    nonisolated func completeWithToolsStream(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        provider: ProviderType,
        modelId: String,
        maxTokens: Int = 64000,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
        switch provider {
        case .cloud(let cloudProvider):
            switch cloudProvider {
            case .openai:
                            try await streamOpenAICompatibleWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                                timeout: timeout,
                                baseURL: URL(string: "https://api.openai.com/v1")!,
                                apiKey: CloudAPIKeyManager.shared.getAPIKey(for: .openai),
                                provider: .openai,
                                continuation: continuation
                )
            case .anthropic:
                            try await streamAnthropicWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                                timeout: timeout,
                                continuation: continuation
                )
            case .google:
                            try await streamGoogleWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                                timeout: timeout,
                                continuation: continuation
                )
            }
        case .local(let localProvider):
                        let baseURL = AgentSettings.shared.baseURL(for: localProvider)
                        try await streamOpenAICompatibleWithTools(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                modelId: modelId,
                maxTokens: maxTokens,
                            timeout: timeout,
                            baseURL: baseURL,
                            apiKey: nil,
                            provider: nil,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - OpenAI-Compatible Streaming (OpenAI + Local providers)
    
    private func streamOpenAICompatibleWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval,
        baseURL: URL,
        apiKey: String?,
        provider: CloudProvider?,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        if let apiKey = apiKey {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Build messages array with system prompt
        var allMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        allMessages.append(contentsOf: messages)
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "messages": allMessages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        
        // Add tools if provided
        if !tools.isEmpty {
            bodyDict["tools"] = tools
            bodyDict["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("OpenAI-compatible streaming tool request: model=\(modelId), tools=\(tools.count)")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            if let cloudProvider = provider {
                let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: cloudProvider)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
            throw LLMClientError.apiError(statusCode: http.statusCode, message: errorBody)
        }
        
        // Track tool calls being accumulated
        var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String? = nil
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]] else {
                continue
            }
            
            // Check for usage in the chunk
            if let usage = json["usage"] as? [String: Any] {
                let promptTokens = usage["prompt_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? 0
                continuation.yield(.usage(prompt: promptTokens, completion: completionTokens))
            }
            
            guard let firstChoice = choices.first else { continue }
            
            // Check for finish reason
            if let reason = firstChoice["finish_reason"] as? String {
                finishReason = reason
            }
            
            guard let delta = firstChoice["delta"] as? [String: Any] else { continue }
            
            // Handle text content delta
            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }
            
            // Handle tool call deltas
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    guard let index = toolCall["index"] as? Int else { continue }
                    
                    // Initialize new tool call
                    if let id = toolCall["id"] as? String {
                        let function = toolCall["function"] as? [String: Any]
                        let name = function?["name"] as? String ?? ""
                        toolCallAccumulators[index] = (id: id, name: name, arguments: "")
                        
                        if !name.isEmpty {
                            continuation.yield(.toolCallStart(id: id, name: name))
                        }
                    }
                    
                    // Accumulate function arguments
                    if let function = toolCall["function"] as? [String: Any],
                       let argsDelta = function["arguments"] as? String,
                       !argsDelta.isEmpty {
                        if var accumulator = toolCallAccumulators[index] {
                            accumulator.arguments += argsDelta
                            toolCallAccumulators[index] = accumulator
                            continuation.yield(.toolCallArgumentDelta(id: accumulator.id, delta: argsDelta))
                        }
                    }
                }
            }
        }
        
        // Emit completed tool calls
        for (_, accumulator) in toolCallAccumulators.sorted(by: { $0.key < $1.key }) {
            var arguments: [String: Any] = [:]
            if let argsData = accumulator.arguments.data(using: .utf8),
               let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                arguments = argsDict
            }
            
            let parsedCall = ParsedToolCall(
                id: accumulator.id,
                name: accumulator.name,
                arguments: arguments
            )
            continuation.yield(.toolCallComplete(parsedCall))
        }
        
        // Emit stop reason if available
        if let reason = finishReason {
            continuation.yield(.stopReason(reason))
        }
        
        continuation.yield(.done)
    }
    
    // MARK: - Anthropic Streaming with Tools
    
    private func streamAnthropicWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) else {
            throw LLMClientError.missingAPIKey(provider: "Anthropic")
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "system": systemPrompt,
            "messages": messages,
            "max_tokens": maxTokens,
            "stream": true
        ]
        
        // Add tools if provided
        if !tools.isEmpty {
            bodyDict["tools"] = tools
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Anthropic streaming tool request: model=\(modelId), tools=\(tools.count)")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .anthropic)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Track content blocks being accumulated
        var currentBlockIndex: Int = -1
        var currentBlockType: String = ""
        var currentToolUseId: String = ""
        var currentToolName: String = ""
        var currentToolArguments: String = ""
        var stopReason: String? = nil
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            let eventType = json["type"] as? String ?? ""
            
            switch eventType {
            case "message_start":
                // Extract input tokens from message usage
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let inputTokens = usage["input_tokens"] as? Int {
                    // We'll get output tokens at the end
                    continuation.yield(.usage(prompt: inputTokens, completion: 0))
                }
                
            case "content_block_start":
                currentBlockIndex = json["index"] as? Int ?? -1
                if let contentBlock = json["content_block"] as? [String: Any] {
                    currentBlockType = contentBlock["type"] as? String ?? ""
                    
                    if currentBlockType == "tool_use" {
                        currentToolUseId = contentBlock["id"] as? String ?? ""
                        currentToolName = contentBlock["name"] as? String ?? ""
                        currentToolArguments = ""
                        continuation.yield(.toolCallStart(id: currentToolUseId, name: currentToolName))
                    }
                }
                
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String ?? ""
                    
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        continuation.yield(.textDelta(text))
                    } else if deltaType == "input_json_delta", let partialJson = delta["partial_json"] as? String {
                        currentToolArguments += partialJson
                        continuation.yield(.toolCallArgumentDelta(id: currentToolUseId, delta: partialJson))
                    }
                }
                
            case "content_block_stop":
                // If we just finished a tool_use block, emit the complete tool call
                if currentBlockType == "tool_use" {
                    var arguments: [String: Any] = [:]
                    if let argsData = currentToolArguments.data(using: .utf8),
                       let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        arguments = argsDict
                    }
                    
                    let parsedCall = ParsedToolCall(
                        id: currentToolUseId,
                        name: currentToolName,
                        arguments: arguments
                    )
                    continuation.yield(.toolCallComplete(parsedCall))
                }
                currentBlockType = ""
                
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                }
                // Extract output tokens
                if let usage = json["usage"] as? [String: Any],
                   let outputTokens = usage["output_tokens"] as? Int {
                    continuation.yield(.usage(prompt: 0, completion: outputTokens))
                }
                
            case "message_stop":
                if let reason = stopReason {
                    continuation.yield(.stopReason(reason))
                }
                
            default:
                break
            }
        }
        
        continuation.yield(.done)
    }
    
    // MARK: - Google Streaming with Tools
    
    private func streamGoogleWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let baseURL = CloudProvider.google.baseURL
        guard var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("models/\(modelId):streamGenerateContent"),
            resolvingAgainstBaseURL: false
        ) else {
            throw LLMClientError.invalidResponse
        }
        urlComponents.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        
        guard let url = urlComponents.url else {
            throw LLMClientError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) else {
            throw LLMClientError.missingAPIKey(provider: "Google")
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        // Convert messages to Google format
        var contents: [[String: Any]] = []
        for msg in messages {
            guard let role = msg["role"] as? String else { continue }
            
            // Handle function response messages
            if role == "function" {
                if let parts = msg["parts"] as? [[String: Any]] {
                    contents.append(["role": "function", "parts": parts])
                }
                continue
            }
            
            // Handle tool responses
            if role == "tool" {
                if let toolCallId = msg["tool_call_id"] as? String,
                   let content = msg["content"] as? String {
                    let functionResponse: [String: Any] = [
                        "functionResponse": [
                            "name": toolCallId,
                            "response": ["output": content]
                        ]
                    ]
                    contents.append(["role": "function", "parts": [functionResponse]])
                }
                continue
            }
            
            // Handle assistant messages with tool calls
            if role == "assistant" {
                var parts: [[String: Any]] = []
                
                if let content = msg["content"] as? String, !content.isEmpty {
                    parts.append(["text": content])
                }
                
                if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        if let function = call["function"] as? [String: Any],
                           let name = function["name"] as? String {
                            var functionCall: [String: Any] = ["name": name]
                            
                            if let argsStr = function["arguments"] as? String,
                               let argsData = argsStr.data(using: .utf8),
                               let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                                functionCall["args"] = args
                            }
                            
                            parts.append(["functionCall": functionCall])
                        }
                    }
                }
                
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
                continue
            }
            
            // Handle user messages
            if let content = msg["content"] as? String {
                let googleRole = role == "assistant" ? "model" : "user"
                contents.append(["role": googleRole, "parts": [["text": content]]])
            }
        }
        
        var bodyDict: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": maxTokens
            ]
        ]
        
        if !systemPrompt.isEmpty {
            bodyDict["systemInstruction"] = [
                "parts": [["text": systemPrompt]]
            ]
        }
        
        if !tools.isEmpty {
            bodyDict["tools"] = [["functionDeclarations": tools]]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Google streaming tool request: model=\(modelId), tools=\(tools.count)")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        if !(200..<300).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .google)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        var toolCallIndex = 0
        var finishReason: String? = nil
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            // Handle usage metadata
            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                let promptTokens = usageMetadata["promptTokenCount"] as? Int ?? 0
                let completionTokens = usageMetadata["candidatesTokenCount"] as? Int ?? 0
                continuation.yield(.usage(prompt: promptTokens, completion: completionTokens))
            }
            
            guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
                continue
        }
        
            // Check for finish reason
            if let reason = firstCandidate["finishReason"] as? String {
                finishReason = reason
            }
            
            for part in parts {
                // Handle text content
                if let text = part["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
    }
    
                // Handle function calls
                if let functionCall = part["functionCall"] as? [String: Any],
                   let name = functionCall["name"] as? String {
                    let id = "google_call_\(toolCallIndex)"
                    toolCallIndex += 1
                    
                    continuation.yield(.toolCallStart(id: id, name: name))
                    
                    let arguments = functionCall["args"] as? [String: Any] ?? [:]
                    
                    // For Google, we get complete function calls, so emit the args as one delta
                    if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                       let argsString = String(data: argsData, encoding: .utf8) {
                        continuation.yield(.toolCallArgumentDelta(id: id, delta: argsString))
                    }
                    
                    let parsedCall = ParsedToolCall(id: id, name: name, arguments: arguments)
                    continuation.yield(.toolCallComplete(parsedCall))
            }
        }
        }
        
        if let reason = finishReason {
            continuation.yield(.stopReason(reason))
        }
        
        continuation.yield(.done)
    }
}

// MARK: - Simple Streaming (No Tools)

extension LLMClient {
    
    /// Perform a simple streaming completion without tool support
    /// Useful for one-shot completions where you want streaming feedback
    nonisolated func completeStream(
        systemPrompt: String,
        userPrompt: String,
        provider: ProviderType,
        modelId: String,
        temperature: Double = 0.3,
        maxTokens: Int = 500,
        timeout: TimeInterval = 30
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // Use the tool-enabled stream with empty tools array
        // This gives us consistent streaming behavior
        let messages: [[String: Any]] = [
            ["role": "user", "content": userPrompt]
        ]
        
        return completeWithToolsStream(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: [],
            provider: provider,
            modelId: modelId,
            maxTokens: maxTokens,
            timeout: timeout
        )
    }
}

