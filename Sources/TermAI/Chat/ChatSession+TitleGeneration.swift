import Foundation
import TermAIModels
import os.log

private let titleLogger = Logger(subsystem: "com.termai.app", category: "TitleGeneration")

// MARK: - Title Generation

extension ChatSession {
    
    func generateTitle(from userMessage: String) async {
        titleLogger.info("Starting title generation for message: \(userMessage.prefix(50))...")
        
        // Clear any previous error
        await MainActor.run { [weak self] in
            self?.titleGenerationError = nil
        }
        
        // Skip if model is not set
        guard !model.isEmpty else {
            titleLogger.error("Title generation skipped: model is empty")
            await MainActor.run { [weak self] in
                self?.titleGenerationError = ChatAPIError(
                    friendlyMessage: "Cannot generate title: No model selected",
                    fullDetails: "No model is currently selected. Please select a model in settings."
                )
            }
            return
        }
        
        // Run title generation in a separate task on MainActor to access ChatSession properties
        let titleTask = Task { @MainActor [weak self] in
            guard let self = self else {
                titleLogger.error("Title generation: self is nil, aborting")
                return
            }
            titleLogger.info("Title generation task started for provider: \(self.providerName), model: \(self.model)")
            
            let titlePrompt = """
            Generate a concise 2-5 word title for a chat conversation that starts with this user message. \
            The title should capture the main topic or intent. \
            Only respond with the title itself, no quotes, no explanation.
            
            User message: \(userMessage)
            """
            
            // Determine the correct URL based on provider type
            let url: URL
            if case .cloud(let cloudProvider) = self.providerType {
                switch cloudProvider {
                case .openai:
                    url = URL(string: "https://api.openai.com/v1/chat/completions")!
                case .anthropic:
                    url = URL(string: "https://api.anthropic.com/v1/messages")!
                case .google:
                    url = CloudProvider.google.baseURL.appendingPathComponent("models/\(self.model):generateContent")
                }
            } else {
                url = self.apiBaseURL.appendingPathComponent("chat/completions")
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60.0
            
            // Set up authentication based on provider
            if case .cloud(let cloudProvider) = self.providerType {
                switch cloudProvider {
                case .openai:
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                case .anthropic:
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) {
                        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
                case .google:
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) {
                        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    }
                }
            } else if let apiKey = self.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            // Build request body based on provider
            let requestData: Data
            do {
                if case .cloud(let cloudProvider) = self.providerType {
                    switch cloudProvider {
                    case .openai:
                        var bodyDict: [String: Any] = [
                            "model": self.model,
                            "messages": [
                                ["role": "system", "content": "You are a helpful assistant that generates concise titles."],
                                ["role": "user", "content": titlePrompt]
                            ],
                            "stream": false
                        ]
                        if self.currentModelSupportsReasoning {
                            bodyDict["temperature"] = 1.0
                        } else {
                            bodyDict["temperature"] = self.temperature
                        }
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                        
                    case .anthropic:
                        let bodyDict: [String: Any] = [
                            "model": self.model,
                            "max_tokens": 1024,
                            "system": "You are a helpful assistant that generates concise titles.",
                            "messages": [
                                ["role": "user", "content": titlePrompt]
                            ]
                        ]
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                        
                    case .google:
                        let bodyDict: [String: Any] = [
                            "contents": [
                                ["role": "user", "parts": [["text": titlePrompt]]]
                            ],
                            "systemInstruction": [
                                "parts": [["text": "You are a helpful assistant that generates concise titles. Respond with ONLY the title, nothing else."]]
                            ],
                            "generationConfig": [
                                "temperature": self.temperature
                            ]
                        ]
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                    }
                } else {
                    // Local provider format (Ollama, LM Studio, vLLM)
                    let bodyDict: [String: Any] = [
                        "model": self.model,
                        "messages": [
                            ["role": "system", "content": "You are a helpful assistant that generates concise titles."],
                            ["role": "user", "content": titlePrompt]
                        ],
                        "stream": false,
                        "temperature": self.temperature
                    ]
                    requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                }
                request.httpBody = requestData
                
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60.0
                config.timeoutIntervalForResource = 60.0
                let session = URLSession(configuration: config)
                
                titleLogger.info("Title generation: making HTTP request...")
                let (data, response) = try await session.data(for: request)
                titleLogger.info("Title generation: received response")
                
                guard !Task.isCancelled else {
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Title generation was cancelled",
                            fullDetails: "The title generation request was cancelled by the user."
                        )
                    }
                    return
                }
                
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Invalid response from server",
                            fullDetails: "The server returned an invalid response that could not be processed."
                        )
                    }
                    return
                }
                
                guard (200..<300).contains(http.statusCode) else {
                    titleLogger.error("Title generation HTTP error: \(http.statusCode)")
                    let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                    let apiError: ChatAPIError
                    if case .cloud(let cloudProvider) = self.providerType {
                        apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: cloudProvider)
                    } else {
                        apiError = ChatAPIError(
                            friendlyMessage: "Title generation failed (HTTP \(http.statusCode))",
                            fullDetails: "HTTP \(http.statusCode): \(errorBody)",
                            statusCode: http.statusCode,
                            provider: self.providerName
                        )
                    }
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = apiError
                    }
                    return
                }
                
                // Response format structs with usage
                struct OpenAIUsage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
                struct OpenAIChoice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                struct OpenAIResponse: Decodable { let choices: [OpenAIChoice]; let usage: OpenAIUsage? }
                
                struct OllamaResponse: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message?
                    let response: String?
                    let prompt_eval_count: Int?
                    let eval_count: Int?
                }
                
                struct AnthropicUsage: Decodable { let input_tokens: Int; let output_tokens: Int }
                struct AnthropicContentBlock: Decodable { let type: String; let text: String? }
                struct AnthropicResponse: Decodable { let content: [AnthropicContentBlock]; let usage: AnthropicUsage? }
                
                struct GooglePart: Decodable { let text: String? }
                struct GoogleContent: Decodable { let parts: [GooglePart]?; let role: String? }
                struct GoogleCandidate: Decodable { let content: GoogleContent? }
                struct GoogleUsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
                struct GoogleResponse: Decodable { let candidates: [GoogleCandidate]?; let usageMetadata: GoogleUsageMetadata? }
                
                var generatedTitle: String? = nil
                var promptTokens: Int? = nil
                var completionTokens: Int? = nil
                
                let systemPromptForTitle = "You are a helpful assistant that generates concise titles."
                let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPromptForTitle + titlePrompt)
                
                titleLogger.info("Title generation: parsing response for provider type")
                
                if case .cloud(let cloudProvider) = self.providerType, cloudProvider == .anthropic {
                    titleLogger.info("Title generation: parsing as Anthropic response")
                    if let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data),
                       let textBlock = decoded.content.first(where: { $0.type == "text" }),
                       let text = textBlock.text {
                        generatedTitle = text
                        promptTokens = decoded.usage?.input_tokens
                        completionTokens = decoded.usage?.output_tokens
                    }
                } else if case .cloud(let cloudProvider) = self.providerType, cloudProvider == .google {
                    if let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data),
                       let candidate = decoded.candidates?.first,
                       let content = candidate.content,
                       let parts = content.parts,
                       let textPart = parts.first(where: { $0.text != nil }),
                       let text = textPart.text {
                        generatedTitle = text
                        promptTokens = decoded.usageMetadata?.promptTokenCount
                        completionTokens = decoded.usageMetadata?.candidatesTokenCount
                    } else {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let candidates = json["candidates"] as? [[String: Any]],
                           let firstCandidate = candidates.first,
                           let content = firstCandidate["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let firstPart = parts.first,
                           let text = firstPart["text"] as? String {
                            generatedTitle = text
                            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                                promptTokens = usageMetadata["promptTokenCount"] as? Int
                                completionTokens = usageMetadata["candidatesTokenCount"] as? Int
                            }
                        }
                    }
                } else {
                    do {
                        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                        if let title = decoded.choices.first?.message.content {
                            generatedTitle = title
                            promptTokens = decoded.usage?.prompt_tokens
                            completionTokens = decoded.usage?.completion_tokens
                        }
                    } catch {
                        do {
                            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
                            generatedTitle = decoded.message?.content ?? decoded.response
                            promptTokens = decoded.prompt_eval_count
                            completionTokens = decoded.eval_count
                        } catch {
                            // Failed to decode both formats
                            titleLogger.error("Title generation: failed to decode response as OpenAI or Ollama format")
                            let responsePreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "unable to decode"
                            titleLogger.error("Response preview: \(responsePreview)")
                        }
                    }
                }
                
                titleLogger.info("Title generation: parsed title = \(generatedTitle ?? "nil")")
                
                if let title = generatedTitle {
                    titleLogger.info("Title generation: success! Setting title: \(title)")
                    let finalPromptTokens = promptTokens ?? estimatedPromptTokens
                    let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(title)
                    let isEstimated = promptTokens == nil || completionTokens == nil
                    
                    let providerForTracking: String
                    if case .cloud(let cloudProvider) = self.providerType {
                        switch cloudProvider {
                        case .anthropic: providerForTracking = "Anthropic"
                        case .google: providerForTracking = "Google"
                        case .openai: providerForTracking = "OpenAI"
                        }
                    } else {
                        providerForTracking = self.providerName
                    }
                    
                    TokenUsageTracker.shared.recordUsage(
                        provider: providerForTracking,
                        model: self.model,
                        promptTokens: finalPromptTokens,
                        completionTokens: finalCompletionTokens,
                        isEstimated: isEstimated,
                        requestType: .titleGeneration
                    )
                    
                    await MainActor.run { [weak self] in
                        self?.sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.titleGenerationError = nil
                        self?.persistSettings()
                    }
                } else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    let providerInfo = self.providerName
                    let modelInfo = self.model
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Could not parse title from response",
                            fullDetails: """
                            Provider: \(providerInfo)
                            Model: \(modelInfo)
                            
                            Response body:
                            \(responseBody)
                            """,
                            provider: providerInfo
                        )
                    }
                }
            } catch {
                titleLogger.error("Title generation exception: \(error.localizedDescription)")
                let apiError: ChatAPIError
                if let urlError = error as? URLError {
                    let friendlyMessage: String
                    switch urlError.code {
                    case .timedOut:
                        friendlyMessage = "Request timed out"
                    case .notConnectedToInternet:
                        friendlyMessage = "No internet connection"
                    case .cannotConnectToHost:
                        friendlyMessage = "Cannot connect to server"
                    default:
                        friendlyMessage = "Network error"
                    }
                    apiError = ChatAPIError(
                        friendlyMessage: friendlyMessage,
                        fullDetails: "URLError: \(urlError.localizedDescription)\nCode: \(urlError.code.rawValue)"
                    )
                } else {
                    apiError = ChatAPIError(
                        friendlyMessage: "Title generation error",
                        fullDetails: error.localizedDescription
                    )
                }
                
                await MainActor.run { [weak self] in
                    self?.titleGenerationError = apiError
                }
            }
        }
        
        // Cancel the task if it takes more than 90 seconds
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)  // 90 seconds
            if !titleTask.isCancelled {
                titleTask.cancel()
                await MainActor.run { [weak self] in
                    if self?.sessionTitle.isEmpty == true {
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Title generation timed out",
                            fullDetails: "The request took longer than 90 seconds and was cancelled."
                        )
                    }
                }
            }
        }
    }
}
