import Foundation
import SwiftUI

/// App appearance mode for light/dark theme control
enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    /// Convert to SwiftUI ColorScheme for preferredColorScheme modifier
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    /// Icon for the mode
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    /// Description for the mode
    var description: String {
        switch self {
        case .system: return "Follow system appearance"
        case .light: return "Always use light mode"
        case .dark: return "Always use dark mode"
        }
    }
}

/// Global agent settings that control the terminal agent's behavior
/// These settings are shared across all sessions and persisted to disk
final class AgentSettings: ObservableObject, Codable {
    static let shared = AgentSettings.load()
    
    // MARK: - Execution Limits
    
    /// Maximum number of iterations the agent will attempt to complete a goal
    @Published var maxIterations: Int = 100
    
    /// Maximum number of fix attempts when a command fails
    @Published var maxFixAttempts: Int = 3
    
    /// Timeout in seconds to wait for command output
    @Published var commandTimeout: TimeInterval = 10.0
    
    /// Delay in seconds before capturing command output after execution
    @Published var commandCaptureDelay: TimeInterval = 1.5
    
    // MARK: - Context Limits
    
    /// Maximum characters to capture from command output
    @Published var maxOutputCapture: Int = 3000
    
    /// Maximum characters for the agent context log
    @Published var maxContextSize: Int = 8000
    
    /// Threshold above which output is summarized
    @Published var outputSummarizationThreshold: Int = 5000
    
    /// Enable automatic summarization of long outputs
    @Published var enableOutputSummarization: Bool = true
    
    /// Maximum size of the full output buffer for search
    @Published var maxFullOutputBuffer: Int = 50000
    
    // MARK: - Planning & Reflection
    
    /// Enable planning phase before execution
    @Published var enablePlanning: Bool = true
    
    /// Interval (in steps) between reflection prompts
    @Published var reflectionInterval: Int = 10
    
    /// Enable periodic reflection and progress assessment
    @Published var enableReflection: Bool = true
    
    /// Number of similar commands before stuck detection triggers
    @Published var stuckDetectionThreshold: Int = 3
    
    /// Enable verification phase before declaring goal complete
    @Published var enableVerificationPhase: Bool = true
    
    // MARK: - Verification & Testing
    
    /// Timeout in seconds for HTTP requests during verification
    @Published var httpRequestTimeout: TimeInterval = 10.0
    
    /// Timeout in seconds when waiting for background process startup
    @Published var backgroundProcessTimeout: TimeInterval = 5.0
    
    // MARK: - File Coordination
    
    /// Timeout in seconds for waiting to acquire a file lock
    @Published var fileLockTimeout: TimeInterval = 30.0
    
    /// Enable smart merging of non-overlapping file edits across sessions
    @Published var enableFileMerging: Bool = true
    
    // MARK: - Model Behavior
    
    /// Temperature for agent decision-making (lower = more deterministic)
    @Published var agentTemperature: Double = 0.2
    
    /// Temperature for title generation (higher = more creative)
    @Published var titleTemperature: Double = 1.0
    
    // MARK: - Defaults
    
    /// Enable agent mode by default for new chat sessions
    @Published var agentModeEnabledByDefault: Bool = false
    
    // MARK: - Appearance
    
    /// App appearance mode (light, dark, or system)
    @Published var appAppearance: AppearanceMode = .system
    
    // MARK: - Safety
    
    /// Whether to require user approval before executing commands
    @Published var requireCommandApproval: Bool = false
    
    /// Auto-approve read-only commands when approval is required
    @Published var autoApproveReadOnly: Bool = true
    
    /// Whether to require user approval before applying file changes (write, edit, insert, delete)
    @Published var requireFileEditApproval: Bool = true
    
    // MARK: - Debug
    
    /// Enable verbose logging for agent operations
    @Published var verboseLogging: Bool = false
    
    // MARK: - Model Favorites
    
    /// Set of favorited model IDs for quick access
    @Published var favoriteModels: Set<String> = []
    
    // MARK: - Terminal Suggestions
    
    /// Enable real-time terminal command suggestions
    @Published var terminalSuggestionsEnabled: Bool = true
    
    /// Model ID for terminal suggestions (nil = not configured)
    @Published var terminalSuggestionsModelId: String? = nil
    
    /// Provider type for terminal suggestions (nil = not configured)
    @Published var terminalSuggestionsProvider: ProviderType? = nil
    
    /// Debounce interval in seconds before generating suggestions
    @Published var terminalSuggestionsDebounceSeconds: Double = 2.5
    
    /// Read shell history file (~/.zsh_history, ~/.bash_history) for command suggestions
    @Published var readShellHistory: Bool = true
    
    /// Reasoning effort for terminal suggestions (for models that support it)
    @Published var terminalSuggestionsReasoningEffort: ReasoningEffort = .none
    
    // MARK: - Test Runner
    
    /// Enable the Test Runner button in the chat UI (disabled by default)
    @Published var testRunnerEnabled: Bool = false
    
    /// Check if terminal suggestions are fully configured
    var isTerminalSuggestionsConfigured: Bool {
        terminalSuggestionsEnabled && 
        terminalSuggestionsModelId != nil && 
        terminalSuggestionsProvider != nil
    }
    
    // MARK: - Global Provider URLs
    
    /// Base URL for Ollama provider
    @Published var ollamaBaseURL: String = "http://localhost:11434/v1"
    
    /// Base URL for LM Studio provider
    @Published var lmStudioBaseURL: String = "http://localhost:1234/v1"
    
    /// Base URL for vLLM provider
    @Published var vllmBaseURL: String = "http://localhost:8000/v1"
    
    /// Get the configured base URL for a local provider
    func baseURL(for provider: LocalLLMProvider) -> URL {
        switch provider {
        case .ollama:
            return URL(string: ollamaBaseURL) ?? provider.defaultBaseURL
        case .lmStudio:
            return URL(string: lmStudioBaseURL) ?? provider.defaultBaseURL
        case .vllm:
            return URL(string: vllmBaseURL) ?? provider.defaultBaseURL
        }
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case maxIterations
        case maxFixAttempts
        case commandTimeout
        case commandCaptureDelay
        case maxOutputCapture
        case maxContextSize
        case outputSummarizationThreshold
        case enableOutputSummarization
        case maxFullOutputBuffer
        case enablePlanning
        case reflectionInterval
        case enableReflection
        case stuckDetectionThreshold
        case enableVerificationPhase
        case httpRequestTimeout
        case backgroundProcessTimeout
        case fileLockTimeout
        case enableFileMerging
        case agentModeEnabledByDefault
        case appAppearance
        case requireCommandApproval
        case autoApproveReadOnly
        case requireFileEditApproval
        case verboseLogging
        case agentTemperature
        case titleTemperature
        case favoriteModels
        case terminalSuggestionsEnabled
        case terminalSuggestionsModelId
        case terminalSuggestionsProvider
        case terminalSuggestionsDebounceSeconds
        case readShellHistory
        case terminalSuggestionsReasoningEffort
        case testRunnerEnabled
        case ollamaBaseURL
        case lmStudioBaseURL
        case vllmBaseURL
    }
    
    init() {}
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 100
        maxFixAttempts = try container.decodeIfPresent(Int.self, forKey: .maxFixAttempts) ?? 3
        commandTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .commandTimeout) ?? 10.0
        commandCaptureDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .commandCaptureDelay) ?? 1.5
        maxOutputCapture = try container.decodeIfPresent(Int.self, forKey: .maxOutputCapture) ?? 3000
        maxContextSize = try container.decodeIfPresent(Int.self, forKey: .maxContextSize) ?? 8000
        outputSummarizationThreshold = try container.decodeIfPresent(Int.self, forKey: .outputSummarizationThreshold) ?? 5000
        enableOutputSummarization = try container.decodeIfPresent(Bool.self, forKey: .enableOutputSummarization) ?? true
        maxFullOutputBuffer = try container.decodeIfPresent(Int.self, forKey: .maxFullOutputBuffer) ?? 50000
        enablePlanning = try container.decodeIfPresent(Bool.self, forKey: .enablePlanning) ?? true
        reflectionInterval = try container.decodeIfPresent(Int.self, forKey: .reflectionInterval) ?? 10
        enableReflection = try container.decodeIfPresent(Bool.self, forKey: .enableReflection) ?? true
        stuckDetectionThreshold = try container.decodeIfPresent(Int.self, forKey: .stuckDetectionThreshold) ?? 3
        enableVerificationPhase = try container.decodeIfPresent(Bool.self, forKey: .enableVerificationPhase) ?? true
        httpRequestTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .httpRequestTimeout) ?? 10.0
        backgroundProcessTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundProcessTimeout) ?? 5.0
        fileLockTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .fileLockTimeout) ?? 30.0
        enableFileMerging = try container.decodeIfPresent(Bool.self, forKey: .enableFileMerging) ?? true
        agentModeEnabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .agentModeEnabledByDefault) ?? false
        appAppearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appAppearance) ?? .system
        requireCommandApproval = try container.decodeIfPresent(Bool.self, forKey: .requireCommandApproval) ?? false
        autoApproveReadOnly = try container.decodeIfPresent(Bool.self, forKey: .autoApproveReadOnly) ?? true
        requireFileEditApproval = try container.decodeIfPresent(Bool.self, forKey: .requireFileEditApproval) ?? true
        verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
        agentTemperature = try container.decodeIfPresent(Double.self, forKey: .agentTemperature) ?? 0.2
        titleTemperature = try container.decodeIfPresent(Double.self, forKey: .titleTemperature) ?? 1.0
        favoriteModels = try container.decodeIfPresent(Set<String>.self, forKey: .favoriteModels) ?? []
        terminalSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminalSuggestionsEnabled) ?? true
        terminalSuggestionsModelId = try container.decodeIfPresent(String.self, forKey: .terminalSuggestionsModelId)
        terminalSuggestionsProvider = try container.decodeIfPresent(ProviderType.self, forKey: .terminalSuggestionsProvider)
        terminalSuggestionsDebounceSeconds = try container.decodeIfPresent(Double.self, forKey: .terminalSuggestionsDebounceSeconds) ?? 2.5
        readShellHistory = try container.decodeIfPresent(Bool.self, forKey: .readShellHistory) ?? true
        terminalSuggestionsReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .terminalSuggestionsReasoningEffort) ?? .none
        testRunnerEnabled = try container.decodeIfPresent(Bool.self, forKey: .testRunnerEnabled) ?? false
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434/v1"
        lmStudioBaseURL = try container.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? "http://localhost:1234/v1"
        vllmBaseURL = try container.decodeIfPresent(String.self, forKey: .vllmBaseURL) ?? "http://localhost:8000/v1"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxIterations, forKey: .maxIterations)
        try container.encode(maxFixAttempts, forKey: .maxFixAttempts)
        try container.encode(commandTimeout, forKey: .commandTimeout)
        try container.encode(commandCaptureDelay, forKey: .commandCaptureDelay)
        try container.encode(maxOutputCapture, forKey: .maxOutputCapture)
        try container.encode(maxContextSize, forKey: .maxContextSize)
        try container.encode(outputSummarizationThreshold, forKey: .outputSummarizationThreshold)
        try container.encode(enableOutputSummarization, forKey: .enableOutputSummarization)
        try container.encode(maxFullOutputBuffer, forKey: .maxFullOutputBuffer)
        try container.encode(enablePlanning, forKey: .enablePlanning)
        try container.encode(reflectionInterval, forKey: .reflectionInterval)
        try container.encode(enableReflection, forKey: .enableReflection)
        try container.encode(stuckDetectionThreshold, forKey: .stuckDetectionThreshold)
        try container.encode(enableVerificationPhase, forKey: .enableVerificationPhase)
        try container.encode(httpRequestTimeout, forKey: .httpRequestTimeout)
        try container.encode(backgroundProcessTimeout, forKey: .backgroundProcessTimeout)
        try container.encode(fileLockTimeout, forKey: .fileLockTimeout)
        try container.encode(enableFileMerging, forKey: .enableFileMerging)
        try container.encode(agentModeEnabledByDefault, forKey: .agentModeEnabledByDefault)
        try container.encode(appAppearance, forKey: .appAppearance)
        try container.encode(requireCommandApproval, forKey: .requireCommandApproval)
        try container.encode(autoApproveReadOnly, forKey: .autoApproveReadOnly)
        try container.encode(requireFileEditApproval, forKey: .requireFileEditApproval)
        try container.encode(verboseLogging, forKey: .verboseLogging)
        try container.encode(agentTemperature, forKey: .agentTemperature)
        try container.encode(titleTemperature, forKey: .titleTemperature)
        try container.encode(favoriteModels, forKey: .favoriteModels)
        try container.encode(terminalSuggestionsEnabled, forKey: .terminalSuggestionsEnabled)
        try container.encodeIfPresent(terminalSuggestionsModelId, forKey: .terminalSuggestionsModelId)
        try container.encodeIfPresent(terminalSuggestionsProvider, forKey: .terminalSuggestionsProvider)
        try container.encode(terminalSuggestionsDebounceSeconds, forKey: .terminalSuggestionsDebounceSeconds)
        try container.encode(readShellHistory, forKey: .readShellHistory)
        try container.encode(terminalSuggestionsReasoningEffort, forKey: .terminalSuggestionsReasoningEffort)
        try container.encode(testRunnerEnabled, forKey: .testRunnerEnabled)
        try container.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try container.encode(lmStudioBaseURL, forKey: .lmStudioBaseURL)
        try container.encode(vllmBaseURL, forKey: .vllmBaseURL)
    }
    
    // MARK: - Persistence
    
    private static let fileName = "agent-settings.json"
    
    /// Debounce interval for settings saves (prevents multiple disk writes when settings change rapidly)
    private static let saveDebounceInterval: TimeInterval = 0.5
    
    /// Pending save work item (used for debouncing)
    private var pendingSaveWorkItem: DispatchWorkItem?
    
    /// Queue for serializing save operations
    private let saveQueue = DispatchQueue(label: "com.termai.agentsettings.save")
    
    static func load() -> AgentSettings {
        if let settings = try? PersistenceService.loadJSON(AgentSettings.self, from: fileName) {
            return settings
        }
        return AgentSettings()
    }
    
    /// Save settings to disk with debouncing to prevent excessive writes
    func save() {
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending save
            self.pendingSaveWorkItem?.cancel()
            
            // Create new debounced save work item
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                try? PersistenceService.saveJSON(self, to: Self.fileName)
            }
            
            self.pendingSaveWorkItem = workItem
            
            // Schedule save after debounce interval
            self.saveQueue.asyncAfter(deadline: .now() + Self.saveDebounceInterval, execute: workItem)
        }
    }
    
    /// Force an immediate save without debouncing (use sparingly)
    func saveImmediately() {
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending debounced save
            self.pendingSaveWorkItem?.cancel()
            self.pendingSaveWorkItem = nil
            
            try? PersistenceService.saveJSON(self, to: Self.fileName)
        }
    }
    
    /// Reset all settings to defaults
    func resetToDefaults() {
        maxIterations = 100
        maxFixAttempts = 3
        commandTimeout = 10.0
        commandCaptureDelay = 1.5
        maxOutputCapture = 3000
        maxContextSize = 8000
        outputSummarizationThreshold = 5000
        enableOutputSummarization = true
        maxFullOutputBuffer = 50000
        enablePlanning = true
        reflectionInterval = 10
        enableReflection = true
        stuckDetectionThreshold = 3
        enableVerificationPhase = true
        httpRequestTimeout = 10.0
        backgroundProcessTimeout = 5.0
        fileLockTimeout = 30.0
        enableFileMerging = true
        agentModeEnabledByDefault = false
        appAppearance = .system
        requireCommandApproval = false
        autoApproveReadOnly = true
        requireFileEditApproval = true
        verboseLogging = false
        agentTemperature = 0.2
        titleTemperature = 1.0
        terminalSuggestionsEnabled = true
        terminalSuggestionsModelId = nil
        terminalSuggestionsProvider = nil
        terminalSuggestionsDebounceSeconds = 2.5
        readShellHistory = true
        terminalSuggestionsReasoningEffort = .none
        testRunnerEnabled = false
        ollamaBaseURL = "http://localhost:11434/v1"
        lmStudioBaseURL = "http://localhost:1234/v1"
        vllmBaseURL = "http://localhost:8000/v1"
        saveImmediately()
    }
    
    // MARK: - Model Favorites Helpers
    
    /// Check if a model is favorited
    func isFavorite(_ modelId: String) -> Bool {
        favoriteModels.contains(modelId)
    }
    
    /// Toggle favorite status for a model
    func toggleFavorite(_ modelId: String) {
        if favoriteModels.contains(modelId) {
            favoriteModels.remove(modelId)
        } else {
            favoriteModels.insert(modelId)
        }
        save()
    }
    
    /// Add a model to favorites
    func addFavorite(_ modelId: String) {
        favoriteModels.insert(modelId)
        save()
    }
    
    /// Remove a model from favorites
    func removeFavorite(_ modelId: String) {
        favoriteModels.remove(modelId)
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

