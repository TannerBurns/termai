import Foundation

/// Manages cloud provider API keys with support for environment variables and user overrides.
/// User overrides are stored securely and take precedence over environment variables.
final class CloudAPIKeyManager: ObservableObject, Codable {
    static let shared = CloudAPIKeyManager.load()
    
    /// User-provided API key overrides (takes precedence over environment)
    @Published private var openAIKeyOverride: String?
    @Published private var anthropicKeyOverride: String?
    
    enum CodingKeys: String, CodingKey {
        case openAIKeyOverride
        case anthropicKeyOverride
    }
    
    init() {}
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openAIKeyOverride = try container.decodeIfPresent(String.self, forKey: .openAIKeyOverride)
        anthropicKeyOverride = try container.decodeIfPresent(String.self, forKey: .anthropicKeyOverride)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(openAIKeyOverride, forKey: .openAIKeyOverride)
        try container.encodeIfPresent(anthropicKeyOverride, forKey: .anthropicKeyOverride)
    }
    
    // MARK: - API Key Access
    
    /// Get the effective API key for a provider (user override or environment)
    func getAPIKey(for provider: CloudProvider) -> String? {
        switch provider {
        case .openai:
            return openAIKeyOverride ?? ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable]
        case .anthropic:
            return anthropicKeyOverride ?? ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable]
        }
    }
    
    /// Check if an API key is available for a provider
    func hasAPIKey(for provider: CloudProvider) -> Bool {
        getAPIKey(for: provider) != nil
    }
    
    /// Get all providers that have API keys available
    var availableProviders: [CloudProvider] {
        CloudProvider.allCases.filter { hasAPIKey(for: $0) }
    }
    
    // MARK: - Key Sources
    
    /// Check if the API key comes from environment variable
    func isFromEnvironment(for provider: CloudProvider) -> Bool {
        switch provider {
        case .openai:
            return openAIKeyOverride == nil && ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable] != nil
        case .anthropic:
            return anthropicKeyOverride == nil && ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable] != nil
        }
    }
    
    /// Check if user has provided an override
    func hasOverride(for provider: CloudProvider) -> Bool {
        switch provider {
        case .openai:
            return openAIKeyOverride != nil && !openAIKeyOverride!.isEmpty
        case .anthropic:
            return anthropicKeyOverride != nil && !anthropicKeyOverride!.isEmpty
        }
    }
    
    /// Get the environment variable value (for display purposes)
    func getEnvironmentKey(for provider: CloudProvider) -> String? {
        ProcessInfo.processInfo.environment[provider.apiKeyEnvVariable]
    }
    
    // MARK: - Key Management
    
    /// Set or clear the user override for a provider
    func setOverride(_ key: String?, for provider: CloudProvider) {
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (trimmedKey?.isEmpty == true) ? nil : trimmedKey
        
        switch provider {
        case .openai:
            openAIKeyOverride = effectiveKey
        case .anthropic:
            anthropicKeyOverride = effectiveKey
        }
        save()
    }
    
    /// Get the current override value (for editing)
    func getOverride(for provider: CloudProvider) -> String? {
        switch provider {
        case .openai:
            return openAIKeyOverride
        case .anthropic:
            return anthropicKeyOverride
        }
    }
    
    /// Clear all user overrides
    func clearAllOverrides() {
        openAIKeyOverride = nil
        anthropicKeyOverride = nil
        save()
    }
    
    // MARK: - Persistence
    
    private static let fileName = "cloud-api-keys.json"
    
    static func load() -> CloudAPIKeyManager {
        if let manager = try? PersistenceService.loadJSON(CloudAPIKeyManager.self, from: fileName) {
            return manager
        }
        return CloudAPIKeyManager()
    }
    
    func save() {
        try? PersistenceService.saveJSON(self, to: Self.fileName)
    }
}

// MARK: - Update CloudProvider to use manager

extension CloudProvider {
    /// Get API key using the centralized manager (preferred method)
    static func getEffectiveAPIKey(for provider: CloudProvider) -> String? {
        CloudAPIKeyManager.shared.getAPIKey(for: provider)
    }
    
    /// Check if any key (override or env) is available
    static func hasEffectiveAPIKey(for provider: CloudProvider) -> Bool {
        CloudAPIKeyManager.shared.hasAPIKey(for: provider)
    }
}

