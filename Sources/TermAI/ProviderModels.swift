import Foundation

// MARK: - Provider Types

/// Represents a cloud LLM provider that requires an API key
enum CloudProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    
    var apiKeyEnvVariable: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }
    
    var baseURL: URL {
        switch self {
        case .openai: return URL(string: "https://api.openai.com/v1")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1")!
        }
    }
    
    var icon: String {
        switch self {
        case .openai: return "brain.head.profile"
        case .anthropic: return "sparkle"
        }
    }
    
    var accentColorName: String {
        switch self {
        case .openai: return "green"
        case .anthropic: return "orange"
        }
    }
    
    /// Check if API key is available in environment
    static func hasAPIKey(for provider: CloudProvider) -> Bool {
        ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable] != nil
    }
    
    /// Get API key from environment
    static func getAPIKey(for provider: CloudProvider) -> String? {
        ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable]
    }
    
    /// Get all available cloud providers (those with API keys set)
    static var availableProviders: [CloudProvider] {
        allCases.filter { hasAPIKey(for: $0) }
    }
}

// MARK: - Reasoning Effort

/// Reasoning/thinking effort level for supported models
enum ReasoningEffort: String, CaseIterable, Codable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    /// OpenAI reasoning_effort parameter value
    var openAIValue: String? {
        switch self {
        case .none: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
    
    /// Anthropic thinking budget tokens
    var anthropicBudgetTokens: Int? {
        switch self {
        case .none: return nil
        case .low: return 1024
        case .medium: return 8192
        case .high: return 32000
        }
    }
}

// MARK: - Model Definition

/// Represents a curated model from a cloud provider
struct ModelDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let provider: CloudProvider
    let supportsReasoning: Bool
    /// Context window size in tokens
    let contextSize: Int
    
    static func == (lhs: ModelDefinition, rhs: ModelDefinition) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider
    }
    
    /// Get context size for a model by ID, with fallback to TokenEstimator
    static func contextSize(for modelId: String) -> Int {
        if let model = CuratedModels.find(id: modelId) {
            return model.contextSize
        }
        // Fallback to TokenEstimator for unknown models
        return TokenEstimator.contextLimit(for: modelId)
    }
}

// MARK: - Curated Model Lists

struct CuratedModels {
    /// OpenAI models with reasoning effort support info and context sizes
    static let openAI: [ModelDefinition] = [
        // GPT-5 series (with reasoning) - 1M context
        ModelDefinition(id: "gpt-5.1", displayName: "GPT-5.1", provider: .openai, supportsReasoning: true, contextSize: 1_000_000),
        ModelDefinition(id: "gpt-5", displayName: "GPT-5", provider: .openai, supportsReasoning: true, contextSize: 1_000_000),
        ModelDefinition(id: "gpt-5-mini", displayName: "GPT-5 Mini", provider: .openai, supportsReasoning: true, contextSize: 1_000_000),
        ModelDefinition(id: "gpt-5-nano", displayName: "GPT-5 Nano", provider: .openai, supportsReasoning: true, contextSize: 1_000_000),
        
        // O-series reasoning models - 200K context
        ModelDefinition(id: "o4-mini", displayName: "o4-mini", provider: .openai, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "o3", displayName: "o3", provider: .openai, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "o3-mini", displayName: "o3-mini", provider: .openai, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "o1", displayName: "o1", provider: .openai, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "o1-mini", displayName: "o1-mini", provider: .openai, supportsReasoning: true, contextSize: 128_000),
        ModelDefinition(id: "o1-preview", displayName: "o1-preview", provider: .openai, supportsReasoning: true, contextSize: 128_000),
        
        // GPT-4.1 series (no reasoning) - 1M context
        ModelDefinition(id: "gpt-4.1", displayName: "GPT-4.1", provider: .openai, supportsReasoning: false, contextSize: 1_000_000),
        ModelDefinition(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: .openai, supportsReasoning: false, contextSize: 1_000_000),
        ModelDefinition(id: "gpt-4.1-nano", displayName: "GPT-4.1 Nano", provider: .openai, supportsReasoning: false, contextSize: 1_000_000),
        
        // GPT-4o series (no reasoning) - 128K context
        ModelDefinition(id: "gpt-4o", displayName: "GPT-4o", provider: .openai, supportsReasoning: false, contextSize: 128_000),
        ModelDefinition(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openai, supportsReasoning: false, contextSize: 128_000),
        
        // GPT-4 Turbo - 128K context
        ModelDefinition(id: "gpt-4-turbo", displayName: "GPT-4 Turbo", provider: .openai, supportsReasoning: false, contextSize: 128_000),
    ]
    
    /// Anthropic models with extended thinking support info and context sizes
    static let anthropic: [ModelDefinition] = [
        // Claude 4 series - 200K context
        ModelDefinition(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "claude-opus-4-5", displayName: "Claude Opus 4.5", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "claude-opus-4", displayName: "Claude Opus 4", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        ModelDefinition(id: "claude-sonnet-4", displayName: "Claude Sonnet 4", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        
        // Claude 3.7 series - 200K context
        ModelDefinition(id: "claude-3-7-sonnet", displayName: "Claude Sonnet 3.7", provider: .anthropic, supportsReasoning: true, contextSize: 200_000),
        
        // Claude 3.5 series (no extended thinking) - 200K context
        ModelDefinition(id: "claude-3-5-sonnet", displayName: "Claude Sonnet 3.5", provider: .anthropic, supportsReasoning: false, contextSize: 200_000),
        ModelDefinition(id: "claude-3-5-haiku", displayName: "Claude Haiku 3.5", provider: .anthropic, supportsReasoning: false, contextSize: 200_000),
    ]
    
    /// All curated models
    static var all: [ModelDefinition] {
        openAI + anthropic
    }
    
    /// Get models for a specific provider
    static func models(for provider: CloudProvider) -> [ModelDefinition] {
        switch provider {
        case .openai: return openAI
        case .anthropic: return anthropic
        }
    }
    
    /// Find a model definition by ID
    static func find(id: String) -> ModelDefinition? {
        all.first { $0.id == id }
    }
    
    /// Check if a model ID supports reasoning
    static func supportsReasoning(modelId: String) -> Bool {
        find(id: modelId)?.supportsReasoning ?? false
    }
}

// MARK: - Provider Type (Unified)

/// Unified provider type that includes both local and cloud providers
enum ProviderType: Equatable, Codable {
    case local(LocalLLMProvider)
    case cloud(CloudProvider)
    
    var displayName: String {
        switch self {
        case .local(let provider): return provider.rawValue
        case .cloud(let provider): return provider.rawValue
        }
    }
    
    var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }
    
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
    
    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        
        if type == "local", let local = LocalLLMProvider(rawValue: value) {
            self = .local(local)
        } else if type == "cloud", let cloud = CloudProvider(rawValue: value) {
            self = .cloud(cloud)
        } else {
            // Default to local Ollama
            self = .local(.ollama)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let provider):
            try container.encode("local", forKey: .type)
            try container.encode(provider.rawValue, forKey: .value)
        case .cloud(let provider):
            try container.encode("cloud", forKey: .type)
            try container.encode(provider.rawValue, forKey: .value)
        }
    }
}

/// Local LLM provider enum (moved from ChatSession for better organization)
enum LocalLLMProvider: String, CaseIterable, Codable {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case vllm = "vLLM"
    
    var defaultBaseURL: URL {
        switch self {
        case .ollama:
            return URL(string: "http://localhost:11434/v1")!
        case .lmStudio:
            return URL(string: "http://localhost:1234/v1")!
        case .vllm:
            return URL(string: "http://localhost:8000/v1")!
        }
    }
    
    var icon: String {
        switch self {
        case .ollama: return "cube.fill"
        case .lmStudio: return "sparkles"
        case .vllm: return "bolt.fill"
        }
    }
    
    var accentColorName: String {
        switch self {
        case .ollama: return "blue"
        case .lmStudio: return "purple"
        case .vllm: return "orange"
        }
    }
}

// MARK: - Local Provider Service

/// Error types for local provider operations
enum LocalProviderError: LocalizedError {
    case invalidURL
    case connectionFailed(statusCode: Int)
    case decodingFailed(message: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid provider URL"
        case .connectionFailed(let statusCode):
            return "Connection failed (HTTP \(statusCode))"
        case .decodingFailed(let message):
            return message
        }
    }
}

/// Shared service for fetching models from local LLM providers
/// Consolidates duplicate implementations from SessionSettingsView, SettingsRootView, and TerminalPane
enum LocalProviderService {
    /// Fetch available models from a local LLM provider
    /// - Parameters:
    ///   - provider: The local provider to query
    ///   - timeout: Request timeout in seconds (default: 10)
    /// - Returns: Array of model IDs sorted alphabetically
    static func fetchModels(for provider: LocalLLMProvider, timeout: TimeInterval = 10) async throws -> [String] {
        let baseURL = AgentSettings.shared.baseURL(for: provider)
        
        switch provider {
        case .ollama:
            // Ollama uses /api/tags endpoint (not OpenAI-compatible for listing models)
            let baseURLString = baseURL.absoluteString.replacingOccurrences(of: "/v1", with: "")
            guard let url = URL(string: baseURLString + "/api/tags") else {
                throw LocalProviderError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LocalProviderError.connectionFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            
            struct TagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            
            do {
                let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
                return decoded.models.map { $0.name }.sorted()
            } catch {
                throw LocalProviderError.decodingFailed(message: "Failed to parse Ollama response: \(error.localizedDescription)")
            }
            
        case .lmStudio, .vllm:
            // LM Studio and vLLM use OpenAI-compatible /models endpoint
            let url = baseURL.appendingPathComponent("models")
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LocalProviderError.connectionFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            
            struct ModelsResponse: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            
            do {
                let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
                return decoded.data.map { $0.id }.sorted()
            } catch {
                throw LocalProviderError.decodingFailed(message: "Failed to parse models response: \(error.localizedDescription)")
            }
        }
    }
}

