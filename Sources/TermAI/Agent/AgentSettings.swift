import Foundation
import SwiftUI

/// Global agent settings that control the terminal agent's behavior
/// These settings are shared across all sessions and persisted to disk
final class AgentSettings: ObservableObject, Codable {
    static let shared = AgentSettings.load()
    
    // MARK: - Execution Limits
    
    /// Maximum number of iterations the agent will attempt to complete a goal
    @Published var maxIterations: Int = 100
    
    /// Maximum number of tool calls allowed within a single step (prevents infinite loops)
    @Published var maxToolCallsPerStep: Int = 100
    
    /// Maximum number of fix attempts when a command fails
    @Published var maxFixAttempts: Int = 3
    
    /// Timeout in seconds to wait for command output (default 5 minutes for builds/tests)
    @Published var commandTimeout: TimeInterval = 300.0
    
    /// Delay in seconds before capturing command output after execution
    @Published var commandCaptureDelay: TimeInterval = 1.5
    
    // MARK: - Context Limits (Dynamic Scaling)
    
    /// Percentage of model context to allocate per individual output capture (0.0-1.0)
    /// Default 15% means a 128K context model gets ~19K chars per output
    @Published var outputCapturePercent: Double = 0.15
    
    /// Percentage of model context to allocate for agent working memory (0.0-1.0)
    /// Default 40% means a 128K context model gets ~51K chars for agent memory
    @Published var agentMemoryPercent: Double = 0.40
    
    /// Hard cap on output capture to prevent excessive memory use (chars)
    @Published var maxOutputCaptureCap: Int = 50000
    
    /// Hard cap on agent memory to prevent excessive memory use (chars)
    @Published var maxAgentMemoryCap: Int = 100000
    
    /// Minimum characters to capture from command output (floor for small models)
    @Published var minOutputCapture: Int = 8000
    
    /// Minimum characters for agent context log (floor for small models)
    @Published var minContextSize: Int = 16000
    
    // Legacy settings - kept for migration, now used as minimums
    /// Maximum characters to capture from command output (legacy - use dynamic calculation)
    @Published var maxOutputCapture: Int = 8000
    
    /// Maximum characters for the agent context log (legacy - use dynamic calculation)
    @Published var maxContextSize: Int = 16000
    
    /// Threshold above which output is summarized
    @Published var outputSummarizationThreshold: Int = 10000
    
    /// Enable automatic summarization of long outputs
    @Published var enableOutputSummarization: Bool = true
    
    /// Maximum size of the full output buffer for search
    @Published var maxFullOutputBuffer: Int = 100000
    
    // MARK: - Dynamic Context Calculation
    
    /// Calculate effective output capture limit based on model context size
    /// - Parameter contextTokens: The model's context window size in tokens
    /// - Returns: Maximum characters to capture for a single output
    func effectiveOutputCaptureLimit(forContextTokens contextTokens: Int) -> Int {
        // Approximate 4 chars per token
        let contextChars = contextTokens * 4
        let dynamic = Int(Double(contextChars) * outputCapturePercent)
        
        // Apply floor and cap
        let withFloor = max(dynamic, minOutputCapture)
        return min(withFloor, maxOutputCaptureCap)
    }
    
    /// Calculate effective agent memory limit based on model context size
    /// - Parameter contextTokens: The model's context window size in tokens
    /// - Returns: Maximum characters for agent working memory
    func effectiveAgentMemoryLimit(forContextTokens contextTokens: Int) -> Int {
        // Approximate 4 chars per token
        let contextChars = contextTokens * 4
        let dynamic = Int(Double(contextChars) * agentMemoryPercent)
        
        // Apply floor and cap
        let withFloor = max(dynamic, minContextSize)
        return min(withFloor, maxAgentMemoryCap)
    }
    
    /// Get a human-readable description of current context allocation
    /// - Parameter contextTokens: The model's context window size in tokens
    /// - Returns: Description of how context is allocated
    func contextAllocationDescription(forContextTokens contextTokens: Int) -> String {
        let outputLimit = effectiveOutputCaptureLimit(forContextTokens: contextTokens)
        let memoryLimit = effectiveAgentMemoryLimit(forContextTokens: contextTokens)
        let contextChars = contextTokens * 4
        
        return """
        Model context: ~\(formatChars(contextChars))
        Per-output capture: \(formatChars(outputLimit)) (\(Int(outputCapturePercent * 100))%)
        Agent memory: \(formatChars(memoryLimit)) (\(Int(agentMemoryPercent * 100))%)
        """
    }
    
    /// Format character count for display
    private func formatChars(_ chars: Int) -> String {
        if chars >= 1000 {
            return "\(chars / 1000)K chars"
        }
        return "\(chars) chars"
    }
    
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
    
    /// Default agent mode for new chat sessions
    @Published var defaultAgentMode: AgentMode = .scout
    
    /// Default agent profile for new chat sessions
    @Published var defaultAgentProfile: AgentProfile = .auto
    
    // MARK: - Appearance
    
    /// App appearance mode (light, dark, or system)
    @Published var appAppearance: AppearanceMode = .system
    
    // MARK: - Safety
    
    /// Whether to require user approval before executing commands
    @Published var requireCommandApproval: Bool = false
    
    /// Auto-approve read-only commands when approval is required
    @Published var autoApproveReadOnly: Bool = true
    
    /// Whether to require user approval before applying file changes (write, edit, insert, delete)
    /// Note: Destructive operations (delete_file, rm, rmdir) ALWAYS require approval regardless of this setting
    @Published var requireFileEditApproval: Bool = false
    
    /// Whether to send macOS system notifications when agent approval is needed
    /// Useful for alerting users who are away or in another window
    @Published var enableApprovalNotifications: Bool = true
    
    /// Whether to play a sound with approval notifications
    @Published var enableApprovalNotificationSound: Bool = true
    
    /// Command patterns that always require user approval before execution
    /// These are dangerous commands that could cause data loss or system changes
    @Published var blockedCommandPatterns: [String] = AgentSettings.defaultBlockedCommandPatterns
    
    /// Default blocked command patterns for safe agent operation
    static let defaultBlockedCommandPatterns: [String] = [
        // File/directory deletion
        "rm",
        "rmdir",
        "unlink",
        // Elevated privileges
        "sudo",
        "su ",
        "doas",
        // Permission/ownership changes
        "chmod",
        "chown",
        "chgrp",
        // Git destructive operations
        "git push --force",
        "git push -f",
        "git reset --hard",
        "git clean -fd",
        "git clean -f",
        "git checkout -- .",
        // Dangerous moves/copies
        "mv /",
        "cp /dev/",
        // Disk operations
        "dd ",
        "mkfs",
        "fdisk",
        "diskutil eraseDisk",
        "diskutil partitionDisk",
        // Process termination
        "kill ",
        "killall ",
        "pkill ",
        // System shutdown/reboot
        "shutdown",
        "reboot",
        "halt",
        // Package removal
        "brew uninstall",
        "brew remove",
        "pip uninstall",
        "npm uninstall -g",
        "apt remove",
        "apt purge",
        // Database destructive
        "DROP DATABASE",
        "DROP TABLE",
        "TRUNCATE",
        "DELETE FROM"
    ]
    
    // MARK: - Debug
    
    /// Enable verbose logging for agent operations
    @Published var verboseLogging: Bool = false
    
    /// Show verbose agent events in chat (progress checks, internal status updates, etc.)
    /// When false, only essential events like tool calls and file changes are shown
    @Published var showVerboseAgentEvents: Bool = false
    
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
    
    // MARK: - Terminal Bell
    
    /// Terminal bell behavior (sound, visual flash, or off)
    @Published var terminalBellMode: TerminalBellMode = .sound
    
    // MARK: - Test Runner
    
    /// Enable the Test Runner button in the chat UI (disabled by default)
    @Published var testRunnerEnabled: Bool = false
    
    // MARK: - Favorite Commands
    
    /// User's favorite terminal commands for quick access
    @Published var favoriteCommands: [FavoriteCommand] = []
    
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
        case maxToolCallsPerStep
        case maxFixAttempts
        case commandTimeout
        case commandCaptureDelay
        // Dynamic context settings
        case outputCapturePercent
        case agentMemoryPercent
        case maxOutputCaptureCap
        case maxAgentMemoryCap
        case minOutputCapture
        case minContextSize
        // Legacy (still encoded for backward compat)
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
        case defaultAgentMode
        case defaultAgentProfile
        case appAppearance
        case requireCommandApproval
        case autoApproveReadOnly
        case requireFileEditApproval
        case enableApprovalNotifications
        case enableApprovalNotificationSound
        case blockedCommandPatterns
        case verboseLogging
        case showVerboseAgentEvents
        case agentTemperature
        case titleTemperature
        case favoriteModels
        case terminalSuggestionsEnabled
        case terminalSuggestionsModelId
        case terminalSuggestionsProvider
        case terminalSuggestionsDebounceSeconds
        case readShellHistory
        case terminalSuggestionsReasoningEffort
        case terminalBellMode
        case testRunnerEnabled
        case ollamaBaseURL
        case lmStudioBaseURL
        case vllmBaseURL
        case favoriteCommands
    }
    
    init() {}
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 100
        maxToolCallsPerStep = try container.decodeIfPresent(Int.self, forKey: .maxToolCallsPerStep) ?? 100
        maxFixAttempts = try container.decodeIfPresent(Int.self, forKey: .maxFixAttempts) ?? 3
        commandTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .commandTimeout) ?? 300.0
        commandCaptureDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .commandCaptureDelay) ?? 1.5
        
        // Dynamic context settings - check if these exist to detect migration
        let hasNewSettings = container.contains(.outputCapturePercent)
        
        if hasNewSettings {
            // New settings exist - use them directly
            outputCapturePercent = try container.decodeIfPresent(Double.self, forKey: .outputCapturePercent) ?? 0.15
            agentMemoryPercent = try container.decodeIfPresent(Double.self, forKey: .agentMemoryPercent) ?? 0.40
            maxOutputCaptureCap = try container.decodeIfPresent(Int.self, forKey: .maxOutputCaptureCap) ?? 50000
            maxAgentMemoryCap = try container.decodeIfPresent(Int.self, forKey: .maxAgentMemoryCap) ?? 100000
            minOutputCapture = try container.decodeIfPresent(Int.self, forKey: .minOutputCapture) ?? 8000
            minContextSize = try container.decodeIfPresent(Int.self, forKey: .minContextSize) ?? 16000
            maxOutputCapture = try container.decodeIfPresent(Int.self, forKey: .maxOutputCapture) ?? 8000
            maxContextSize = try container.decodeIfPresent(Int.self, forKey: .maxContextSize) ?? 16000
        } else {
            // Migration from old fixed settings
            let legacyOutputCapture = try container.decodeIfPresent(Int.self, forKey: .maxOutputCapture) ?? 3000
            let legacyContextSize = try container.decodeIfPresent(Int.self, forKey: .maxContextSize) ?? 8000
            
            // Convert old fixed values to approximate percentages (assuming ~32K default context)
            // Old defaults: 3000 chars output, 8000 chars context
            // New: We'll set percentages that give similar results for a 32K model but scale up for larger models
            
            // If user customized old settings significantly higher, try to preserve that intent
            if legacyOutputCapture > 5000 {
                // User wanted more output - increase percentage
                outputCapturePercent = min(0.25, Double(legacyOutputCapture) / (32_000.0 * 4))
            } else {
                outputCapturePercent = 0.15 // Default for new users
            }
            
            if legacyContextSize > 12000 {
                // User wanted more context - increase percentage
                agentMemoryPercent = min(0.50, Double(legacyContextSize) / (32_000.0 * 4))
            } else {
                agentMemoryPercent = 0.40 // Default for new users
            }
            
            // Set new defaults for caps and minimums
            maxOutputCaptureCap = 50000
            maxAgentMemoryCap = 100000
            minOutputCapture = max(8000, legacyOutputCapture) // At least as much as they had before
            minContextSize = max(16000, legacyContextSize) // At least as much as they had before
            maxOutputCapture = minOutputCapture
            maxContextSize = minContextSize
        }
        
        outputSummarizationThreshold = try container.decodeIfPresent(Int.self, forKey: .outputSummarizationThreshold) ?? 10000
        enableOutputSummarization = try container.decodeIfPresent(Bool.self, forKey: .enableOutputSummarization) ?? true
        maxFullOutputBuffer = try container.decodeIfPresent(Int.self, forKey: .maxFullOutputBuffer) ?? 100000
        enablePlanning = try container.decodeIfPresent(Bool.self, forKey: .enablePlanning) ?? true
        reflectionInterval = try container.decodeIfPresent(Int.self, forKey: .reflectionInterval) ?? 10
        enableReflection = try container.decodeIfPresent(Bool.self, forKey: .enableReflection) ?? true
        stuckDetectionThreshold = try container.decodeIfPresent(Int.self, forKey: .stuckDetectionThreshold) ?? 3
        enableVerificationPhase = try container.decodeIfPresent(Bool.self, forKey: .enableVerificationPhase) ?? true
        httpRequestTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .httpRequestTimeout) ?? 10.0
        backgroundProcessTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundProcessTimeout) ?? 5.0
        fileLockTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .fileLockTimeout) ?? 30.0
        enableFileMerging = try container.decodeIfPresent(Bool.self, forKey: .enableFileMerging) ?? true
        defaultAgentMode = try container.decodeIfPresent(AgentMode.self, forKey: .defaultAgentMode) ?? .scout
        defaultAgentProfile = try container.decodeIfPresent(AgentProfile.self, forKey: .defaultAgentProfile) ?? .auto
        appAppearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appAppearance) ?? .system
        requireCommandApproval = try container.decodeIfPresent(Bool.self, forKey: .requireCommandApproval) ?? false
        autoApproveReadOnly = try container.decodeIfPresent(Bool.self, forKey: .autoApproveReadOnly) ?? true
        requireFileEditApproval = try container.decodeIfPresent(Bool.self, forKey: .requireFileEditApproval) ?? false
        enableApprovalNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableApprovalNotifications) ?? true
        enableApprovalNotificationSound = try container.decodeIfPresent(Bool.self, forKey: .enableApprovalNotificationSound) ?? true
        blockedCommandPatterns = try container.decodeIfPresent([String].self, forKey: .blockedCommandPatterns) ?? AgentSettings.defaultBlockedCommandPatterns
        verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
        showVerboseAgentEvents = try container.decodeIfPresent(Bool.self, forKey: .showVerboseAgentEvents) ?? false
        agentTemperature = try container.decodeIfPresent(Double.self, forKey: .agentTemperature) ?? 0.2
        titleTemperature = try container.decodeIfPresent(Double.self, forKey: .titleTemperature) ?? 1.0
        favoriteModels = try container.decodeIfPresent(Set<String>.self, forKey: .favoriteModels) ?? []
        terminalSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminalSuggestionsEnabled) ?? true
        terminalSuggestionsModelId = try container.decodeIfPresent(String.self, forKey: .terminalSuggestionsModelId)
        terminalSuggestionsProvider = try container.decodeIfPresent(ProviderType.self, forKey: .terminalSuggestionsProvider)
        terminalSuggestionsDebounceSeconds = try container.decodeIfPresent(Double.self, forKey: .terminalSuggestionsDebounceSeconds) ?? 2.5
        readShellHistory = try container.decodeIfPresent(Bool.self, forKey: .readShellHistory) ?? true
        terminalSuggestionsReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .terminalSuggestionsReasoningEffort) ?? .none
        terminalBellMode = try container.decodeIfPresent(TerminalBellMode.self, forKey: .terminalBellMode) ?? .sound
        testRunnerEnabled = try container.decodeIfPresent(Bool.self, forKey: .testRunnerEnabled) ?? false
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434/v1"
        lmStudioBaseURL = try container.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? "http://localhost:1234/v1"
        vllmBaseURL = try container.decodeIfPresent(String.self, forKey: .vllmBaseURL) ?? "http://localhost:8000/v1"
        favoriteCommands = try container.decodeIfPresent([FavoriteCommand].self, forKey: .favoriteCommands) ?? []
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxIterations, forKey: .maxIterations)
        try container.encode(maxToolCallsPerStep, forKey: .maxToolCallsPerStep)
        try container.encode(maxFixAttempts, forKey: .maxFixAttempts)
        try container.encode(commandTimeout, forKey: .commandTimeout)
        try container.encode(commandCaptureDelay, forKey: .commandCaptureDelay)
        
        // Dynamic context settings
        try container.encode(outputCapturePercent, forKey: .outputCapturePercent)
        try container.encode(agentMemoryPercent, forKey: .agentMemoryPercent)
        try container.encode(maxOutputCaptureCap, forKey: .maxOutputCaptureCap)
        try container.encode(maxAgentMemoryCap, forKey: .maxAgentMemoryCap)
        try container.encode(minOutputCapture, forKey: .minOutputCapture)
        try container.encode(minContextSize, forKey: .minContextSize)
        
        // Legacy settings (for backward compatibility)
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
        try container.encode(defaultAgentMode, forKey: .defaultAgentMode)
        try container.encode(defaultAgentProfile, forKey: .defaultAgentProfile)
        try container.encode(appAppearance, forKey: .appAppearance)
        try container.encode(requireCommandApproval, forKey: .requireCommandApproval)
        try container.encode(autoApproveReadOnly, forKey: .autoApproveReadOnly)
        try container.encode(requireFileEditApproval, forKey: .requireFileEditApproval)
        try container.encode(enableApprovalNotifications, forKey: .enableApprovalNotifications)
        try container.encode(enableApprovalNotificationSound, forKey: .enableApprovalNotificationSound)
        try container.encode(blockedCommandPatterns, forKey: .blockedCommandPatterns)
        try container.encode(verboseLogging, forKey: .verboseLogging)
        try container.encode(showVerboseAgentEvents, forKey: .showVerboseAgentEvents)
        try container.encode(agentTemperature, forKey: .agentTemperature)
        try container.encode(titleTemperature, forKey: .titleTemperature)
        try container.encode(favoriteModels, forKey: .favoriteModels)
        try container.encode(terminalSuggestionsEnabled, forKey: .terminalSuggestionsEnabled)
        try container.encodeIfPresent(terminalSuggestionsModelId, forKey: .terminalSuggestionsModelId)
        try container.encodeIfPresent(terminalSuggestionsProvider, forKey: .terminalSuggestionsProvider)
        try container.encode(terminalSuggestionsDebounceSeconds, forKey: .terminalSuggestionsDebounceSeconds)
        try container.encode(readShellHistory, forKey: .readShellHistory)
        try container.encode(terminalSuggestionsReasoningEffort, forKey: .terminalSuggestionsReasoningEffort)
        try container.encode(terminalBellMode, forKey: .terminalBellMode)
        try container.encode(testRunnerEnabled, forKey: .testRunnerEnabled)
        try container.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try container.encode(lmStudioBaseURL, forKey: .lmStudioBaseURL)
        try container.encode(vllmBaseURL, forKey: .vllmBaseURL)
        try container.encode(favoriteCommands, forKey: .favoriteCommands)
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
        maxToolCallsPerStep = 100
        maxFixAttempts = 3
        commandTimeout = 300.0
        commandCaptureDelay = 1.5
        
        // Dynamic context settings
        outputCapturePercent = 0.15
        agentMemoryPercent = 0.40
        maxOutputCaptureCap = 50000
        maxAgentMemoryCap = 100000
        minOutputCapture = 8000
        minContextSize = 16000
        
        // Legacy settings (now used as minimums/fallbacks)
        maxOutputCapture = 8000
        maxContextSize = 16000
        outputSummarizationThreshold = 10000
        enableOutputSummarization = true
        maxFullOutputBuffer = 100000
        enablePlanning = true
        reflectionInterval = 10
        enableReflection = true
        stuckDetectionThreshold = 3
        enableVerificationPhase = true
        httpRequestTimeout = 10.0
        backgroundProcessTimeout = 5.0
        fileLockTimeout = 30.0
        enableFileMerging = true
        defaultAgentMode = .scout
        defaultAgentProfile = .auto
        appAppearance = .system
        requireCommandApproval = false
        autoApproveReadOnly = true
        requireFileEditApproval = false
        enableApprovalNotifications = true
        enableApprovalNotificationSound = true
        blockedCommandPatterns = AgentSettings.defaultBlockedCommandPatterns
        verboseLogging = false
        showVerboseAgentEvents = false
        agentTemperature = 0.2
        titleTemperature = 1.0
        terminalSuggestionsEnabled = true
        terminalSuggestionsModelId = nil
        terminalSuggestionsProvider = nil
        terminalSuggestionsDebounceSeconds = 2.5
        readShellHistory = true
        terminalSuggestionsReasoningEffort = .none
        terminalBellMode = .sound
        testRunnerEnabled = false
        ollamaBaseURL = "http://localhost:11434/v1"
        lmStudioBaseURL = "http://localhost:1234/v1"
        vllmBaseURL = "http://localhost:8000/v1"
        favoriteCommands = []
        saveImmediately()
    }
    
    // MARK: - Favorite Commands Helpers
    
    /// Add a new favorite command
    func addFavoriteCommand(_ command: FavoriteCommand) {
        favoriteCommands.append(command)
        save()
    }
    
    /// Update an existing favorite command
    func updateFavoriteCommand(_ command: FavoriteCommand) {
        if let index = favoriteCommands.firstIndex(where: { $0.id == command.id }) {
            favoriteCommands[index] = command
            save()
        }
    }
    
    /// Remove a favorite command by ID
    func removeFavoriteCommand(id: UUID) {
        favoriteCommands.removeAll { $0.id == id }
        save()
    }
    
    /// Move favorite commands (for reordering)
    func moveFavoriteCommands(from source: IndexSet, to destination: Int) {
        favoriteCommands.move(fromOffsets: source, toOffset: destination)
        save()
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
    
    // MARK: - Destructive/Blocked Command Detection
    
    /// Check if a command matches any blocked pattern - these always require approval
    func isDestructiveCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        for pattern in blockedCommandPatterns {
            let lowerPattern = pattern.lowercased()
            
            // Check for exact match (e.g., command is just "rm" or "sudo")
            if trimmed == lowerPattern {
                return true
            }
            
            // Check for pattern as prefix with space or tab after (e.g., "rm file.txt")
            if trimmed.hasPrefix(lowerPattern + " ") || trimmed.hasPrefix(lowerPattern + "\t") {
                return true
            }
            
            // Check if pattern contains spaces (multi-word like "git push --force")
            // In this case, check if the command contains the pattern
            if lowerPattern.contains(" ") && trimmed.contains(lowerPattern) {
                return true
            }
            
            // For patterns ending with space (like "dd "), check prefix directly
            if lowerPattern.hasSuffix(" ") && trimmed.hasPrefix(lowerPattern) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Blocked Command Helpers
    
    /// Add a command pattern to the blocklist
    func addBlockedPattern(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedCommandPatterns.contains(trimmed) else { return }
        blockedCommandPatterns.append(trimmed)
        save()
    }
    
    /// Remove a command pattern from the blocklist
    func removeBlockedPattern(_ pattern: String) {
        blockedCommandPatterns.removeAll { $0 == pattern }
        save()
    }
    
    /// Remove blocked patterns at specific indices
    func removeBlockedPatterns(at offsets: IndexSet) {
        blockedCommandPatterns.remove(atOffsets: offsets)
        save()
    }
    
    /// Reset blocked patterns to defaults
    func resetBlockedPatternsToDefaults() {
        blockedCommandPatterns = AgentSettings.defaultBlockedCommandPatterns
        save()
    }
    
    /// Determine if a command should be auto-approved based on settings
    func shouldAutoApprove(_ command: String) -> Bool {
        // Never auto-approve destructive commands
        if isDestructiveCommand(command) {
            return false
        }
        if !requireCommandApproval {
            return true
        }
        if autoApproveReadOnly && isReadOnlyCommand(command) {
            return true
        }
        return false
    }
}

