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

// MARK: - Errors

enum LLMClientError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, message: String)
    
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
        }
    }
}

