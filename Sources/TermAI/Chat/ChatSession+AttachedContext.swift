import Foundation
import TermAIModels

// MARK: - Attached Context Management

extension ChatSession {
    
    /// Add a file to the pending attached contexts (legacy - entire file or single range)
    func attachFile(path: String, content: String, startLine: Int? = nil, endLine: Int? = nil) {
        let context = PinnedContext.file(path: path, content: content, startLine: startLine, endLine: endLine)
        pendingAttachedContexts.append(context)
    }
    
    /// Add a file with multiple line ranges to the pending attached contexts
    func attachFileWithRanges(path: String, selectedContent: String, fullContent: String, lineRanges: [LineRange]) {
        let context = PinnedContext.file(path: path, content: selectedContent, fullContent: fullContent, lineRanges: lineRanges)
        pendingAttachedContexts.append(context)
    }
    
    /// Update line ranges for an existing attached context
    func updateAttachedContextLineRanges(id: UUID, lineRanges: [LineRange]) {
        guard let index = pendingAttachedContexts.firstIndex(where: { $0.id == id }) else { return }
        let existing = pendingAttachedContexts[index]
        
        // Get the full content (either stored or from file)
        let fullContent = existing.fullContent ?? existing.content
        let lines = fullContent.components(separatedBy: .newlines)
        
        // Extract selected content based on new ranges
        let selectedContent: String
        if lineRanges.isEmpty {
            selectedContent = fullContent
        } else {
            var selectedLines: [String] = []
            for range in lineRanges.sorted(by: { $0.start < $1.start }) {
                let startIdx = max(0, range.start - 1)
                let endIdx = min(lines.count, range.end)
                guard startIdx < lines.count else { continue }
                selectedLines.append(contentsOf: lines[startIdx..<endIdx])
            }
            selectedContent = selectedLines.joined(separator: "\n")
        }
        
        // Create updated context
        let updated = PinnedContext(
            id: existing.id,
            type: existing.type,
            path: existing.path,
            displayName: existing.displayName,
            content: selectedContent,
            fullContent: fullContent,
            lineRanges: lineRanges.isEmpty ? nil : lineRanges
        )
        
        pendingAttachedContexts[index] = updated
    }
    
    /// Add terminal output to the pending attached contexts
    func attachTerminalOutput(_ content: String, cwd: String? = nil) {
        let context = PinnedContext.terminal(content: content, cwd: cwd)
        pendingAttachedContexts.append(context)
    }
    
    /// Remove an attached context by ID
    func removeAttachedContext(id: UUID) {
        pendingAttachedContexts.removeAll { $0.id == id }
    }
    
    /// Clear all pending attached contexts
    func clearAttachedContexts() {
        pendingAttachedContexts.removeAll()
    }
    
    /// Consume and return pending attached contexts (used when sending a message)
    func consumeAttachedContexts() -> [PinnedContext] {
        let contexts = pendingAttachedContexts
        pendingAttachedContexts.removeAll()
        return contexts
    }
    
    /// Summarize large attached contexts before sending
    /// This processes contexts that exceed the token threshold and generates summaries
    func summarizeLargeContexts() async {
        // Process each context that needs summarization
        var updatedContexts: [PinnedContext] = []
        
        for context in pendingAttachedContexts {
            if context.isLargeContent && context.summary == nil {
                // Generate summary for large content
                if let summary = await generateContextSummary(context) {
                    var updated = context
                    updated.summary = summary
                    updatedContexts.append(updated)
                } else {
                    updatedContexts.append(context)
                }
            } else {
                updatedContexts.append(context)
            }
        }
        
        pendingAttachedContexts = updatedContexts
    }
    
    /// Generate a summary for a large attached context using the LLM
    func generateContextSummary(_ context: PinnedContext) async -> String? {
        // Skip if model not configured
        guard !model.isEmpty else { return nil }
        
        let prompt = """
        You are summarizing a file that will be used as context for a coding assistant.
        
        File: \(context.displayName)
        Path: \(context.path)
        \(context.language.map { "Language: \($0)" } ?? "")
        
        Provide a concise summary that captures:
        1. The main purpose/functionality of this code
        2. Key functions, classes, or structures defined
        3. Important dependencies or imports
        4. Any notable patterns or configurations
        
        Keep the summary under 500 words. Focus on information that would help an AI understand how to work with or modify this code.
        
        FILE CONTENT:
        ```
        \(context.content.prefix(15000))
        ```
        \(context.content.count > 15000 ? "\n[Content truncated at 15000 characters...]" : "")
        """
        
        do {
            let response = try await requestSimpleCompletion(prompt: prompt, maxTokens: 800)
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AgentDebugConfig.log("[Summary] Failed to generate summary: \(error)")
            return nil
        }
    }
    
    /// Request a simple completion (non-streaming) for utility tasks like summarization
    func requestSimpleCompletion(prompt: String, maxTokens: Int = 500) async throws -> String {
        var messageBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant that summarizes code and technical content concisely."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "stream": false
        ]
        
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]
        
        switch providerType {
        case .cloud(let provider):
            switch provider {
            case .openai:
                url = URL(string: "https://api.openai.com/v1/chat/completions")!
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .openai) {
                    headers["Authorization"] = "Bearer \(key)"
                }
            case .anthropic:
                // For Anthropic, we need to use a different message format
                url = URL(string: "https://api.anthropic.com/v1/messages")!
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) {
                    headers["x-api-key"] = key
                    headers["anthropic-version"] = "2023-06-01"
                }
                // Anthropic uses a different message format
                messageBody = [
                    "model": model,
                    "max_tokens": maxTokens,
                    "messages": [
                        ["role": "user", "content": prompt]
                    ],
                    "system": "You are a helpful assistant that summarizes code and technical content concisely."
                ]
            case .google:
                // Google AI Studio uses a different URL and message format
                url = CloudProvider.google.baseURL.appendingPathComponent("models/\(model):generateContent")
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .google) {
                    headers["x-goog-api-key"] = key
                }
                // Google uses a different message format
                // Note: Gemini 2.5 models use reasoning tokens, so we need more output tokens
                // to accommodate both thinking and the actual response
                messageBody = [
                    "contents": [
                        ["role": "user", "parts": [["text": prompt]]]
                    ],
                    "systemInstruction": [
                        "parts": [["text": "You are a helpful assistant that summarizes code and technical content concisely. Be direct and concise."]]
                    ],
                    "generationConfig": [
                        "maxOutputTokens": max(maxTokens, 2048)  // Ensure enough tokens for reasoning + response
                    ]
                ]
            }
        case .local(let provider):
            switch provider {
            case .ollama:
                url = URL(string: "http://127.0.0.1:11434/api/chat")!
            case .lmStudio:
                url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
            case .vllm:
                url = provider.defaultBaseURL.appendingPathComponent("chat/completions")
            }
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: messageBody)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "Summary", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get summary"])
        }
        
        // Parse response based on provider
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/LM Studio format
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
            // Anthropic format
            if let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return text
            }
            // Google AI format
            if let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text
            }
            // Ollama format
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }
        
        throw NSError(domain: "Summary", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not parse response"])
    }
}
