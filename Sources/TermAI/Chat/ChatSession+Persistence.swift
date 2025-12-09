import Foundation
import TermAIModels

// MARK: - Session Settings Type

/// Settings that are persisted for each session
struct SessionSettings: Codable {
    let apiBaseURL: String
    let apiKey: String?
    let model: String
    let providerName: String
    let systemPrompt: String? // Kept for backward compatibility but no longer used
    let sessionTitle: String?
    let agentMode: AgentMode?
    let agentProfile: AgentProfile?
    
    // Generation settings
    let temperature: Double?
    let maxTokens: Int?
    let reasoningEffort: ReasoningEffort?
    let providerType: ProviderType?
    
    // Provider configuration tracking
    let hasExplicitlyConfiguredProvider: Bool?
    
    // Context size settings
    let customLocalContextSize: Int?
    
    // Context tracking (per-session)
    let currentContextTokens: Int?
    let contextLimitTokens: Int?
    let lastSummarizationDate: Date?
    let summarizationCount: Int?
    
    // Navigator mode - current plan being implemented
    let currentPlanId: UUID?
}

// MARK: - Persistence

extension ChatSession {
    
    /// Persist messages with debouncing to reduce disk I/O during streaming
    func persistMessages() {
        persistDebounceItem?.cancel()
        // Capture messages immediately to avoid race conditions
        let messagesToSave = messages
        let fileName = messagesFileName
        let item = DispatchWorkItem {
            // Save on background thread
            PersistenceService.saveJSONInBackground(messagesToSave, to: fileName)
        }
        persistDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: item)
    }
    
    /// Force immediate persistence for critical events (session close, app quit)
    func persistMessagesImmediately() {
        persistDebounceItem?.cancel()
        persistDebounceItem = nil
        // Synchronous save for critical paths (app quit)
        try? PersistenceService.saveJSON(messages, to: messagesFileName)
    }
    
    func loadMessages() {
        if let m = try? PersistenceService.loadJSON([ChatMessage].self, from: messagesFileName) {
            messages = m
        }
        // Also load checkpoints alongside messages
        loadCheckpoints()
    }
    
    func persistSettings() {
        let settings = SessionSettings(
            apiBaseURL: apiBaseURL.absoluteString,
            apiKey: apiKey,
            model: model,
            providerName: providerName,
            systemPrompt: nil,  // No longer used
            sessionTitle: sessionTitle,
            agentMode: agentMode,
            agentProfile: agentProfile,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            providerType: providerType,
            hasExplicitlyConfiguredProvider: hasExplicitlyConfiguredProvider,
            customLocalContextSize: customLocalContextSize,
            currentContextTokens: currentContextTokens,
            contextLimitTokens: contextLimitTokens,
            lastSummarizationDate: lastSummarizationDate,
            summarizationCount: summarizationCount,
            currentPlanId: currentPlanId
        )
        // Use background save for settings (not critical path)
        PersistenceService.saveJSONInBackground(settings, to: "session-settings-\(id.uuidString).json")
    }
    
    func loadSettings() {
        if let settings = try? PersistenceService.loadJSON(SessionSettings.self, from: "session-settings-\(id.uuidString).json") {
            if let url = URL(string: settings.apiBaseURL) { apiBaseURL = url }
            apiKey = settings.apiKey
            model = settings.model
            providerName = settings.providerName
            // Note: systemPrompt is no longer loaded from settings - using hard-coded prompt
            sessionTitle = settings.sessionTitle ?? ""
            agentMode = settings.agentMode ?? .scout
            agentProfile = settings.agentProfile ?? .general
            // Initialize activeProfile (will be dynamically managed in Auto mode)
            let loadedProfile = settings.agentProfile ?? .general
            activeProfile = loadedProfile.isAuto ? .general : loadedProfile
            
            // Load generation settings
            temperature = settings.temperature ?? 0.7
            maxTokens = settings.maxTokens ?? 4096
            reasoningEffort = settings.reasoningEffort ?? .medium
            providerType = settings.providerType ?? .local(.ollama)
            
            // Load provider configuration status (defaults to false for backward compatibility)
            hasExplicitlyConfiguredProvider = settings.hasExplicitlyConfiguredProvider ?? false
            
            // Load context size settings
            customLocalContextSize = settings.customLocalContextSize
            
            // Load context tracking (per-session)
            if let tokens = settings.currentContextTokens {
                currentContextTokens = tokens
            }
            if let limit = settings.contextLimitTokens {
                contextLimitTokens = limit
            }
            lastSummarizationDate = settings.lastSummarizationDate
            if let count = settings.summarizationCount {
                summarizationCount = count
            }
            
            // Load Navigator mode state
            currentPlanId = settings.currentPlanId
        }
        
        // Update context limit based on model (only if not already loaded from settings)
        if contextLimitTokens == 32_000 {
            updateContextLimit()
        }
        
        // After loading settings, fetch models for selected provider
        Task { await fetchAvailableModels() }
    }
}

// MARK: - Provider Switching

extension ChatSession {
    
    /// Switch to a cloud provider
    func switchToCloudProvider(_ provider: CloudProvider) {
        providerType = .cloud(provider)
        providerName = provider.rawValue
        apiBaseURL = provider.baseURL
        apiKey = CloudAPIKeyManager.shared.getAPIKey(for: provider)
        model = "" // Reset model selection
        hasExplicitlyConfiguredProvider = true // User explicitly chose this provider
        availableModels = CuratedModels.models(for: provider).map { $0.id }
        persistSettings()
    }
    
    /// Switch to a local provider
    func switchToLocalProvider(_ provider: LocalLLMProvider) {
        providerType = .local(provider)
        providerName = provider.rawValue
        // Use the URL from global AgentSettings
        apiBaseURL = AgentSettings.shared.baseURL(for: provider)
        apiKey = nil
        model = "" // Reset model selection
        hasExplicitlyConfiguredProvider = true // User explicitly chose this provider
        persistSettings()
        Task { await fetchAvailableModels() }
    }
}

// MARK: - Context Tracking

extension ChatSession {
    
    /// Update the context limit based on the current model
    func updateContextLimit() {
        if providerType.isLocal {
            // For local models, use custom size if set, otherwise use TokenEstimator fallback
            if let custom = customLocalContextSize {
                contextLimitTokens = custom
            } else {
                contextLimitTokens = TokenEstimator.contextLimit(for: model)
            }
        } else {
            // For cloud models, use ModelDefinition if available
            contextLimitTokens = ModelDefinition.contextSize(for: model)
        }
    }
    
    /// Update the current context usage based on messages and agent context
    /// During agent execution, this is a no-op since we use actual API-reported tokens
    func updateContextUsage(persist: Bool = true) {
        // During active agent execution, skip estimation - we use actual API tokens set by callOneShotText()
        if isAgentRunning {
            if persist {
                persistSettings()
            }
            return
        }
        
        var totalTokens = 0
        
        if !agentContextLog.isEmpty {
            // Agent mode but not actively running - show combined estimate
            let messageArray = buildMessageArray()
            let messageText = messageArray.map { $0.content }.joined(separator: "\n")
            totalTokens = TokenEstimator.estimateTokens(messageText, model: model)
            let agentContext = agentContextLog.joined(separator: "\n")
            totalTokens += TokenEstimator.estimateTokens(agentContext, model: model)
        } else {
            // Estimate from messages
            let messageArray = buildMessageArray()
            let messageText = messageArray.map { $0.content }.joined(separator: "\n")
            totalTokens = TokenEstimator.estimateTokens(messageText, model: model)
        }
        
        // Only update and notify if the value has actually changed
        if currentContextTokens != totalTokens {
            currentContextTokens = totalTokens
        }
        
        if persist {
            persistSettings()  // Persist context tracking per session
        }
    }
    
    /// Record that summarization occurred
    func recordSummarization() {
        summarizationCount += 1
        lastSummarizationDate = Date()
        // Reset accumulated context after summarization since we've compressed it
        accumulatedContextTokens = 0
        persistSettings()  // Persist context tracking per session
    }
    
    /// Reset context tracking state (e.g., when clearing chat)
    func resetContextTracking() {
        currentContextTokens = 0
        accumulatedContextTokens = 0
        lastSummarizationDate = nil
        summarizationCount = 0
        agentSessionTokensUsed = 0
        // Note: persistSettings() is called by the caller (clearChat)
    }
}
