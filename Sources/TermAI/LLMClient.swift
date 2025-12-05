import Foundation
import os.log

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

// MARK: - Tool Calling Support

/// Result of a tool-enabled completion
struct LLMToolCompletionResult {
    let content: String?
    let toolCalls: [ParsedToolCall]
    let promptTokens: Int
    let completionTokens: Int
    let isEstimated: Bool
    let stopReason: String?
    
    var totalTokens: Int { promptTokens + completionTokens }
    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

// MARK: - Streaming Tool Calling Support

/// Event yielded during streaming tool completion
enum StreamingToolEvent {
    /// Incremental text content from the model
    case textDelta(String)
    /// A tool call has been detected (may have partial arguments initially)
    case toolCallStart(id: String, name: String)
    /// Incremental argument JSON for a tool call
    case toolCallDelta(id: String, argumentsDelta: String)
    /// A tool call is complete with all arguments parsed
    case toolCallComplete(ParsedToolCall)
    /// Token usage information (typically at end of stream)
    case usage(promptTokens: Int, completionTokens: Int)
    /// Stream is complete
    case done(stopReason: String?)
}

/// Accumulator for building tool calls from streaming deltas
final class StreamingToolCallAccumulator {
    private var toolCalls: [String: (name: String, arguments: String)] = [:]
    
    /// Add or update a tool call with streaming delta
    func addDelta(id: String, name: String?, argumentsDelta: String?) {
        if let existing = toolCalls[id] {
            // Append to existing arguments
            let newArgs = existing.arguments + (argumentsDelta ?? "")
            toolCalls[id] = (name: existing.name, arguments: newArgs)
        } else {
            // New tool call
            toolCalls[id] = (name: name ?? "", arguments: argumentsDelta ?? "")
        }
    }
    
    /// Get all completed tool calls
    func getCompletedToolCalls() -> [ParsedToolCall] {
        return toolCalls.compactMap { (id, data) -> ParsedToolCall? in
            guard !data.name.isEmpty else { return nil }
            
            // Parse JSON arguments
            var arguments: [String: Any] = [:]
            if !data.arguments.isEmpty,
               let argsData = data.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                arguments = parsed
            }
            
            return ParsedToolCall(id: id, name: data.name, arguments: arguments)
        }
    }
    
    /// Check if a specific tool call has a name set
    func hasName(for id: String) -> Bool {
        return toolCalls[id]?.name.isEmpty == false
    }
    
    /// Get current state for a tool call
    func getToolCall(id: String) -> (name: String, arguments: String)? {
        return toolCalls[id]
    }
    
    /// Reset the accumulator
    func reset() {
        toolCalls.removeAll()
    }
}

extension LLMClient {
    /// Perform a completion with tool calling support
    /// - Parameters:
    ///   - systemPrompt: System prompt for the model
    ///   - messages: Conversation history as array of [role, content] pairs
    ///   - tools: Tool schemas in provider-specific format
    ///   - provider: The provider type
    ///   - modelId: Model identifier
    ///   - maxTokens: Maximum tokens
    ///   - timeout: Request timeout
    /// - Returns: Result with content and/or tool calls
    func completeWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        provider: ProviderType,
        modelId: String,
        maxTokens: Int = 64000,
        timeout: TimeInterval = 120
    ) async throws -> LLMToolCompletionResult {
        switch provider {
        case .cloud(let cloudProvider):
            switch cloudProvider {
            case .openai:
                return try await completeOpenAIWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            case .anthropic:
                return try await completeAnthropicWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            case .google:
                return try await completeGoogleWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            }
        case .local(let localProvider):
            return try await completeLocalWithTools(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                localProvider: localProvider,
                modelId: modelId,
                maxTokens: maxTokens,
                timeout: timeout
            )
        }
    }
    
    /// Stream a completion with tool calling support
    /// - Parameters:
    ///   - systemPrompt: System prompt for the model
    ///   - messages: Conversation history as array of [role, content] pairs
    ///   - tools: Tool schemas in provider-specific format
    ///   - provider: The provider type
    ///   - modelId: Model identifier
    ///   - maxTokens: Maximum tokens
    ///   - timeout: Request timeout
    /// - Returns: AsyncThrowingStream of StreamingToolEvent
    nonisolated func streamWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        provider: ProviderType,
        modelId: String,
        maxTokens: Int = 64000,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<StreamingToolEvent, Error> {
        switch provider {
        case .cloud(let cloudProvider):
            switch cloudProvider {
            case .openai:
                return streamOpenAIWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            case .anthropic:
                return streamAnthropicWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            case .google:
                return streamGoogleWithTools(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    modelId: modelId,
                    maxTokens: maxTokens,
                    timeout: timeout
                )
            }
        case .local(let localProvider):
            return streamLocalWithTools(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                localProvider: localProvider,
                modelId: modelId,
                maxTokens: maxTokens,
                timeout: timeout
            )
        }
    }
    
    // MARK: - OpenAI with Tools
    
    private func completeOpenAIWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> LLMToolCompletionResult {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
            throw LLMClientError.missingAPIKey(provider: "OpenAI")
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Build messages array with system prompt
        var allMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        allMessages.append(contentsOf: messages)
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "messages": allMessages,
            "stream": false
        ]
        
        // Add tools if provided
        if !tools.isEmpty {
            bodyDict["tools"] = tools
            bodyDict["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("OpenAI tool request: model=\(modelId), tools=\(tools.count)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            llmLogger.error("OpenAI tool call failed (\(http.statusCode)): \(errorBody)")
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .openai)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMClientError.emptyResponse
        }
        
        let content = message["content"] as? String
        let toolCalls = ToolCallParser.parseOpenAI(from: message)
        let finishReason = firstChoice["finish_reason"] as? String
        
        // Parse usage
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0
        
        return LLMToolCompletionResult(
            content: content,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: usage == nil,
            stopReason: finishReason
        )
    }
    
    // MARK: - OpenAI Streaming with Tools
    
    private nonisolated func streamOpenAIWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<StreamingToolEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = timeout
                    
                    guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
                        throw LLMClientError.missingAPIKey(provider: "OpenAI")
                    }
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    
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
                    
                    llmLogger.debug("OpenAI streaming tool request: model=\(modelId), tools=\(tools.count)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.invalidResponse
                    }
                    
                    if !(200..<300).contains(http.statusCode) {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .openai)
                        throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
                    }
                    
                    // Tool call accumulator for building tool calls from deltas
                    let accumulator = StreamingToolCallAccumulator()
                    var emittedToolStarts = Set<String>()
                    var finishReason: String? = nil
                    
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        
                        // Parse OpenAI streaming chunk with tool calls
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        // Check for usage in final chunk
                        if let usage = json["usage"] as? [String: Any],
                           let promptTokens = usage["prompt_tokens"] as? Int,
                           let completionTokens = usage["completion_tokens"] as? Int {
                            continuation.yield(.usage(promptTokens: promptTokens, completionTokens: completionTokens))
                        }
                        
                        // Parse choices
                        guard let choices = json["choices"] as? [[String: Any]],
                              let firstChoice = choices.first else { continue }
                        
                        // Capture finish reason
                        if let reason = firstChoice["finish_reason"] as? String {
                            finishReason = reason
                        }
                        
                        guard let delta = firstChoice["delta"] as? [String: Any] else { continue }
                        
                        // Handle text content delta
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.textDelta(content))
                        }
                        
                        // Handle tool calls delta
                        if let toolCallsArray = delta["tool_calls"] as? [[String: Any]] {
                            for toolCallDelta in toolCallsArray {
                                guard let index = toolCallDelta["index"] as? Int else { continue }
                                
                                // Generate a stable ID based on index if not provided
                                let id = (toolCallDelta["id"] as? String) ?? "tool_\(index)"
                                
                                // Extract function info
                                let function = toolCallDelta["function"] as? [String: Any]
                                let name = function?["name"] as? String
                                let argumentsDelta = function?["arguments"] as? String
                                
                                // Update accumulator
                                accumulator.addDelta(id: id, name: name, argumentsDelta: argumentsDelta)
                                
                                // Emit tool call start when we first see the name
                                if let name = name, !name.isEmpty, !emittedToolStarts.contains(id) {
                                    emittedToolStarts.insert(id)
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                }
                                
                                // Emit argument delta
                                if let argDelta = argumentsDelta, !argDelta.isEmpty {
                                    continuation.yield(.toolCallDelta(id: id, argumentsDelta: argDelta))
                                }
                            }
                        }
                    }
                    
                    // Emit completed tool calls
                    for toolCall in accumulator.getCompletedToolCalls() {
                        continuation.yield(.toolCallComplete(toolCall))
                    }
                    
                    // Emit done
                    continuation.yield(.done(stopReason: finishReason))
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Anthropic with Tools
    
    private func completeAnthropicWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> LLMToolCompletionResult {
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
            "max_tokens": maxTokens
        ]
        
        // Add tools if provided
        if !tools.isEmpty {
            bodyDict["tools"] = tools
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Anthropic tool request: model=\(modelId), tools=\(tools.count)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .anthropic)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw LLMClientError.emptyResponse
        }
        
        // Extract text content
        var textContent: String? = nil
        for block in contentArray {
            if block["type"] as? String == "text",
               let text = block["text"] as? String {
                textContent = text
                break
            }
        }
        
        let toolCalls = ToolCallParser.parseAnthropic(from: contentArray)
        let stopReason = json["stop_reason"] as? String
        
        // Parse usage
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["input_tokens"] as? Int ?? 0
        let completionTokens = usage?["output_tokens"] as? Int ?? 0
        
        return LLMToolCompletionResult(
            content: textContent,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: usage == nil,
            stopReason: stopReason
        )
    }
    
    // MARK: - Anthropic Streaming with Tools
    
    private nonisolated func streamAnthropicWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<StreamingToolEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
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
                    
                    // Track tool calls being built
                    var currentToolId: String? = nil
                    var currentToolName: String = ""
                    var currentToolArgs: String = ""
                    var completedToolCalls: [ParsedToolCall] = []
                    var stopReason: String? = nil
                    var inputTokens: Int? = nil
                    var outputTokens: Int? = nil
                    
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        let eventType = json["type"] as? String ?? ""
                        
                        switch eventType {
                        case "message_start":
                            // Capture input tokens from message start
                            if let message = json["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any] {
                                inputTokens = usage["input_tokens"] as? Int
                            }
                            
                        case "content_block_start":
                            // Check if this is a tool_use block
                            if let contentBlock = json["content_block"] as? [String: Any],
                               let blockType = contentBlock["type"] as? String {
                                if blockType == "tool_use" {
                                    currentToolId = contentBlock["id"] as? String
                                    currentToolName = contentBlock["name"] as? String ?? ""
                                    currentToolArgs = ""
                                    
                                    if let id = currentToolId, !currentToolName.isEmpty {
                                        continuation.yield(.toolCallStart(id: id, name: currentToolName))
                                    }
                                }
                            }
                            
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let deltaType = delta["type"] as? String {
                                
                                if deltaType == "text_delta", let text = delta["text"] as? String {
                                    // Regular text delta
                                    continuation.yield(.textDelta(text))
                                } else if deltaType == "input_json_delta", let partialJson = delta["partial_json"] as? String {
                                    // Tool argument delta
                                    currentToolArgs += partialJson
                                    if let id = currentToolId {
                                        continuation.yield(.toolCallDelta(id: id, argumentsDelta: partialJson))
                                    }
                                }
                            }
                            
                        case "content_block_stop":
                            // Finalize tool call if we were building one
                            if let id = currentToolId, !currentToolName.isEmpty {
                                var arguments: [String: Any] = [:]
                                if !currentToolArgs.isEmpty,
                                   let argsData = currentToolArgs.data(using: .utf8),
                                   let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                                    arguments = parsed
                                }
                                
                                let toolCall = ParsedToolCall(id: id, name: currentToolName, arguments: arguments)
                                completedToolCalls.append(toolCall)
                                continuation.yield(.toolCallComplete(toolCall))
                                
                                // Reset for next tool call
                                currentToolId = nil
                                currentToolName = ""
                                currentToolArgs = ""
                            }
                            
                        case "message_delta":
                            // Capture stop reason and output tokens
                            if let delta = json["delta"] as? [String: Any] {
                                stopReason = delta["stop_reason"] as? String
                            }
                            if let usage = json["usage"] as? [String: Any] {
                                outputTokens = usage["output_tokens"] as? Int
                            }
                            
                        case "message_stop":
                            // Emit usage if available
                            if let input = inputTokens, let output = outputTokens {
                                continuation.yield(.usage(promptTokens: input, completionTokens: output))
                            }
                            
                        default:
                            break
                        }
                    }
                    
                    // Emit done
                    continuation.yield(.done(stopReason: stopReason))
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Google with Tools
    
    private func completeGoogleWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> LLMToolCompletionResult {
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
        
        // Convert messages to Google format
        // Google expects: user, model, and function roles with appropriate parts
        var contents: [[String: Any]] = []
        for msg in messages {
            guard let role = msg["role"] as? String else { continue }
            
            // Handle function response messages (from ToolResultFormatter.functionResponseMessageGoogle)
            if role == "function" {
                if let parts = msg["parts"] as? [[String: Any]] {
                    contents.append(["role": "function", "parts": parts])
                }
                continue
            }
            
            // Handle OpenAI-format tool responses
            if role == "tool" {
                if let toolCallId = msg["tool_call_id"] as? String,
                   let content = msg["content"] as? String {
                    // Convert to Google function response format
                    // Group with previous function responses if possible
                    let functionResponse: [String: Any] = [
                        "functionResponse": [
                            "name": toolCallId, // Use tool_call_id as name fallback
                            "response": ["output": content]
                        ]
                    ]
                    contents.append(["role": "function", "parts": [functionResponse]])
                }
                continue
            }
            
            // Handle assistant messages with tool calls (convert to model with functionCall parts)
            if role == "assistant" {
                var parts: [[String: Any]] = []
                
                // Add text content if present
                if let content = msg["content"] as? String, !content.isEmpty {
                    parts.append(["text": content])
                }
                
                // Convert tool_calls to functionCall parts
                if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        if let function = call["function"] as? [String: Any],
                           let name = function["name"] as? String {
                            var functionCall: [String: Any] = ["name": name]
                            
                            // Parse arguments from JSON string
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
            
            // Handle simple text content (user messages)
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
        
        // Add system instruction
        if !systemPrompt.isEmpty {
            bodyDict["systemInstruction"] = [
                "parts": [["text": systemPrompt]]
            ]
        }
        
        // Add tools if provided (Google format: [{functionDeclarations: [...]}])
        if !tools.isEmpty {
            bodyDict["tools"] = [["functionDeclarations": tools]]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Google tool request: model=\(modelId), tools=\(tools.count)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .google)
            throw LLMClientError.apiError(statusCode: http.statusCode, message: apiError.friendlyMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMClientError.emptyResponse
        }
        
        // Extract text content
        var textContent: String? = nil
        for part in parts {
            if let text = part["text"] as? String {
                textContent = text
                break
            }
        }
        
        let toolCalls = ToolCallParser.parseGoogle(from: parts)
        let finishReason = firstCandidate["finishReason"] as? String
        
        // Parse usage
        let usageMetadata = json["usageMetadata"] as? [String: Any]
        let promptTokens = usageMetadata?["promptTokenCount"] as? Int ?? 0
        let completionTokens = usageMetadata?["candidatesTokenCount"] as? Int ?? 0
        
        return LLMToolCompletionResult(
            content: textContent,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: usageMetadata == nil,
            stopReason: finishReason
        )
    }
    
    // MARK: - Google Streaming with Tools
    
    private nonisolated func streamGoogleWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<StreamingToolEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let baseURL = CloudProvider.google.baseURL
                    guard var urlComponents = URLComponents(url: baseURL.appendingPathComponent("models/\(modelId):streamGenerateContent"), resolvingAgainstBaseURL: false) else {
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
                    
                    // Convert messages to Google format (same as non-streaming)
                    var contents: [[String: Any]] = []
                    for msg in messages {
                        guard let role = msg["role"] as? String else { continue }
                        
                        if role == "function" {
                            if let parts = msg["parts"] as? [[String: Any]] {
                                contents.append(["role": "function", "parts": parts])
                            }
                            continue
                        }
                        
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
                    
                    var completedToolCalls: [ParsedToolCall] = []
                    var emittedToolIds = Set<String>()
                    var finishReason: String? = nil
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil
                    
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        // Parse usage metadata
                        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                            promptTokens = usageMetadata["promptTokenCount"] as? Int
                            completionTokens = usageMetadata["candidatesTokenCount"] as? Int
                        }
                        
                        // Parse candidates
                        guard let candidates = json["candidates"] as? [[String: Any]],
                              let firstCandidate = candidates.first else { continue }
                        
                        // Capture finish reason
                        if let reason = firstCandidate["finishReason"] as? String {
                            finishReason = reason
                        }
                        
                        guard let content = firstCandidate["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]] else { continue }
                        
                        for (index, part) in parts.enumerated() {
                            // Handle text content
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            
                            // Handle function calls (Google typically sends complete function calls)
                            if let functionCall = part["functionCall"] as? [String: Any],
                               let name = functionCall["name"] as? String {
                                let id = "google_call_\(index)"
                                let arguments = functionCall["args"] as? [String: Any] ?? [:]
                                
                                if !emittedToolIds.contains(id) {
                                    emittedToolIds.insert(id)
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                    
                                    // Google sends complete arguments, so emit as delta then complete
                                    if !arguments.isEmpty,
                                       let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                                       let argsStr = String(data: argsData, encoding: .utf8) {
                                        continuation.yield(.toolCallDelta(id: id, argumentsDelta: argsStr))
                                    }
                                    
                                    let toolCall = ParsedToolCall(id: id, name: name, arguments: arguments)
                                    completedToolCalls.append(toolCall)
                                    continuation.yield(.toolCallComplete(toolCall))
                                }
                            }
                        }
                    }
                    
                    // Emit usage if available
                    if let prompt = promptTokens, let completion = completionTokens {
                        continuation.yield(.usage(promptTokens: prompt, completionTokens: completion))
                    }
                    
                    // Emit done
                    continuation.yield(.done(stopReason: finishReason))
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Local with Tools
    
    private func completeLocalWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        localProvider: LocalLLMProvider,
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> LLMToolCompletionResult {
        let baseURL = AgentSettings.shared.baseURL(for: localProvider)
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        // Build messages with system prompt
        var allMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        allMessages.append(contentsOf: messages)
        
        var bodyDict: [String: Any] = [
            "model": modelId,
            "messages": allMessages,
            "stream": false
        ]
        
        // Add tools if provided (OpenAI-compatible format)
        if !tools.isEmpty {
            bodyDict["tools"] = tools
            bodyDict["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        llmLogger.debug("Local tool request: provider=\(localProvider.rawValue), model=\(modelId), tools=\(tools.count)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        
        // Check for tool calling not supported error
        if http.statusCode == 400 || http.statusCode == 422 {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            if errorBody.lowercased().contains("tool") || 
               errorBody.lowercased().contains("function") ||
               errorBody.lowercased().contains("not supported") {
                throw LLMClientError.toolsNotSupported(model: modelId)
            }
        }
        
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMClientError.apiError(statusCode: http.statusCode, message: errorBody)
        }
        
        // Parse OpenAI-compatible response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMClientError.emptyResponse
        }
        
        let content = message["content"] as? String
        let toolCalls = ToolCallParser.parseOpenAI(from: message)
        let finishReason = firstChoice["finish_reason"] as? String
        
        // Parse usage
        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0
        
        return LLMToolCompletionResult(
            content: content,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: usage == nil,
            stopReason: finishReason
        )
    }
    
    // MARK: - Local Streaming with Tools
    
    private nonisolated func streamLocalWithTools(
        systemPrompt: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        localProvider: LocalLLMProvider,
        modelId: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) -> AsyncThrowingStream<StreamingToolEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let baseURL = AgentSettings.shared.baseURL(for: localProvider)
                    let url = baseURL.appendingPathComponent("chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = timeout
                    
                    // Build messages with system prompt
                    var allMessages: [[String: Any]] = [
                        ["role": "system", "content": systemPrompt]
                    ]
                    allMessages.append(contentsOf: messages)
                    
                    var bodyDict: [String: Any] = [
                        "model": modelId,
                        "messages": allMessages,
                        "stream": true
                    ]
                    
                    // Add tools if provided (OpenAI-compatible format)
                    if !tools.isEmpty {
                        bodyDict["tools"] = tools
                        bodyDict["tool_choice"] = "auto"
                    }
                    
                    request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
                    
                    llmLogger.debug("Local streaming tool request: provider=\(localProvider.rawValue), model=\(modelId), tools=\(tools.count)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.invalidResponse
                    }
                    
                    // Check for tool calling not supported error
                    if http.statusCode == 400 || http.statusCode == 422 {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        if errorBody.lowercased().contains("tool") ||
                           errorBody.lowercased().contains("function") ||
                           errorBody.lowercased().contains("not supported") {
                            throw LLMClientError.toolsNotSupported(model: modelId)
                        }
                        throw LLMClientError.apiError(statusCode: http.statusCode, message: errorBody)
                    }
                    
                    if !(200..<300).contains(http.statusCode) {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        throw LLMClientError.apiError(statusCode: http.statusCode, message: errorBody)
                    }
                    
                    // Tool call accumulator (same as OpenAI)
                    let accumulator = StreamingToolCallAccumulator()
                    var emittedToolStarts = Set<String>()
                    var finishReason: String? = nil
                    
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        
                        // Check for usage (some local providers support it)
                        if let usage = json["usage"] as? [String: Any],
                           let promptTokens = usage["prompt_tokens"] as? Int,
                           let completionTokens = usage["completion_tokens"] as? Int {
                            continuation.yield(.usage(promptTokens: promptTokens, completionTokens: completionTokens))
                        }
                        
                        // Parse choices (OpenAI-compatible format)
                        guard let choices = json["choices"] as? [[String: Any]],
                              let firstChoice = choices.first else { continue }
                        
                        if let reason = firstChoice["finish_reason"] as? String {
                            finishReason = reason
                        }
                        
                        guard let delta = firstChoice["delta"] as? [String: Any] else { continue }
                        
                        // Handle text content delta
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.textDelta(content))
                        }
                        
                        // Handle tool calls delta (OpenAI-compatible)
                        if let toolCallsArray = delta["tool_calls"] as? [[String: Any]] {
                            for toolCallDelta in toolCallsArray {
                                guard let index = toolCallDelta["index"] as? Int else { continue }
                                
                                let id = (toolCallDelta["id"] as? String) ?? "tool_\(index)"
                                
                                let function = toolCallDelta["function"] as? [String: Any]
                                let name = function?["name"] as? String
                                let argumentsDelta = function?["arguments"] as? String
                                
                                accumulator.addDelta(id: id, name: name, argumentsDelta: argumentsDelta)
                                
                                if let name = name, !name.isEmpty, !emittedToolStarts.contains(id) {
                                    emittedToolStarts.insert(id)
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                }
                                
                                if let argDelta = argumentsDelta, !argDelta.isEmpty {
                                    continuation.yield(.toolCallDelta(id: id, argumentsDelta: argDelta))
                                }
                            }
                        }
                    }
                    
                    // Emit completed tool calls
                    for toolCall in accumulator.getCompletedToolCalls() {
                        continuation.yield(.toolCallComplete(toolCall))
                    }
                    
                    // Emit done
                    continuation.yield(.done(stopReason: finishReason))
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

