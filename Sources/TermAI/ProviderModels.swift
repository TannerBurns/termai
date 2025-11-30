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
    
    static func == (lhs: ModelDefinition, rhs: ModelDefinition) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider
    }
}

// MARK: - Curated Model Lists

struct CuratedModels {
    /// OpenAI models with reasoning effort support info
    static let openAI: [ModelDefinition] = [
        // GPT-5 series (with reasoning)
        ModelDefinition(id: "gpt-5.1", displayName: "GPT-5.1", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "gpt-5", displayName: "GPT-5", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "gpt-5-mini", displayName: "GPT-5 Mini", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "gpt-5-nano", displayName: "GPT-5 Nano", provider: .openai, supportsReasoning: true),
        
        // O-series reasoning models
        ModelDefinition(id: "o4-mini", displayName: "o4-mini", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "o3", displayName: "o3", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "o3-mini", displayName: "o3-mini", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "o1", displayName: "o1", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "o1-mini", displayName: "o1-mini", provider: .openai, supportsReasoning: true),
        ModelDefinition(id: "o1-preview", displayName: "o1-preview", provider: .openai, supportsReasoning: true),
        
        // GPT-4.1 series (no reasoning)
        ModelDefinition(id: "gpt-4.1", displayName: "GPT-4.1", provider: .openai, supportsReasoning: false),
        ModelDefinition(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: .openai, supportsReasoning: false),
        ModelDefinition(id: "gpt-4.1-nano", displayName: "GPT-4.1 Nano", provider: .openai, supportsReasoning: false),
        
        // GPT-4o series (no reasoning)
        ModelDefinition(id: "gpt-4o", displayName: "GPT-4o", provider: .openai, supportsReasoning: false),
        ModelDefinition(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openai, supportsReasoning: false),
        
        // GPT-4 Turbo
        ModelDefinition(id: "gpt-4-turbo", displayName: "GPT-4 Turbo", provider: .openai, supportsReasoning: false),
    ]
    
    /// Anthropic models with extended thinking support info
    static let anthropic: [ModelDefinition] = [
        // Claude 4 series
        ModelDefinition(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", provider: .anthropic, supportsReasoning: true),
        ModelDefinition(id: "claude-opus-4-5", displayName: "Claude Opus 4.5", provider: .anthropic, supportsReasoning: true),
        ModelDefinition(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: .anthropic, supportsReasoning: true),
        ModelDefinition(id: "claude-opus-4", displayName: "Claude Opus 4", provider: .anthropic, supportsReasoning: true), 
        ModelDefinition(id: "claude-sonnet-4", displayName: "Claude Sonnet 4", provider: .anthropic, supportsReasoning: true),
        
        // Claude 3.7 series
        ModelDefinition(id: "claude-3-7-sonnet", displayName: "Claude Sonnet 3.7", provider: .anthropic, supportsReasoning: true),
        
        // Claude 3.5 series (no extended thinking)
        ModelDefinition(id: "claude-3-5-sonnet", displayName: "Claude Sonnet 3.5", provider: .anthropic, supportsReasoning: false),
        ModelDefinition(id: "claude-3-5-haiku", displayName: "Claude Haiku 3.5", provider: .anthropic, supportsReasoning: false),
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

