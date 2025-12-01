import Foundation

/// Manages cloud provider API keys with support for environment variables and user overrides.
/// User overrides are stored securely and take precedence over environment variables.
final class CloudAPIKeyManager: ObservableObject, Codable {
    static let shared = CloudAPIKeyManager.load()
    
    /// User-provided API key overrides (takes precedence over environment)
    @Published private var openAIKeyOverride: String?
    @Published private var anthropicKeyOverride: String?
    
    /// Cached environment variables from shell (for GUI apps that don't inherit shell env)
    private var shellEnvironment: [String: String] = [:]
    
    enum CodingKeys: String, CodingKey {
        case openAIKeyOverride
        case anthropicKeyOverride
    }
    
    init() {
        loadShellEnvironment()
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openAIKeyOverride = try container.decodeIfPresent(String.self, forKey: .openAIKeyOverride)
        anthropicKeyOverride = try container.decodeIfPresent(String.self, forKey: .anthropicKeyOverride)
        loadShellEnvironment()
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(openAIKeyOverride, forKey: .openAIKeyOverride)
        try container.encodeIfPresent(anthropicKeyOverride, forKey: .anthropicKeyOverride)
    }
    
    // MARK: - Shell Environment Loading
    
    /// Load environment variables from shell config files (for GUI apps that don't inherit shell env)
    /// GUI apps launched from Finder/Dock don't inherit shell environment variables,
    /// so we parse common shell config files to find API key exports.
    private func loadShellEnvironment() {
        let envVars = [CloudProvider.openai.apiKeyEnvVariable, CloudProvider.anthropic.apiKeyEnvVariable]
        let directEnv = ProcessInfo.processInfo.environment
        
        // For each key, check direct env first, then parse config files
        for key in envVars {
            if directEnv[key] != nil {
                // Already in direct environment, no need to parse files
                continue
            }
            if let value = readEnvFromFiles(key: key) {
                shellEnvironment[key] = value
            }
        }
    }
    
    /// Try to read an environment variable from common shell config files
    private func readEnvFromFiles(key: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configFiles = [
            "\(home)/.zshenv",           // zsh: always sourced
            "\(home)/.zshrc",            // zsh: interactive shells (most common)
            "\(home)/.zprofile",         // zsh: login shells
            "\(home)/.bashrc",           // bash: interactive shells
            "\(home)/.bash_profile",     // bash: login shells
            "\(home)/.profile",          // POSIX: login shells
            "\(home)/.config/termai/env" // App-specific config
        ]
        
        // Patterns to match various export formats:
        // export KEY="value"
        // export KEY='value'  
        // export KEY=value
        // KEY="value"
        // KEY='value'
        // KEY=value
        let patterns = [
            "^\\s*export\\s+\(key)=\"([^\"]+)\"",
            "^\\s*export\\s+\(key)='([^']+)'",
            "^\\s*export\\s+\(key)=([^\\s#\"']+)",
            "^\\s*\(key)=\"([^\"]+)\"",
            "^\\s*\(key)='([^']+)'",
            "^\\s*\(key)=([^\\s#\"']+)"
        ]
        
        for file in configFiles {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            
            // Check each line individually to handle multi-line files properly
            for line in content.components(separatedBy: .newlines) {
                // Skip comments
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { continue }
                
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
                       let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                       let valueRange = Range(match.range(at: 1), in: line) {
                        let value = String(line[valueRange])
                        // Skip if it looks like a variable reference (e.g., $OTHER_VAR)
                        if !value.hasPrefix("$") {
                            return value
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Get an environment variable, checking both direct process env and shell env
    private func getEnvVar(_ key: String) -> String? {
        // Direct process environment takes precedence
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }
        // Fall back to shell environment
        return shellEnvironment[key]
    }
    
    // MARK: - API Key Access
    
    /// Get the effective API key for a provider (user override or environment)
    func getAPIKey(for provider: CloudProvider) -> String? {
        switch provider {
        case .openai:
            return openAIKeyOverride ?? getEnvVar(provider.apiKeyEnvVariable)
        case .anthropic:
            return anthropicKeyOverride ?? getEnvVar(provider.apiKeyEnvVariable)
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
            return openAIKeyOverride == nil && getEnvVar(provider.apiKeyEnvVariable) != nil
        case .anthropic:
            return anthropicKeyOverride == nil && getEnvVar(provider.apiKeyEnvVariable) != nil
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
        getEnvVar(provider.apiKeyEnvVariable)
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

