import Foundation

/// Global agent settings that control the terminal agent's behavior
/// These settings are shared across all sessions and persisted to disk
final class AgentSettings: ObservableObject, Codable {
    static let shared = AgentSettings.load()
    
    // MARK: - Execution Limits
    
    /// Maximum number of iterations the agent will attempt to complete a goal
    @Published var maxIterations: Int = 6
    
    /// Maximum number of fix attempts when a command fails
    @Published var maxFixAttempts: Int = 3
    
    /// Timeout in seconds to wait for command output
    @Published var commandTimeout: TimeInterval = 10.0
    
    // MARK: - Context Limits
    
    /// Maximum characters to capture from command output
    @Published var maxOutputCapture: Int = 3000
    
    /// Maximum characters for the agent context log
    @Published var maxContextSize: Int = 8000
    
    // MARK: - Model Behavior
    
    /// Temperature for agent decision-making (lower = more deterministic)
    @Published var agentTemperature: Double = 0.2
    
    /// Temperature for title generation (higher = more creative)
    @Published var titleTemperature: Double = 1.0
    
    // MARK: - Safety
    
    /// Whether to require user approval before executing commands
    @Published var requireCommandApproval: Bool = false
    
    /// Auto-approve read-only commands when approval is required
    @Published var autoApproveReadOnly: Bool = true
    
    // MARK: - Debug
    
    /// Enable verbose logging for agent operations
    @Published var verboseLogging: Bool = false
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case maxIterations
        case maxFixAttempts
        case commandTimeout
        case maxOutputCapture
        case maxContextSize
        case requireCommandApproval
        case autoApproveReadOnly
        case verboseLogging
        case agentTemperature
        case titleTemperature
    }
    
    init() {}
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 6
        maxFixAttempts = try container.decodeIfPresent(Int.self, forKey: .maxFixAttempts) ?? 3
        commandTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .commandTimeout) ?? 10.0
        maxOutputCapture = try container.decodeIfPresent(Int.self, forKey: .maxOutputCapture) ?? 3000
        maxContextSize = try container.decodeIfPresent(Int.self, forKey: .maxContextSize) ?? 8000
        requireCommandApproval = try container.decodeIfPresent(Bool.self, forKey: .requireCommandApproval) ?? false
        autoApproveReadOnly = try container.decodeIfPresent(Bool.self, forKey: .autoApproveReadOnly) ?? true
        verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
        agentTemperature = try container.decodeIfPresent(Double.self, forKey: .agentTemperature) ?? 0.2
        titleTemperature = try container.decodeIfPresent(Double.self, forKey: .titleTemperature) ?? 1.0
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxIterations, forKey: .maxIterations)
        try container.encode(maxFixAttempts, forKey: .maxFixAttempts)
        try container.encode(commandTimeout, forKey: .commandTimeout)
        try container.encode(maxOutputCapture, forKey: .maxOutputCapture)
        try container.encode(maxContextSize, forKey: .maxContextSize)
        try container.encode(requireCommandApproval, forKey: .requireCommandApproval)
        try container.encode(autoApproveReadOnly, forKey: .autoApproveReadOnly)
        try container.encode(verboseLogging, forKey: .verboseLogging)
        try container.encode(agentTemperature, forKey: .agentTemperature)
        try container.encode(titleTemperature, forKey: .titleTemperature)
    }
    
    // MARK: - Persistence
    
    private static let fileName = "agent-settings.json"
    
    static func load() -> AgentSettings {
        if let settings = try? PersistenceService.loadJSON(AgentSettings.self, from: fileName) {
            return settings
        }
        return AgentSettings()
    }
    
    func save() {
        try? PersistenceService.saveJSON(self, to: Self.fileName)
    }
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        maxIterations = 6
        maxFixAttempts = 3
        commandTimeout = 10.0
        maxOutputCapture = 3000
        maxContextSize = 8000
        requireCommandApproval = false
        autoApproveReadOnly = true
        verboseLogging = false
        agentTemperature = 0.2
        titleTemperature = 1.0
        save()
    }
    
    // MARK: - Read-Only Command Detection
    
    /// Common read-only commands that are safe to auto-approve
    private static let readOnlyPrefixes = [
        "ls", "cat", "head", "tail", "less", "more", "grep", "find", "which", "where",
        "pwd", "whoami", "hostname", "uname", "date", "cal", "echo", "printf",
        "wc", "file", "stat", "du", "df", "free", "top", "ps", "env", "printenv",
        "git status", "git log", "git diff", "git show", "git branch",
        "docker ps", "docker images", "docker logs",
        "brew list", "brew info", "brew search",
        "npm list", "npm info", "npm search",
        "pip list", "pip show",
        "cargo --version", "rustc --version",
        "python --version", "node --version", "swift --version"
    ]
    
    /// Check if a command is considered read-only (safe)
    func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.readOnlyPrefixes.contains { prefix in
            trimmed.hasPrefix(prefix.lowercased())
        }
    }
    
    /// Determine if a command should be auto-approved based on settings
    func shouldAutoApprove(_ command: String) -> Bool {
        if !requireCommandApproval {
            return true
        }
        if autoApproveReadOnly && isReadOnlyCommand(command) {
            return true
        }
        return false
    }
}

