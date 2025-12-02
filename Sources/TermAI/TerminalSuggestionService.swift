import Foundation
import os.log

private let suggestionLogger = Logger(subsystem: "com.termai.app", category: "Suggestions")

// MARK: - Data Models

/// Source of a command suggestion
enum SuggestionSource: String, Codable {
    case projectContext   // Detected from package.json, Cargo.toml, etc.
    case errorAnalysis    // Suggested fix for error output
    case gitStatus        // Git-aware suggestions
    case cwdChange        // Common commands for new directory
    case generalContext   // General contextual suggestion
    case startup          // Shown on terminal open or directory change
    case resumeCommand    // Recent command from history
    case shellHistory     // From user's shell history file
}

/// Detected project type for context-aware suggestions
enum ProjectType: String, Codable {
    case node       // package.json
    case swift      // Package.swift
    case rust       // Cargo.toml
    case python     // setup.py, pyproject.toml, requirements.txt
    case go         // go.mod
    case ruby       // Gemfile
    case java       // pom.xml, build.gradle
    case dotnet     // *.csproj, *.sln
    case unknown
    
    /// Common startup commands for this project type
    var commonCommands: [(command: String, reason: String)] {
        switch self {
        case .node:
            return [
                ("npm install", "Install dependencies"),
                ("npm start", "Start development server"),
                ("npm run dev", "Run dev script"),
                ("npm test", "Run tests")
            ]
        case .swift:
            return [
                ("swift build", "Build the package"),
                ("swift run", "Build and run"),
                ("swift test", "Run tests")
            ]
        case .rust:
            return [
                ("cargo build", "Build the project"),
                ("cargo run", "Build and run"),
                ("cargo test", "Run tests"),
                ("cargo check", "Check for errors")
            ]
        case .python:
            return [
                ("pip install -r requirements.txt", "Install dependencies"),
                ("python -m venv venv", "Create virtual environment"),
                ("source venv/bin/activate", "Activate venv"),
                ("pytest", "Run tests")
            ]
        case .go:
            return [
                ("go build", "Build the project"),
                ("go run .", "Run the project"),
                ("go test ./...", "Run tests"),
                ("go mod tidy", "Tidy dependencies")
            ]
        case .ruby:
            return [
                ("bundle install", "Install dependencies"),
                ("bundle exec rails s", "Start Rails server"),
                ("bundle exec rspec", "Run tests")
            ]
        case .java:
            return [
                ("mvn clean install", "Build with Maven"),
                ("./gradlew build", "Build with Gradle"),
                ("mvn test", "Run Maven tests")
            ]
        case .dotnet:
            return [
                ("dotnet build", "Build the project"),
                ("dotnet run", "Run the project"),
                ("dotnet test", "Run tests")
            ]
        case .unknown:
            return []
        }
    }
}

/// A single command suggestion
struct CommandSuggestion: Identifiable, Codable, Equatable {
    let id: UUID
    let command: String
    let reason: String
    let confidence: Double
    let source: SuggestionSource
    
    init(command: String, reason: String, confidence: Double = 0.8, source: SuggestionSource) {
        self.id = UUID()
        self.command = command
        self.reason = reason
        self.confidence = confidence
        self.source = source
    }
    
    static func == (lhs: CommandSuggestion, rhs: CommandSuggestion) -> Bool {
        lhs.command == rhs.command
    }
}

/// Context passed to the suggestion engine
struct TerminalContext {
    let cwd: String
    let lastOutput: String
    let lastExitCode: Int32
    let gitInfo: GitInfo?
    let recentCommands: [String]
    
    /// Create a hash for cache lookup
    var cacheKey: String {
        let gitPart = gitInfo.map { "\($0.branch):\($0.isDirty)" } ?? "nogit"
        let exitPart = lastExitCode != 0 ? "err\(lastExitCode)" : "ok"
        return "\(cwd)|\(gitPart)|\(exitPart)|\(lastOutput.prefix(100).hashValue)"
    }
}

/// A command executed during the session with its outcome
struct SessionCommand {
    let command: String
    let exitCode: Int32
    let timestamp: Date
    let cwd: String
    
    init(command: String, exitCode: Int32, cwd: String) {
        self.command = command
        self.exitCode = exitCode
        self.timestamp = Date()
        self.cwd = cwd
    }
}

// MARK: - Suggestion Pipeline Phase

/// Represents the current phase of the agentic suggestion pipeline
enum SuggestionPhase: Equatable, CustomStringConvertible {
    case idle
    case gatheringContext(detail: String)
    case researching(detail: String, step: Int)
    case planning
    case generating
    case readingOutput
    case updatingContext
    
    var description: String {
        switch self {
        case .idle:
            return ""
        case .gatheringContext(let detail):
            return detail
        case .researching(let detail, let step):
            return "[\(step)] \(detail)"
        case .planning:
            return "Planning suggestions..."
        case .generating:
            return "Generating suggestions..."
        case .readingOutput:
            return "Reading terminal output..."
        case .updatingContext:
            return "Updating context..."
        }
    }
    
    /// Whether this phase represents active processing
    var isActive: Bool {
        switch self {
        case .idle:
            return false
        default:
            return true
        }
    }
    
    /// Short label for UI display
    var label: String {
        switch self {
        case .idle:
            return ""
        case .gatheringContext:
            return "Context"
        case .researching:
            return "Researching"
        case .planning:
            return "Planning"
        case .generating:
            return "Generating"
        case .readingOutput:
            return "Reading"
        case .updatingContext:
            return "Updating"
        }
    }
}

/// Gathered context for the suggestion pipeline
struct GatheredContext {
    /// Top N frequent commands with counts: "git (42), npm (28), ..."
    var frequentCommandsFormatted: String = ""
    
    /// Last N recent commands
    var recentCommands: [String] = []
    
    /// Environment info (installed tools, project type, etc.)
    var environmentInfo: [String] = []
    
    /// Shell config insights (aliases, shortcuts)
    var shellConfigInsights: [String] = []
    
    /// Current terminal output (for post-command analysis)
    var terminalOutput: String = ""
    
    /// Last command exit code
    var lastExitCode: Int32 = 0
    
    /// Last command run
    var lastCommand: String? = nil
    
    /// Formatted string for AI prompts
    var formattedForPrompt: String {
        var parts: [String] = []
        
        if !frequentCommandsFormatted.isEmpty {
            parts.append("=== Frequent Commands ===\n\(frequentCommandsFormatted)")
        }
        
        if !recentCommands.isEmpty {
            parts.append("=== Recent Commands ===\n\(recentCommands.joined(separator: "\n"))")
        }
        
        if !environmentInfo.isEmpty {
            parts.append("=== Environment ===\n\(environmentInfo.joined(separator: "\n"))")
        }
        
        if !shellConfigInsights.isEmpty {
            parts.append("=== Shell Config ===\n\(shellConfigInsights.joined(separator: "\n"))")
        }
        
        if !terminalOutput.isEmpty {
            let truncated = String(terminalOutput.prefix(500))
            parts.append("=== Terminal Output ===\n\(truncated)")
        }
        
        return parts.joined(separator: "\n\n")
    }
}

/// Plan generated by the planning phase
struct SuggestionPlan {
    /// What the user appears to be doing
    var userIntent: String = ""
    
    /// Whether suggestions are needed
    var shouldSuggest: Bool = true
    
    /// Type of suggestions to generate
    var suggestionType: String = "general" // "error_fix", "next_step", "workflow", "general"
    
    /// Focus area for suggestions
    var focusArea: String? = nil
    
    /// Number of suggestions to generate
    var suggestionCount: Int = 2
}

/// Findings from the AI-driven research phase
struct ResearchFindings {
    /// Files that were read and their key insights
    var fileInsights: [(path: String, insight: String)] = []
    
    /// Directories that were explored
    var exploredDirectories: [String] = []
    
    /// Key discoveries about the project/environment
    var discoveries: [String] = []
    
    /// Number of research steps taken
    var stepsTaken: Int = 0
    
    /// Whether research was completed (vs hitting step limit)
    var completed: Bool = false
    
    /// Format findings for inclusion in prompts
    var formattedForPrompt: String {
        guard !discoveries.isEmpty || !fileInsights.isEmpty else {
            return ""
        }
        
        var parts: [String] = []
        
        if !discoveries.isEmpty {
            parts.append("=== Research Discoveries ===\n\(discoveries.joined(separator: "\n"))")
        }
        
        if !fileInsights.isEmpty {
            let insights = fileInsights.map { "• \($0.path): \($0.insight)" }.joined(separator: "\n")
            parts.append("=== File Insights ===\n\(insights)")
        }
        
        return parts.joined(separator: "\n\n")
    }
}

/// Structured environment context for the suggestion pipeline
struct EnvironmentContext {
    /// Detected project type
    var projectType: ProjectType = .unknown
    
    /// Installed development tools (detected from config files)
    var installedTools: [String] = []
    
    /// Current project technologies (from project files in cwd)
    var projectTechnologies: [String] = []
    
    /// Shell framework (oh-my-zsh, prezto, etc.)
    var shellFramework: String? = nil
    
    /// Directory shortcuts/aliases
    var directoryAliases: [(name: String, path: String)] = []
    
    /// Important paths from exports
    var importantPaths: [String] = []
    
    /// Custom shell functions
    var shellFunctions: [String] = []
    
    /// Git info if in a repo
    var gitInfo: GitInfo? = nil
    
    /// Current working directory
    var cwd: String = ""
    
    /// Formatted string for AI prompts
    /// Note: Prioritizes CWD, project type, and git status first (primary context),
    /// then shell config, then installed tools last (reference only).
    var formattedForPrompt: String {
        var parts: [String] = []
        
        // === PRIMARY CONTEXT (most relevant for suggestions) ===
        parts.append("CWD: \(cwd)")
        
        if projectType != .unknown {
            parts.append("Project type: \(projectType.rawValue)")
        }
        
        if !projectTechnologies.isEmpty {
            parts.append("Technologies in CWD: \(projectTechnologies.joined(separator: ", "))")
        }
        
        if let git = gitInfo {
            var gitParts = ["Git: branch=\(git.branch)"]
            if git.isDirty { gitParts.append("dirty") }
            if git.ahead > 0 { gitParts.append("\(git.ahead) to push") }
            if git.behind > 0 { gitParts.append("\(git.behind) to pull") }
            parts.append(gitParts.joined(separator: ", "))
        }
        
        // === SECONDARY CONTEXT (shell customizations) ===
        if !directoryAliases.isEmpty {
            let aliases = directoryAliases.prefix(5).map { "\($0.name)→\($0.path)" }.joined(separator: ", ")
            parts.append("Dir shortcuts: \(aliases)")
        }
        
        if let framework = shellFramework {
            parts.append("Shell: \(framework)")
        }
        
        // === REFERENCE INFO (installed tools - for context only, not driving suggestions) ===
        // Note: Command history is a better signal of what user actually uses
        if !installedTools.isEmpty {
            parts.append("Installed (ref only): \(installedTools.prefix(10).joined(separator: ", "))")
        }
        
        return parts.joined(separator: "\n")
    }
}

/// Session-level context that tracks user patterns and activity
struct SessionContext {
    /// Commands executed this session
    var commandsThisSession: [SessionCommand] = []
    
    /// AI-generated summary of what the user typically does (from history analysis)
    var usagePatternSummary: String? = nil
    
    /// AI-generated rolling summary of current session activity
    var sessionSummary: String? = nil
    
    /// Number of commands since last summary update
    var commandsSinceLastSummary: Int = 0
    
    /// Whether history analysis has been performed
    var hasAnalyzedHistory: Bool = false
    
    /// Add a command to the session
    mutating func addCommand(_ command: String, exitCode: Int32, cwd: String) {
        commandsThisSession.append(SessionCommand(command: command, exitCode: exitCode, cwd: cwd))
        commandsSinceLastSummary += 1
    }
    
    /// Get recent commands as strings for prompts
    func recentCommandStrings(limit: Int = 10) -> [String] {
        return commandsThisSession.suffix(limit).map { cmd in
            let status = cmd.exitCode == 0 ? "✓" : "✗(\(cmd.exitCode))"
            return "\(cmd.command) \(status)"
        }
    }
    
    /// Check if we should update the rolling summary (every 3-5 commands)
    var shouldUpdateSummary: Bool {
        return commandsSinceLastSummary >= 3
    }
}

// MARK: - Terminal Suggestion Service

/// Service that generates AI-powered command suggestions based on terminal context
/// Create one instance per terminal tab to avoid state sharing issues
@MainActor
final class TerminalSuggestionService: ObservableObject {
    /// Shared instance for backwards compatibility (settings previews, etc.)
    /// Prefer creating per-tab instances for actual terminal use
    static let shared = TerminalSuggestionService()
    
    // MARK: - Published State
    
    @Published var suggestions: [CommandSuggestion] = []
    @Published var isLoading: Bool = false
    @Published var needsModelSetup: Bool = false
    @Published var lastError: String? = nil
    @Published var isVisible: Bool = false
    @Published var sessionContext: SessionContext = SessionContext()
    
    /// Current phase of the agentic suggestion pipeline
    @Published var currentPhase: SuggestionPhase = .idle
    
    /// Detailed status message for the current phase
    @Published var phaseDetail: String? = nil
    
    /// Gathered context from the pipeline (for debugging/display)
    @Published var gatheredContext: GatheredContext = GatheredContext()
    
    // MARK: - Private State
    
    private var debounceTask: Task<Void, Never>?
    private var activeAPITask: Task<Void, Never>?
    private var postCommandTask: Task<Void, Never>?
    private var suggestionCache: [String: (suggestions: [CommandSuggestion], timestamp: Date)] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    private let maxCacheSize: Int = 50 // Maximum number of cached contexts
    private var lastContext: TerminalContext?
    
    /// Cooldown after command execution to prevent old cache from showing
    private var commandExecutionCooldown: Date? = nil
    private let cooldownDuration: TimeInterval = 0.5 // 500ms cooldown after running a command
    private let postCommandDelay: TimeInterval = 1.0 // Wait for terminal output to stabilize
    
    /// Tracks when user manually dismissed suggestions (via X button or Escape)
    /// When true, cached suggestions won't be shown until a meaningful event resets it
    private var userDismissed: Bool = false
    
    /// Hash of the last processed output to prevent duplicate triggers
    private var lastProcessedOutputHash: Int = 0
    
    /// Callback to get fresh terminal context for post-command regeneration
    var getTerminalContext: (() -> (cwd: String, lastOutput: String, lastExitCode: Int32, gitInfo: GitInfo?))?
    
    /// Callback to check if the chat agent is currently running
    /// When true, suggestion generation is paused to avoid confusion from agent-generated terminal activity
    var checkAgentRunning: (() -> Bool)?
    
    /// Cache for project type detection results (path -> (projectType, timestamp))
    private var projectTypeCache: [String: (type: ProjectType, timestamp: Date)] = [:]
    private let projectTypeCacheExpiration: TimeInterval = 60 // 1 minute (shorter since directories can change)
    
    /// Cache for installed dev tools (home directory based, changes rarely)
    private var installedToolsCache: (tools: [String], timestamp: Date)?
    private let installedToolsCacheExpiration: TimeInterval = 600 // 10 minutes
    
    /// Cache for shell config parsing results (changes rarely)
    private var shellConfigCache: (framework: String?, aliases: [(name: String, path: String)], functions: [String], paths: [String], timestamp: Date)?
    private let shellConfigCacheExpiration: TimeInterval = 600 // 10 minutes
    
    // MARK: - Research Phase Tracking
    
    /// Directory where research was last performed
    private var lastResearchCWD: String? = nil
    
    /// Counter for commands run since last research phase
    private var commandsSinceLastResearch: Int = 0
    
    /// Timestamp of last research phase
    private var lastResearchTimestamp: Date? = nil
    
    /// Number of commands before triggering periodic research
    private let researchCommandThreshold: Int = 5
    
    /// Create a new suggestion service instance
    /// Each terminal tab should have its own instance
    init() {
        updateNeedsModelSetup()
    }
    
    // MARK: - Public API
    
    /// Update the needsModelSetup flag based on current settings
    func updateNeedsModelSetup() {
        let settings = AgentSettings.shared
        needsModelSetup = settings.terminalSuggestionsEnabled && !settings.isTerminalSuggestionsConfigured
    }
    
    /// Set the current phase with an optional detail message
    func setPhase(_ phase: SuggestionPhase, detail: String? = nil) {
        suggestionLogger.debug("Phase transition: \(self.currentPhase.label) → \(phase.label)\(detail.map { " (\($0))" } ?? "")")
        currentPhase = phase
        phaseDetail = detail
        
        // Update isLoading based on phase
        isLoading = phase.isActive
    }
    
    /// Cancel all active work (debounce, API calls, post-command tasks)
    /// Call this when user activity is detected to abort stale processing
    func cancelActiveWork() {
        let hadActiveWork = debounceTask != nil || activeAPITask != nil || postCommandTask != nil
        
        debounceTask?.cancel()
        debounceTask = nil
        
        activeAPITask?.cancel()
        activeAPITask = nil
        
        postCommandTask?.cancel()
        postCommandTask = nil
        
        if hadActiveWork {
            suggestionLogger.info("Cancelled active work (debounce/API/postCommand tasks)")
            setPhase(.idle)
        }
    }
    
    /// Resume suggestions after the chat agent has finished running
    /// This triggers a fresh suggestion pipeline using the terminal context callback
    func resumeSuggestionsAfterAgent() {
        suggestionLogger.info("Resuming suggestions after agent completed")
        
        // Get fresh terminal context if callback is available
        guard let getContext = getTerminalContext else {
            suggestionLogger.warning("No terminal context callback available for resume")
            return
        }
        
        let ctx = getContext()
        
        // Trigger suggestions with fresh context
        triggerSuggestions(
            cwd: ctx.cwd,
            lastOutput: ctx.lastOutput,
            lastExitCode: ctx.lastExitCode,
            gitInfo: ctx.gitInfo
        )
    }
    
    /// Called when user activity is detected (command entered, cd, etc.)
    /// This aborts any in-progress pipeline and prepares for fresh suggestions
    /// The actual pipeline will be triggered by subsequent events (CWD change, output change)
    /// - Parameters:
    ///   - command: The command the user entered (optional)
    ///   - cwd: Current working directory
    ///   - gitInfo: Git info if available
    ///   - lastExitCode: Last exit code
    ///   - lastOutput: Last terminal output
    func userActivityDetected(
        command: String? = nil,
        cwd: String,
        gitInfo: GitInfo?,
        lastExitCode: Int32,
        lastOutput: String
    ) {
        // Ignore activity from chat agent - don't track agent commands as user activity
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Activity ignored - chat agent is currently running")
            return
        }
        
        suggestionLogger.info("User activity detected: \(command ?? "unknown command"), aborting active work")
        
        // Cancel any ongoing work
        cancelActiveWork()
        
        // Reset tracking state so new context is processed fresh
        userDismissed = false
        lastProcessedOutputHash = 0
        
        // Record command to session if provided
        if let cmd = command, !cmd.isEmpty {
            sessionContext.addCommand(cmd, exitCode: 0, cwd: cwd)
            gatheredContext.lastCommand = cmd
            commandsSinceLastResearch += 1
        }
        
        // Set cooldown and clear existing suggestions
        commandExecutionCooldown = Date()
        suggestions = []
        isVisible = false
        lastError = nil
        
        // Invalidate cache for last context
        if let ctx = lastContext {
            suggestionCache.removeValue(forKey: ctx.cacheKey)
        }
        
        // Update lastContext with current state
        // Subsequent triggers (CWD change, output change) will detect changes and start pipeline
        lastContext = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: []
        )
        
        // DON'T start our own debounce task here - let triggerSuggestions handle it
        // when the subsequent events fire (CWD change, output change, etc.)
        // This prevents conflicting debounce tasks that cancel each other
        suggestionLogger.debug("User activity processed, waiting for context change events to trigger pipeline")
    }
    
    /// Gather structured environment context for the suggestion pipeline
    /// This is a programmatic analysis (no AI calls) with caching
    func getStructuredEnvironmentContext(cwd: String, gitInfo: GitInfo?) -> EnvironmentContext {
        var context = EnvironmentContext()
        context.cwd = cwd
        context.gitInfo = gitInfo
        context.projectType = detectProjectType(at: cwd)
        
        // 1. Get installed dev tools (cached)
        context.installedTools = getCachedInstalledTools()
        
        // 2. Check current directory for project indicators (not cached - cwd specific)
        context.projectTechnologies = detectProjectTechnologies(at: cwd)
        
        // 3. Get shell config info (cached)
        let shellInfo = getCachedShellConfigInfo()
        context.shellFramework = shellInfo.framework
        context.directoryAliases = shellInfo.aliases
        context.shellFunctions = shellInfo.functions
        context.importantPaths = shellInfo.paths
        
        return context
    }
    
    /// Get installed dev tools with caching (10 minute TTL)
    private func getCachedInstalledTools() -> [String] {
        // Check cache validity
        if let cached = installedToolsCache,
           Date().timeIntervalSince(cached.timestamp) < installedToolsCacheExpiration {
            return cached.tools
        }
        
        // Perform detection
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        
        let devConfigs: [(file: String, description: String)] = [
            (".npmrc", "npm"), (".yarnrc", "Yarn"), (".pnpmrc", "pnpm"),
            (".cargo/config.toml", "Cargo"), (".docker", "Docker"),
            (".kube/config", "Kubernetes"), (".aws/credentials", "AWS"),
            (".gcloud", "GCloud"), (".terraform.d", "Terraform"),
            (".volta", "Volta"), (".rustup", "Rustup"), (".nvm", "nvm"),
            (".pyenv", "pyenv"), (".rbenv", "rbenv"), (".sdkman", "SDKMAN"),
            (".config/gh", "GitHub CLI")
        ]
        
        var tools: [String] = []
        for config in devConfigs {
            let path = (home as NSString).appendingPathComponent(config.file)
            if fm.fileExists(atPath: path) {
                tools.append(config.description)
            }
        }
        
        // Cache the result
        installedToolsCache = (tools: tools, timestamp: Date())
        return tools
    }
    
    /// Detect project technologies for a specific directory (not cached - cwd specific)
    private func detectProjectTechnologies(at cwd: String) -> [String] {
        let fm = FileManager.default
        let projectFiles: [(file: String, meaning: String)] = [
            ("package.json", "Node.js"), ("Cargo.toml", "Rust"),
            ("go.mod", "Go"), ("requirements.txt", "Python"),
            ("pyproject.toml", "Python"), ("Gemfile", "Ruby"),
            ("pom.xml", "Maven"), ("build.gradle", "Gradle"),
            ("Package.swift", "Swift"), ("docker-compose.yml", "Docker Compose"),
            ("Dockerfile", "Docker"), ("Makefile", "Make"),
            (".terraform", "Terraform"), ("Chart.yaml", "Helm"),
            (".github/workflows", "GitHub Actions")
        ]
        
        var technologies: [String] = []
        for pf in projectFiles {
            let path = (cwd as NSString).appendingPathComponent(pf.file)
            if fm.fileExists(atPath: path) {
                technologies.append(pf.meaning)
            }
        }
        return technologies
    }
    
    /// Get shell config info with caching (10 minute TTL)
    private func getCachedShellConfigInfo() -> (framework: String?, aliases: [(name: String, path: String)], functions: [String], paths: [String]) {
        // Check cache validity
        if let cached = shellConfigCache,
           Date().timeIntervalSince(cached.timestamp) < shellConfigCacheExpiration {
            return (cached.framework, cached.aliases, cached.functions, cached.paths)
        }
        
        // Perform shell config parsing
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        
        var shellFramework: String? = nil
        var directoryAliases: [(name: String, path: String)] = []
        var shellFunctions: [String] = []
        var importantPaths: [String] = []
        
        let shellConfigs = [".zshrc", ".bashrc", ".bash_profile"]
        for configFile in shellConfigs {
            let path = (home as NSString).appendingPathComponent(configFile)
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
                
                // Detect shell framework
                if trimmed.contains("oh-my-zsh") || trimmed.contains("ZSH_THEME") {
                    shellFramework = "oh-my-zsh"
                } else if trimmed.contains("starship") {
                    shellFramework = "starship"
                } else if trimmed.contains("powerlevel10k") {
                    shellFramework = "powerlevel10k"
                }
                
                // Extract cd aliases
                if trimmed.hasPrefix("alias ") {
                    if let aliasInfo = extractAliasWithDetails(from: trimmed) {
                        if aliasInfo.command.hasPrefix("cd ") {
                            let dirPath = aliasInfo.command.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            directoryAliases.append((aliasInfo.name, dirPath))
                        }
                    }
                }
                
                // Extract function names (limit to avoid noise)
                if shellFunctions.count < 10 {
                    if trimmed.hasPrefix("function ") || (trimmed.contains("()") && trimmed.contains("{")) {
                        if let funcName = extractFunctionName(from: trimmed) {
                            shellFunctions.append(funcName)
                        }
                    }
                }
                
                // Extract important paths
                if importantPaths.count < 10 {
                    if trimmed.contains("=") && (trimmed.contains("~/") || trimmed.contains("$HOME")) {
                        if let dirVar = extractDirectoryVariable(from: trimmed) {
                            importantPaths.append(dirVar)
                        }
                    }
                }
            }
        }
        
        // Cache the result
        shellConfigCache = (framework: shellFramework, aliases: directoryAliases, functions: shellFunctions, paths: importantPaths, timestamp: Date())
        return (shellFramework, directoryAliases, shellFunctions, importantPaths)
    }
    
    // MARK: - Agentic Suggestion Pipeline
    
    /// Run the full agentic suggestion pipeline
    /// This is the main entry point for generating quality suggestions
    /// - Parameters:
    ///   - context: Terminal context (cwd, output, exit code, git info)
    ///   - isStartup: Whether this is the startup flow (more comprehensive context gathering)
    func runAgenticPipeline(context: TerminalContext, isStartup: Bool = false) async {
        suggestionLogger.info(">>> Starting agentic pipeline (startup: \(isStartup)) <<<")
        
        // Pause suggestions while chat agent is running
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Pipeline: Skipping - chat agent is currently running")
            setPhase(.idle)
            return
        }
        
        let settings = AgentSettings.shared
        
        // Check if configured
        guard settings.isTerminalSuggestionsConfigured,
              let provider = settings.terminalSuggestionsProvider,
              let modelId = settings.terminalSuggestionsModelId else {
            suggestionLogger.warning("Pipeline: Model not configured")
            updateNeedsModelSetup()
            setPhase(.idle)
            return
        }
        
        lastContext = context
        lastError = nil
        isVisible = true
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: Gather Context (Programmatic)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.gatheringContext(detail: "Reading shell history..."))
        
        var gathered = GatheredContext()
        gathered.terminalOutput = context.lastOutput
        gathered.lastExitCode = context.lastExitCode
        
        // Get history statistics (programmatic, no AI)
        if settings.readShellHistory && ShellHistoryParser.shared.isAvailable() {
            let historyContext = ShellHistoryParser.shared.getFormattedHistoryContext(topN: 10, recentN: 10)
            gathered.frequentCommandsFormatted = historyContext.frequentFormatted
            gathered.recentCommands = historyContext.recent
            suggestionLogger.info("Phase 1: Got \(gathered.recentCommands.count, privacy: .public) recent commands, frequent: \(historyContext.frequentFormatted.prefix(100), privacy: .public)")
        }
        
        // Also include session commands
        if !sessionContext.commandsThisSession.isEmpty {
            let sessionCmds = sessionContext.recentCommandStrings(limit: 5)
            gathered.recentCommands.insert(contentsOf: sessionCmds, at: 0)
        }
        
        setPhase(.gatheringContext(detail: "Detecting environment..."))
        
        // Get structured environment context (programmatic)
        let envContext = getStructuredEnvironmentContext(cwd: context.cwd, gitInfo: context.gitInfo)
        gathered.environmentInfo.append(envContext.formattedForPrompt)
        
        // Add shell config insights
        gathered.shellConfigInsights = gatherEnvironmentInfo()
        
        // Update the published gathered context for UI
        gatheredContext = gathered
        
        suggestionLogger.info("Phase 1 complete: \(gathered.formattedForPrompt.prefix(200))...")
        
        // Check for cancellation
        guard !Task.isCancelled else {
            setPhase(.idle)
            return
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1.5: Research Phase (AI-Driven Context Exploration)
        // ═══════════════════════════════════════════════════════════════════
        // Run research phase based on context-aware decision (errors, CWD changes, periodic)
        var researchFindings = ResearchFindings()
        if shouldRunResearch(isStartup: isStartup, terminalContext: context, gathered: gathered, envContext: envContext) {
            suggestionLogger.info("Phase 1.5: Starting research phase...")
            
            researchFindings = await runResearchPhase(
                gathered: gathered,
                envContext: envContext,
                terminalContext: context,
                provider: provider,
                modelId: modelId
            )
            
            suggestionLogger.info("Phase 1.5 complete: \(researchFindings.stepsTaken) steps, \(researchFindings.discoveries.count) discoveries")
            
            // Update research tracking state
            lastResearchCWD = context.cwd
            commandsSinceLastResearch = 0
            lastResearchTimestamp = Date()
            
            // Check for cancellation
            guard !Task.isCancelled else {
                setPhase(.idle)
                return
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: Planning (AI Call)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.planning)
        suggestionLogger.info("Phase 2: Planning...")
        
        let plan = await planSuggestions(
            gathered: gathered,
            envContext: envContext,
            terminalContext: context,
            researchFindings: researchFindings,
            provider: provider,
            modelId: modelId
        )
        
        // Check if we should suggest
        guard plan.shouldSuggest else {
            suggestionLogger.info("Planning decided no suggestions needed")
            suggestions = []
            setPhase(.idle)
            isVisible = false
            return
        }
        
        // Check for cancellation
        guard !Task.isCancelled else {
            setPhase(.idle)
            return
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 3: Generate Suggestions (AI Call)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.generating)
        suggestionLogger.info("Phase 3: Generating suggestions (type: \(plan.suggestionType))...")
        
        let generatedSuggestions = await generateSuggestionsFromPlan(
            plan: plan,
            gathered: gathered,
            envContext: envContext,
            terminalContext: context,
            researchFindings: researchFindings,
            provider: provider,
            modelId: modelId
        )
        
        // Update suggestions
        suggestions = generatedSuggestions
        cacheSuggestions(generatedSuggestions, for: context)
        
        suggestionLogger.info("Pipeline complete: \(generatedSuggestions.count) suggestions generated")
        
        setPhase(.idle)
        isVisible = !generatedSuggestions.isEmpty
    }
    
    // MARK: - Research Phase
    
    /// Maximum number of research steps before stopping
    private let maxResearchSteps = 20
    
    /// Available tools for research phase (subset of agent tools)
    private let researchToolNames = ["read_file", "list_dir", "search_files"]
    
    /// Determine if research phase should run based on context
    /// Research runs when context has changed significantly or periodically
    /// - Parameters:
    ///   - isStartup: Whether this is the startup flow
    ///   - terminalContext: Current terminal context
    ///   - gathered: Gathered context from programmatic phase
    ///   - envContext: Environment context
    /// - Returns: Whether research should be performed
    private func shouldRunResearch(
        isStartup: Bool,
        terminalContext: TerminalContext,
        gathered: GatheredContext,
        envContext: EnvironmentContext
    ) -> Bool {
        // Always research on startup
        if isStartup {
            suggestionLogger.info("Research decision: YES (startup)")
            return true
        }
        
        // Research on errors (context needed for fixes)
        if terminalContext.lastExitCode != 0 {
            suggestionLogger.info("Research decision: YES (error exit code \(terminalContext.lastExitCode))")
            return true
        }
        
        // Research if we've never researched before (first pipeline run)
        guard let lastCWD = lastResearchCWD else {
            suggestionLogger.info("Research decision: YES (first research, no prior CWD, current=\(terminalContext.cwd, privacy: .public))")
            return true
        }
        
        // Research when CWD changed (new environment to explore)
        suggestionLogger.debug("CWD check: current='\(terminalContext.cwd, privacy: .public)' last='\(lastCWD, privacy: .public)'")
        if terminalContext.cwd != lastCWD {
            suggestionLogger.info("Research decision: YES (CWD changed from \(lastCWD, privacy: .public) to \(terminalContext.cwd, privacy: .public))")
            return true
        }
        
        // Research periodically (every N commands)
        if commandsSinceLastResearch >= researchCommandThreshold {
            suggestionLogger.info("Research decision: YES (periodic, \(self.commandsSinceLastResearch) commands since last research)")
            return true
        }
        
        // Research in unknown environments (original fallback logic)
        if gathered.recentCommands.isEmpty && envContext.projectType == .unknown {
            suggestionLogger.info("Research decision: YES (unknown environment)")
            return true
        }
        
        suggestionLogger.info("Research decision: NO (context unchanged, \(self.commandsSinceLastResearch)/\(self.researchCommandThreshold) commands)")
        return false
    }
    
    /// Run the AI-driven research phase to gather additional context
    /// The AI can use tools (read_file, list_dir, search_files) to explore the environment
    /// - Parameters:
    ///   - gathered: Initial gathered context from programmatic phase
    ///   - envContext: Environment context (cwd, git info, etc.)
    ///   - terminalContext: Terminal context
    ///   - provider: LLM provider
    ///   - modelId: Model ID
    /// - Returns: Research findings including file insights and discoveries
    private func runResearchPhase(
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        provider: ProviderType,
        modelId: String
    ) async -> ResearchFindings {
        var findings = ResearchFindings()
        var contextAccumulator: [String] = []
        var consecutiveParseFailures = 0
        let maxConsecutiveFailures = 3  // Exit early if AI keeps returning unparseable responses
        
        let toolDescriptions = """
        Available tools for gathering context:
        - read_file: Read a file's contents. Args: {"path": "relative/or/absolute/path", "start_line": 1, "end_line": 50}
        - list_dir: List directory contents. Args: {"path": "directory/path", "recursive": "false"}
        - search_files: Search for files by pattern. Args: {"path": "directory", "pattern": "*.swift"}
        """
        
        let systemPrompt = """
        You are a research assistant gathering context to provide helpful terminal command suggestions.
        Your job is to explore the user's environment to understand what they might need to do next.
        
        \(toolDescriptions)
        
        Based on the current context, decide if you need more information. If yes, call ONE tool.
        If you have enough context OR have already gathered sufficient info, respond with done.
        
        IMPORTANT: Reply with ONLY a JSON object, no other text. Examples:
        {"tool": "list_dir", "args": {"path": "."}, "reason": "see project structure"}
        {"tool": "read_file", "args": {"path": "package.json"}, "reason": "check dependencies"}
        {"done": true, "summary": "Found Node.js project with npm scripts"}
        
        After 3-5 tool calls, you should have enough context - respond with done.
        """
        
        for step in 1...maxResearchSteps {
            // Check for cancellation
            guard !Task.isCancelled else {
                suggestionLogger.debug("Research phase cancelled at step \(step)")
                break
            }
            
            setPhase(.researching(detail: "Exploring context...", step: step))
            
            // Build the user prompt with accumulated context
            var userPrompt = """
            Current directory: \(terminalContext.cwd)
            Project type: \(envContext.projectType.rawValue)
            """
            
            if let git = envContext.gitInfo {
                userPrompt += "\nGit: branch=\(git.branch), dirty=\(git.isDirty)"
            }
            
            if !gathered.recentCommands.isEmpty {
                userPrompt += "\nRecent commands: \(gathered.recentCommands.prefix(5).joined(separator: ", "))"
            }
            
            if !contextAccumulator.isEmpty {
                userPrompt += "\n\n=== Previous Research ===\n\(contextAccumulator.joined(separator: "\n"))"
            }
            
            userPrompt += "\n\nWhat additional context would help you suggest useful commands? Call a tool or say done."
            
            do {
                let response = try await LLMClient.shared.complete(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    provider: provider,
                    modelId: modelId,
                    reasoningEffort: .none,
                    maxTokens: 300,
                    timeout: 15,
                    requestType: .suggestionResearch
                )
                
                // Parse the response
                guard let parsed = parseResearchResponse(response) else {
                    consecutiveParseFailures += 1
                    suggestionLogger.warning("Research step \(step): Could not parse response (\(consecutiveParseFailures)/\(maxConsecutiveFailures)). Response: \(response.prefix(200))")
                    
                    // Exit early if AI keeps returning unparseable responses
                    if consecutiveParseFailures >= maxConsecutiveFailures {
                        suggestionLogger.info("Research phase ending early: too many parse failures")
                        findings.discoveries.append("Research ended: model response format issues")
                        break
                    }
                    continue
                }
                
                // Reset failure counter on successful parse
                consecutiveParseFailures = 0
                
                // Check if done
                if parsed.done {
                    suggestionLogger.info("Research phase complete at step \(step): \(parsed.summary ?? "no summary")")
                    if let summary = parsed.summary, !summary.isEmpty {
                        findings.discoveries.append(summary)
                    }
                    findings.completed = true
                    break
                }
                
                // Execute the tool
                guard let toolName = parsed.tool, researchToolNames.contains(toolName) else {
                    suggestionLogger.warning("Research step \(step): Invalid tool '\(parsed.tool ?? "nil")'")
                    contextAccumulator.append("Invalid tool requested. Available: \(researchToolNames.joined(separator: ", "))")
                    continue
                }
                
                guard let tool = AgentToolRegistry.shared.get(toolName) else {
                    suggestionLogger.error("Research step \(step): Tool '\(toolName)' not in registry")
                    continue
                }
                
                let args = parsed.args ?? [:]
                setPhase(.researching(detail: "\(toolName): \(args["path"] ?? args["pattern"] ?? "...")", step: step))
                
                suggestionLogger.debug("Research step \(step): \(toolName) with args \(args)")
                
                let result = await tool.execute(args: args, cwd: terminalContext.cwd)
                
                // Track tool call for usage metrics
                let providerName: String
                switch provider {
                case .cloud(let cloudProvider):
                    providerName = cloudProvider == .openai ? "OpenAI" : "Anthropic"
                case .local(let localProvider):
                    providerName = localProvider.rawValue
                }
                TokenUsageTracker.shared.recordToolCall(
                    provider: providerName,
                    model: modelId,
                    command: "research:\(toolName)"
                )
                
                if result.success {
                    // Truncate long outputs
                    let truncatedOutput = String(result.output.prefix(1000))
                    contextAccumulator.append("[\(toolName)] \(args): \(truncatedOutput)")
                    
                    // Track findings
                    if toolName == "read_file", let path = args["path"] {
                        // Extract a brief insight from the file
                        let insight = extractFileInsight(from: result.output, path: path)
                        findings.fileInsights.append((path, insight))
                    } else if toolName == "list_dir", let path = args["path"] {
                        findings.exploredDirectories.append(path)
                    }
                    
                    if let reason = parsed.reason {
                        findings.discoveries.append("• \(reason)")
                    }
                } else {
                    contextAccumulator.append("[\(toolName)] Error: \(result.error ?? "Unknown error")")
                }
                
                findings.stepsTaken = step
                
            } catch {
                suggestionLogger.error("Research step \(step) failed: \(error.localizedDescription)")
                break
            }
        }
        
        if findings.stepsTaken >= self.maxResearchSteps {
            suggestionLogger.info("Research phase hit step limit (\(self.maxResearchSteps))")
        }
        
        return findings
    }
    
    /// Parse the JSON response from the research phase LLM call
    /// Robust parsing that handles various AI response formats
    private func parseResearchResponse(_ response: String) -> (done: Bool, tool: String?, args: [String: String]?, reason: String?, summary: String?)? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strategy 1: Try to extract JSON from the response
        if let result = parseResearchJSON(from: trimmed) {
            return result
        }
        
        // Strategy 2: Check for natural language "done" indicators
        let lowerResponse = trimmed.lowercased()
        let doneIndicators = [
            "i have enough context",
            "have enough information",
            "sufficient context",
            "sufficient information", 
            "ready to suggest",
            "no more research needed",
            "research complete",
            "done researching",
            "gathered enough"
        ]
        
        for indicator in doneIndicators {
            if lowerResponse.contains(indicator) {
                suggestionLogger.debug("Research response matched done indicator: '\(indicator)'")
                return (done: true, tool: nil, args: nil, reason: nil, summary: trimmed.prefix(200).description)
            }
        }
        
        // Strategy 3: Try to extract tool call from natural language
        // e.g., "I'll read the package.json file" or "Let me list the directory"
        if let toolResult = parseNaturalLanguageToolCall(from: trimmed) {
            return toolResult
        }
        
        return nil
    }
    
    /// Try to parse JSON from response text
    private func parseResearchJSON(from response: String) -> (done: Bool, tool: String?, args: [String: String]?, reason: String?, summary: String?)? {
        var jsonString = response
        
        // Remove markdown code block if present (handle ```json, ```JSON, etc.)
        if jsonString.contains("```") {
            let lines = jsonString.components(separatedBy: "\n")
            var jsonLines: [String] = []
            var inBlock = false
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.hasPrefix("```") {
                    inBlock.toggle()
                    continue
                }
                if inBlock {
                    jsonLines.append(line)
                }
            }
            if !jsonLines.isEmpty {
                jsonString = jsonLines.joined(separator: "\n")
            }
        }
        
        // Find JSON object - handle multiple objects by taking the first complete one
        guard let start = jsonString.firstIndex(of: "{") else { return nil }
        
        // Find matching closing brace (handle nested objects)
        var braceCount = 0
        var endIndex: String.Index? = nil
        for idx in jsonString.indices[start...] {
            let char = jsonString[idx]
            if char == "{" { braceCount += 1 }
            else if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    endIndex = idx
                    break
                }
            }
        }
        
        guard let end = endIndex else { return nil }
        jsonString = String(jsonString[start...end])
        
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        // Try flexible decoding with AnyCodable-style approach
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Check for "done" - handle bool, string, or presence of summary without tool
        let isDone = parseBoolValue(json["done"]) ?? 
                     parseBoolValue(json["finished"]) ?? 
                     parseBoolValue(json["complete"]) ??
                     (json["summary"] != nil && json["tool"] == nil)
        
        // Get tool name - handle various field names
        let tool = parseStringValue(json["tool"]) ?? 
                   parseStringValue(json["action"]) ??
                   parseStringValue(json["command"])
        
        // Get args - handle nested objects and convert to [String: String]
        var args: [String: String]? = nil
        if let argsDict = json["args"] as? [String: Any] {
            args = [:]
            for (key, value) in argsDict {
                args?[key] = stringifyValue(value)
            }
        } else if let argsDict = json["arguments"] as? [String: Any] {
            args = [:]
            for (key, value) in argsDict {
                args?[key] = stringifyValue(value)
            }
        } else if let argsDict = json["parameters"] as? [String: Any] {
            args = [:]
            for (key, value) in argsDict {
                args?[key] = stringifyValue(value)
            }
        }
        // Handle flat path argument
        if args == nil, let path = parseStringValue(json["path"]) {
            args = ["path": path]
        }
        
        // Get reason/summary
        let reason = parseStringValue(json["reason"]) ?? parseStringValue(json["why"])
        let summary = parseStringValue(json["summary"]) ?? 
                      parseStringValue(json["conclusion"]) ??
                      parseStringValue(json["findings"])
        
        // If we found something useful, return it
        if isDone || tool != nil {
            return (done: isDone, tool: tool, args: args, reason: reason, summary: summary)
        }
        
        return nil
    }
    
    /// Parse natural language tool calls
    private func parseNaturalLanguageToolCall(from text: String) -> (done: Bool, tool: String?, args: [String: String]?, reason: String?, summary: String?)? {
        // Pattern: "read <file>" or "let me read <file>" or "I'll check <file>"
        let readPatterns = [
            "read the ([\\w./\\-_]+)",
            "check the ([\\w./\\-_]+)",
            "look at ([\\w./\\-_]+)",
            "examine ([\\w./\\-_]+)",
            "open ([\\w./\\-_]+)"
        ]
        
        for pattern in readPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let pathRange = Range(match.range(at: 1), in: text) {
                let path = String(text[pathRange])
                // Only match if it looks like a file path
                if path.contains(".") || path.contains("/") {
                    return (done: false, tool: "read_file", args: ["path": path], reason: "Reading file", summary: nil)
                }
            }
        }
        
        // Pattern: "list <directory>" or "explore <directory>"
        let listPatterns = [
            "list (?:the )?(?:contents of )?([\\w./\\-_]+)",
            "explore ([\\w./\\-_]+)",
            "see what's in ([\\w./\\-_]+)"
        ]
        
        for pattern in listPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let pathRange = Range(match.range(at: 1), in: text) {
                let path = String(text[pathRange])
                return (done: false, tool: "list_dir", args: ["path": path], reason: "Exploring directory", summary: nil)
            }
        }
        
        return nil
    }
    
    /// Parse a value as boolean
    private func parseBoolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let str = value as? String {
            let lower = str.lowercased()
            if ["true", "yes", "done", "1"].contains(lower) { return true }
            if ["false", "no", "0"].contains(lower) { return false }
        }
        if let num = value as? Int { return num != 0 }
        return nil
    }
    
    /// Parse a value as string
    private func parseStringValue(_ value: Any?) -> String? {
        if let str = value as? String, !str.isEmpty { return str }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        return nil
    }
    
    /// Convert any value to string
    private func stringifyValue(_ value: Any) -> String {
        if let str = value as? String { return str }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return String(bool) }
        return String(describing: value)
    }
    
    /// Extract a brief insight from file contents
    private func extractFileInsight(from content: String, path: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let lineCount = lines.count
        
        // For package.json, extract name and scripts
        if path.hasSuffix("package.json") {
            if content.contains("\"scripts\"") {
                return "Node.js project with \(lineCount) lines, has scripts defined"
            }
            return "Node.js package.json with \(lineCount) lines"
        }
        
        // For Cargo.toml
        if path.hasSuffix("Cargo.toml") {
            return "Rust project manifest with \(lineCount) lines"
        }
        
        // For go.mod
        if path.hasSuffix("go.mod") {
            return "Go module with \(lineCount) lines"
        }
        
        // For Makefile
        if path.hasSuffix("Makefile") || path.hasSuffix("makefile") {
            let targets = lines.filter { $0.contains(":") && !$0.hasPrefix("\t") && !$0.hasPrefix("#") }.count
            return "Makefile with ~\(targets) targets"
        }
        
        // Generic insight
        if lineCount > 100 {
            return "Large file (\(lineCount) lines)"
        } else if lineCount > 0 {
            return "File with \(lineCount) lines"
        }
        return "Empty or binary file"
    }
    
    /// Planning phase: Analyze context and decide what suggestions to generate
    /// Uses heuristics first to skip AI call when possible (saves latency and tokens)
    private func planSuggestions(
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        researchFindings: ResearchFindings,
        provider: ProviderType,
        modelId: String
    ) async -> SuggestionPlan {
        var plan = SuggestionPlan()
        
        // ═══════════════════════════════════════════════════════════════════
        // HEURISTIC-BASED PLANNING (Skip AI call when we can determine intent)
        // ═══════════════════════════════════════════════════════════════════
        
        // CASE 1: Error recovery - highest priority, skip AI call
        if terminalContext.lastExitCode != 0 {
            plan.suggestionType = "error_fix"
            plan.userIntent = "Fixing a command error"
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            suggestionLogger.info("Planning (heuristic): Error detected (exit \(terminalContext.lastExitCode)), focusing on error_fix")
            return plan
        }
        
        // CASE 2: Git dirty state - clear action needed, skip AI call
        if let git = terminalContext.gitInfo, git.isDirty {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Managing uncommitted changes"
            plan.focusArea = "git"
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            suggestionLogger.info("Planning (heuristic): Git dirty, focusing on git_workflow")
            return plan
        }
        
        // CASE 3: Git ahead of remote - push suggested, skip AI call
        if let git = terminalContext.gitInfo, git.ahead > 0 {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Pushing committed changes"
            plan.focusArea = "git push"
            plan.shouldSuggest = true
            plan.suggestionCount = 1
            suggestionLogger.info("Planning (heuristic): Git ahead by \(git.ahead), suggesting push")
            return plan
        }
        
        // CASE 4: Git behind remote - pull suggested, skip AI call  
        if let git = terminalContext.gitInfo, git.behind > 0 {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Syncing with remote"
            plan.focusArea = "git pull"
            plan.shouldSuggest = true
            plan.suggestionCount = 1
            suggestionLogger.info("Planning (heuristic): Git behind by \(git.behind), suggesting pull")
            return plan
        }
        
        // CASE 5: Known project type with no recent activity - suggest build/run
        if envContext.projectType != .unknown && gathered.recentCommands.isEmpty {
            plan.suggestionType = "workflow"
            plan.userIntent = "Starting work on \(envContext.projectType.rawValue) project"
            plan.focusArea = envContext.projectType.rawValue
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            suggestionLogger.info("Planning (heuristic): Fresh \(envContext.projectType.rawValue) project, suggesting common commands")
            return plan
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // AI-BASED PLANNING (Only for ambiguous contexts)
        // ═══════════════════════════════════════════════════════════════════
        
        suggestionLogger.info("Planning: Using AI for nuanced context analysis")
        
        // Build prompt with optional research findings
        var contextSection = """
        CONTEXT:
        \(gathered.formattedForPrompt)
        
        ENVIRONMENT:
        \(envContext.formattedForPrompt)
        """
        
        // Add research findings if available
        let researchFormatted = researchFindings.formattedForPrompt
        if !researchFormatted.isEmpty {
            contextSection += "\n\n\(researchFormatted)"
        }
        
        let planPrompt = """
        Analyze this terminal context and plan what suggestions would be most helpful.
        
        \(contextSection)
        
        Based on this, determine:
        1. What is the user likely trying to do?
        2. Should we suggest commands? (false if user seems to know what they're doing)
        3. What type of suggestions: "error_fix", "next_step", "workflow", "general"
        4. Any specific focus area?
        
        Reply as JSON:
        {"user_intent": "brief description", "should_suggest": true/false, "suggestion_type": "type", "focus_area": "optional focus", "suggestion_count": 1-3}
        """
        
        do {
            let response = try await LLMClient.shared.complete(
                systemPrompt: "You are a terminal assistant analyzing user context to plan helpful suggestions.",
                userPrompt: planPrompt,
                provider: provider,
                modelId: modelId,
                reasoningEffort: .none,
                maxTokens: 300,
                timeout: 20,
                requestType: .terminalSuggestion
            )
            
            // Parse the response
            if let parsed = parsePlanResponse(response) {
                plan.userIntent = parsed.userIntent ?? plan.userIntent
                plan.shouldSuggest = parsed.shouldSuggest ?? plan.shouldSuggest
                plan.suggestionType = parsed.suggestionType ?? plan.suggestionType
                plan.focusArea = parsed.focusArea ?? plan.focusArea
                plan.suggestionCount = parsed.suggestionCount ?? plan.suggestionCount
            }
            
            suggestionLogger.info("Planning (AI): intent='\(plan.userIntent)', type=\(plan.suggestionType), suggest=\(plan.shouldSuggest)")
        } catch {
            suggestionLogger.error("Planning AI call failed: \(error.localizedDescription)")
            // Fall back to heuristics - still suggest general commands
            plan.shouldSuggest = true
            plan.suggestionType = "general"
        }
        
        return plan
    }
    
    /// Parse the planning response JSON
    private func parsePlanResponse(_ response: String) -> (userIntent: String?, shouldSuggest: Bool?, suggestionType: String?, focusArea: String?, suggestionCount: Int?)? {
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            var jsonLines: [String] = []
            var inBlock = false
            for line in lines {
                if line.hasPrefix("```") { inBlock.toggle(); continue }
                if inBlock { jsonLines.append(line) }
            }
            jsonString = jsonLines.joined(separator: "\n")
        }
        
        // Find JSON object
        if let start = jsonString.firstIndex(of: "{"),
           let end = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[start...end])
        }
        
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        struct PlanJSON: Decodable {
            let user_intent: String?
            let should_suggest: Bool?
            let suggestion_type: String?
            let focus_area: String?
            let suggestion_count: Int?
        }
        
        guard let parsed = try? JSONDecoder().decode(PlanJSON.self, from: data) else { return nil }
        
        return (parsed.user_intent, parsed.should_suggest, parsed.suggestion_type, parsed.focus_area, parsed.suggestion_count)
    }
    
    /// Generate suggestions based on the plan
    private func generateSuggestionsFromPlan(
        plan: SuggestionPlan,
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        researchFindings: ResearchFindings,
        provider: ProviderType,
        modelId: String
    ) async -> [CommandSuggestion] {
        // Build the generation prompt based on plan type
        var prompt = """
        Generate \(plan.suggestionCount) helpful terminal command suggestions.
        
        USER CONTEXT:
        - Intent: \(plan.userIntent)
        - Current directory: \(terminalContext.cwd)
        """
        
        // Add command history patterns (shows what user actually uses)
        if !gathered.frequentCommandsFormatted.isEmpty {
            prompt += "\n- Frequently used: \(gathered.frequentCommandsFormatted)"
        }
        if !gathered.recentCommands.isEmpty {
            prompt += "\n- Recent: \(gathered.recentCommands.prefix(5).joined(separator: ", "))"
        }
        
        // Add research findings if available (AI-discovered context about the project)
        let researchFormatted = researchFindings.formattedForPrompt
        if !researchFormatted.isEmpty {
            prompt += "\n\n\(researchFormatted)"
        }
        
        // Add type-specific context
        switch plan.suggestionType {
        case "error_fix":
            prompt += """
            
            
            🔴 THE LAST COMMAND FAILED (exit code \(terminalContext.lastExitCode))
            Terminal output:
            ```
            \(String(terminalContext.lastOutput.prefix(500)))
            ```
            
            Suggest commands to FIX this error. Be specific about what went wrong.
            """
            
        case "git_workflow":
            if let git = terminalContext.gitInfo {
                prompt += """
                
                
                Git status: branch=\(git.branch), dirty=\(git.isDirty), ahead=\(git.ahead), behind=\(git.behind)
                
                Suggest appropriate git workflow commands.
                """
            }
            
        case "next_step":
            prompt += """
            
            
            Recent commands: \(gathered.recentCommands.prefix(5).joined(separator: ", "))
            
            Suggest the logical next step in their workflow.
            """
            
        default:
            prompt += """
            
            
            Environment: \(envContext.formattedForPrompt)
            Recent: \(gathered.recentCommands.prefix(3).joined(separator: ", "))
            
            Suggest useful commands based on their context.
            """
        }
        
        if let focus = plan.focusArea {
            prompt += "\n\nFocus on: \(focus)"
        }
        
        // Detect if we're in home directory or a non-project directory
        let isHomeDir = terminalContext.cwd == FileManager.default.homeDirectoryForCurrentUser.path
        let hasProjectFiles = envContext.projectType != .unknown || !envContext.projectTechnologies.isEmpty
        
        prompt += """
        
        
        ⚠️ CRITICAL - CURRENT DIRECTORY RULES:
        - Current directory: \(terminalContext.cwd)
        - Is home directory: \(isHomeDir)
        - Has project files: \(hasProjectFiles)
        
        ONLY suggest commands that can ACTUALLY RUN from the current directory!
        - NEVER suggest "cd \(terminalContext.cwd)" or any path that resolves to the current directory - the user is ALREADY THERE!
        - If in home directory with no project files, suggest navigation or general commands
        - Do NOT suggest project commands (npm, cargo, swift build, etc.) unless project files exist HERE
        - Do NOT suggest commands that require being in a different directory
        - If suggesting cd, only suggest cd to a DIFFERENT directory than "\(terminalContext.cwd)"
        
        OTHER RULES:
        - Keep reasons brief (max 6 words)
        - Don't suggest generic commands like 'ls', 'pwd', 'clear'
        
        Reply as JSON array:
        [{"command": "exact command", "reason": "brief reason", "source": "errorAnalysis|gitStatus|projectContext|generalContext"}]
        """
        
        do {
            // Use configurable reasoning effort from settings
            let reasoningEffort = AgentSettings.shared.terminalSuggestionsReasoningEffort
            
            let response = try await LLMClient.shared.complete(
                systemPrompt: "You are a helpful terminal assistant. You MUST only suggest commands that work in the user's CURRENT directory. Never suggest project-specific commands unless the user is actually in a project directory.",
                userPrompt: prompt,
                provider: provider,
                modelId: modelId,
                reasoningEffort: reasoningEffort,
                maxTokens: 500,
                timeout: 30,
                requestType: .terminalSuggestion
            )
            
            let suggestions = parseSuggestions(from: response, context: terminalContext)
            
            // Validate suggestions against CWD
            return validateSuggestionsForCWD(suggestions, cwd: terminalContext.cwd, envContext: envContext)
        } catch {
            suggestionLogger.error("Generate suggestions failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return []
        }
    }
    
    /// Validate that suggestions make sense for the current working directory
    /// Filters out commands that require being in a specific directory
    private func validateSuggestionsForCWD(_ suggestions: [CommandSuggestion], cwd: String, envContext: EnvironmentContext) -> [CommandSuggestion] {
        let fm = FileManager.default
        let isHomeDir = cwd == fm.homeDirectoryForCurrentUser.path
        let hasProjectFiles = envContext.projectType != .unknown
        
        // Normalize CWD for comparison (resolve symlinks, remove trailing slash)
        let normalizedCWD = (cwd as NSString).standardizingPath
        let homeDir = fm.homeDirectoryForCurrentUser.path
        
        // Commands that require being in a project directory
        let projectCommands = [
            "npm", "yarn", "pnpm", "npx",           // Node.js
            "cargo", "rustc",                        // Rust
            "swift build", "swift run", "swift test", // Swift
            "go build", "go run", "go test",         // Go
            "mvn", "gradle", "./gradlew",            // Java
            "dotnet build", "dotnet run",            // .NET
            "bundle", "rake", "rails",               // Ruby
            "pip install -r", "pytest",              // Python (project-specific)
            "make", "./configure"                    // Build systems
        ]
        
        return suggestions.filter { suggestion in
            let cmd = suggestion.command.lowercased()
            
            // Filter out "cd" commands that would cd into the current directory
            if cmd.hasPrefix("cd ") {
                let cdTarget = String(suggestion.command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                
                // Skip empty cd or just "cd" (goes to home)
                if cdTarget.isEmpty || cdTarget == "~" {
                    if normalizedCWD == (homeDir as NSString).standardizingPath {
                        suggestionLogger.info("Filtered out '\(suggestion.command, privacy: .public)' - already in home directory")
                        return false
                    }
                } else {
                    // Expand ~ to home directory properly
                    let expandedTarget: String
                    if cdTarget.hasPrefix("~/") {
                        // ~/path → home + path (without the ~/)
                        expandedTarget = (homeDir as NSString).appendingPathComponent(String(cdTarget.dropFirst(2)))
                    } else if cdTarget.hasPrefix("~") {
                        // ~username style (rare) - just use as is
                        expandedTarget = cdTarget
                    } else if cdTarget.hasPrefix("/") {
                        // Absolute path
                        expandedTarget = cdTarget
                    } else if cdTarget.hasPrefix("./") {
                        // Explicit relative path
                        expandedTarget = (cwd as NSString).appendingPathComponent(String(cdTarget.dropFirst(2)))
                    } else if cdTarget == "." {
                        // Current directory
                        suggestionLogger.debug("Filtered out '\(suggestion.command)' - cd to current directory")
                        return false
                    } else if cdTarget == ".." {
                        // Parent directory - don't filter
                        expandedTarget = (cwd as NSString).deletingLastPathComponent
                    } else {
                        // Relative path - resolve from CWD
                        expandedTarget = (cwd as NSString).appendingPathComponent(cdTarget)
                    }
                    
                    let normalizedTarget = (expandedTarget as NSString).standardizingPath
                    
                    suggestionLogger.debug("CD filter: target='\(cdTarget, privacy: .public)' expanded='\(expandedTarget, privacy: .public)' normalized='\(normalizedTarget, privacy: .public)' cwd='\(normalizedCWD, privacy: .public)'")
                    
                    if normalizedTarget == normalizedCWD {
                        suggestionLogger.info("Filtered out '\(suggestion.command, privacy: .public)' - already in that directory (target: \(normalizedTarget, privacy: .public))")
                        return false
                    }
                }
            }
            
            // If we're in home directory with no project, filter out project commands
            if isHomeDir && !hasProjectFiles {
                for projectCmd in projectCommands {
                    if cmd.hasPrefix(projectCmd.lowercased()) {
                        suggestionLogger.debug("Filtered out '\(suggestion.command)' - project command in home dir")
                        return false
                    }
                }
            }
            
            // Check if command references a file that should exist
            // e.g., "cat README.md" - check if README.md exists
            let parts = suggestion.command.components(separatedBy: " ")
            if parts.count >= 2 {
                let potentialPath = parts.last ?? ""
                // Only check if it looks like a relative path (not a flag or URL)
                if !potentialPath.hasPrefix("-") && !potentialPath.contains("://") && !potentialPath.hasPrefix("$") {
                    let fullPath = (cwd as NSString).appendingPathComponent(potentialPath)
                    // If it looks like a specific file reference, check if it exists
                    if potentialPath.contains(".") || potentialPath.contains("/") {
                        if !fm.fileExists(atPath: fullPath) && !fm.fileExists(atPath: potentialPath) {
                            // File doesn't exist - but allow commands that might create files
                            let creationCommands = ["touch", "mkdir", "echo", "cat >", "vim", "nano", "code"]
                            let isCreationCmd = creationCommands.contains { cmd.hasPrefix($0) }
                            if !isCreationCmd {
                                suggestionLogger.debug("Filtered out '\(suggestion.command)' - references non-existent path")
                                return false
                            }
                        }
                    }
                }
            }
            
            return true
        }
    }
    
    /// Trigger suggestion generation with debouncing
    func triggerSuggestions(
        cwd: String,
        lastOutput: String,
        lastExitCode: Int32,
        gitInfo: GitInfo?,
        recentCommands: [String] = []
    ) {
        suggestionLogger.info(">>> triggerSuggestions called - cwd: \(cwd, privacy: .public), exitCode: \(lastExitCode), outputLen: \(lastOutput.count)")
        suggestionLogger.info("    lastContext?.cwd: \(self.lastContext?.cwd ?? "nil", privacy: .public)")
        
        // Pause suggestions while chat agent is running to avoid confusion from agent-generated activity
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Skipping suggestions - chat agent is currently running")
            cancelActiveWork()
            suggestions = []
            isVisible = false
            return
        }
        
        let settings = AgentSettings.shared
        
        // Check if feature is enabled and configured
        guard settings.terminalSuggestionsEnabled else {
            suggestionLogger.debug("Suggestions disabled in settings")
            suggestions = []
            isVisible = false
            return
        }
        
        updateNeedsModelSetup()
        
        guard settings.isTerminalSuggestionsConfigured else {
            suggestionLogger.debug("Model not configured, showing setup prompt")
            // Show overlay with setup prompt
            isVisible = true
            return
        }
        
        // Compute a hash of the current context to detect duplicate triggers
        let outputHash = "\(cwd)|\(lastOutput.count)|\(lastExitCode)".hashValue
        
        // Check for meaningful context changes - if so, reset userDismissed
        let cwdChanged = lastContext?.cwd != cwd
        let exitCodeChanged = lastContext?.lastExitCode != lastExitCode
        let outputLengthChanged = (lastContext?.lastOutput.count ?? 0) != lastOutput.count
        
        suggestionLogger.info("    cwdChanged=\(cwdChanged), exitCodeChanged=\(exitCodeChanged), outputLengthChanged=\(outputLengthChanged)")
        
        // Track if context changed meaningfully (for debounce timing)
        var meaningfulContextChange = false
        
        if cwdChanged || exitCodeChanged || outputLengthChanged {
            if userDismissed {
                suggestionLogger.info("Meaningful context change detected, resetting userDismissed flag")
            }
            userDismissed = false
            meaningfulContextChange = true
            
            // CRITICAL: Cancel any active API task when context changes meaningfully
            // This prevents stale suggestions from overriding fresh context
            if activeAPITask != nil {
                let changeReason = cwdChanged ? "CWD" : (exitCodeChanged ? "exit code" : "output")
                suggestionLogger.info(">>> Context changed (\(changeReason)), cancelling active API task to use fresh context")
                cancelActiveWork()
            }
            
            if cwdChanged {
                suggestionLogger.info(">>> CWD CHANGE DETECTED: '\(self.lastContext?.cwd ?? "nil", privacy: .public)' → '\(cwd, privacy: .public)'")
            }
        }
        
        // Skip if this is the same context as last time (prevents duplicate triggers from cursor blink etc)
        if outputHash == lastProcessedOutputHash && !cwdChanged && !exitCodeChanged {
            suggestionLogger.debug("Same context as last trigger, skipping")
            return
        }
        lastProcessedOutputHash = outputHash
        
        let context = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: recentCommands
        )
        
        // Check if we're in cooldown period after running a command
        // During cooldown, skip cache and always generate fresh suggestions
        let inCooldown = commandExecutionCooldown.map { Date().timeIntervalSince($0) < cooldownDuration } ?? false
        
        // Check cache first (but skip during cooldown and if user dismissed)
        if !inCooldown && !userDismissed, let cached = getCachedSuggestions(for: context) {
            suggestionLogger.debug("Using cached suggestions: \(cached.count) items")
            suggestions = cached
            isVisible = !cached.isEmpty
            return
        }
        
        if inCooldown {
            suggestionLogger.debug("In cooldown period, skipping cache")
        }
        
        if userDismissed {
            suggestionLogger.debug("User dismissed suggestions, not showing cached")
        }
        
        // Cancel any pending debounce
        debounceTask?.cancel()
        
        // Use shorter debounce when context changed meaningfully (CWD change, error, etc.)
        // This ensures quick response to user activity while still debouncing rapid changes
        let debounceSeconds = meaningfulContextChange ? 0.3 : settings.terminalSuggestionsDebounceSeconds
        suggestionLogger.debug("Starting debounce timer (\(debounceSeconds)s, meaningfulContextChange=\(meaningfulContextChange))")
        
        // Debounce the API call
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
                
                guard !Task.isCancelled else {
                    suggestionLogger.debug("Debounce task was cancelled")
                    return
                }
                
                guard let self = self else { return }
                
                suggestionLogger.debug("Debounce complete, running agentic pipeline")
                
                // Cancel any existing API task before starting new one
                // This handles race conditions where multiple triggers fire
                if let existingTask = self.activeAPITask {
                    suggestionLogger.debug("Cancelling existing API task before starting new one")
                    existingTask.cancel()
                    self.activeAPITask = nil
                }
                
                // CRITICAL: Get fresh context at pipeline start time
                // This ensures we use the latest CWD, which may have changed during debounce
                let freshContext: TerminalContext
                if let getContext = self.getTerminalContext {
                    let ctx = getContext()
                    suggestionLogger.info(">>> Pipeline using fresh context - cwd: '\(ctx.cwd, privacy: .public)', original context cwd: '\(context.cwd, privacy: .public)'")
                    if ctx.cwd != context.cwd {
                        suggestionLogger.info(">>> CWD MISMATCH: Original='\(context.cwd, privacy: .public)' vs Fresh='\(ctx.cwd, privacy: .public)'")
                    }
                    freshContext = TerminalContext(
                        cwd: ctx.cwd,
                        lastOutput: ctx.lastOutput,
                        lastExitCode: ctx.lastExitCode,
                        gitInfo: ctx.gitInfo,
                        recentCommands: []
                    )
                    suggestionLogger.debug("Using fresh context - CWD: \(ctx.cwd)")
                    // Update lastContext with fresh values for accurate future comparisons
                    self.lastContext = freshContext
                } else {
                    // Fall back to captured context if callback not available
                    freshContext = context
                    suggestionLogger.debug("Using captured context - CWD: \(context.cwd)")
                }
                
                self.activeAPITask = Task { [weak self] in
                    guard let self = self else { return }
                    // Use the new agentic pipeline with fresh context
                    await self.runAgenticPipeline(context: freshContext, isStartup: false)
                    self.activeAPITask = nil
                }
            } catch {
                suggestionLogger.debug("Debounce sleep threw: \(error.localizedDescription)")
                // Task was cancelled, ignore
            }
        }
    }
    
    /// Force immediate suggestion generation (no debounce)
    func generateSuggestionsNow(
        cwd: String,
        lastOutput: String,
        lastExitCode: Int32,
        gitInfo: GitInfo?,
        recentCommands: [String] = []
    ) async {
        let context = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: recentCommands
        )
        
        // Use the new agentic pipeline
        await runAgenticPipeline(context: context, isStartup: false)
    }
    
    /// Clear current suggestions and hide overlay
    /// - Parameter userInitiated: If true, marks as user-dismissed to prevent cached suggestions from reappearing
    func clearSuggestions(userInitiated: Bool = false) {
        debounceTask?.cancel()
        suggestions = []
        isVisible = false
        lastError = nil
        if userInitiated {
            userDismissed = true
            suggestionLogger.debug("User dismissed suggestions - will not show cached until meaningful event")
        }
    }
    
    /// Called when a suggested command is executed
    /// This clears suggestions, sets a cooldown, and optionally schedules the agentic pipeline
    /// - Parameters:
    ///   - command: The command that was executed
    ///   - cwd: The current working directory (may be stale for suggested commands)
    ///   - waitForCWDUpdate: If true, don't schedule pipeline - let CWD change event trigger it
    func commandExecuted(command: String? = nil, cwd: String? = nil, waitForCWDUpdate: Bool = false) {
        // Ignore commands from chat agent - don't track or process agent-generated activity
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Command executed ignored - chat agent is currently running")
            return
        }
        
        suggestionLogger.debug("Command executed: \(command ?? "unknown"), clearing and setting cooldown, waitForCWDUpdate=\(waitForCWDUpdate)")
        debounceTask?.cancel()
        postCommandTask?.cancel()
        suggestions = []
        isVisible = false
        lastError = nil
        setPhase(.idle)
        
        // Reset user-dismissed flag since this is a meaningful event
        userDismissed = false
        // Reset output hash so next trigger isn't skipped as duplicate
        lastProcessedOutputHash = 0
        
        // Set cooldown to prevent cache hits immediately after command execution
        commandExecutionCooldown = Date()
        
        // Increment research tracking counter
        commandsSinceLastResearch += 1
        suggestionLogger.debug("Commands since last research: \(self.commandsSinceLastResearch)/\(self.researchCommandThreshold)")
        
        // Invalidate the cache entry for the last context (if any)
        if let ctx = lastContext {
            let key = ctx.cacheKey
            suggestionCache.removeValue(forKey: key)
            suggestionLogger.debug("Invalidated cache for key")
        }
        
        // Track command in session context (we'll update exit code when we get it)
        if let cmd = command, let dir = cwd ?? lastContext?.cwd {
            sessionContext.addCommand(cmd, exitCode: 0, cwd: dir)
            // Store the last command for pipeline context
            gatheredContext.lastCommand = cmd
            suggestionLogger.debug("Added command to session context, total: \(self.sessionContext.commandsThisSession.count)")
        }
        
        // Schedule post-command agentic pipeline after output stabilizes
        // Skip if waitForCWDUpdate is true - the CWD change event will trigger the pipeline
        guard !waitForCWDUpdate else {
            suggestionLogger.info("Waiting for CWD update event to trigger pipeline (not scheduling post-command task)")
            return
        }
        
        // Capture cooldown values before Task to avoid capturing self early
        let totalDelay = cooldownDuration + postCommandDelay
        suggestionLogger.info("Scheduling post-command agentic pipeline in \(totalDelay)s")
        postCommandTask = Task { [weak self] in
            do {
                // Wait for cooldown + extra time for terminal output to arrive
                try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
                
                guard !Task.isCancelled else {
                    suggestionLogger.debug("Post-command task was cancelled")
                    return
                }
                
                guard let self = self else { return }
                
                suggestionLogger.info(">>> Post-command delay complete, running agentic pipeline <<<")
                
                // Get fresh context from terminal
                if let getContext = self.getTerminalContext {
                    let ctx = getContext()
                    
                    // Update last command's exit code in session context
                    if !self.sessionContext.commandsThisSession.isEmpty {
                        let lastIdx = self.sessionContext.commandsThisSession.count - 1
                        var lastCmd = self.sessionContext.commandsThisSession[lastIdx]
                        lastCmd = SessionCommand(command: lastCmd.command, exitCode: ctx.lastExitCode, cwd: lastCmd.cwd)
                        self.sessionContext.commandsThisSession[lastIdx] = lastCmd
                    }
                    
                    // Build terminal context for pipeline
                    let terminalContext = TerminalContext(
                        cwd: ctx.cwd,
                        lastOutput: ctx.lastOutput,
                        lastExitCode: ctx.lastExitCode,
                        gitInfo: ctx.gitInfo,
                        recentCommands: self.sessionContext.recentCommandStrings(limit: 5)
                    )
                    
                    // Run the full agentic pipeline (continuous flow)
                    await self.runAgenticPipeline(context: terminalContext, isStartup: false)
                } else {
                    suggestionLogger.warning("No terminal context callback available for post-command regeneration")
                }
            } catch {
                suggestionLogger.debug("Post-command sleep threw: \(error.localizedDescription)")
            }
        }
    }
    
    /// Toggle visibility of suggestions overlay
    func toggleVisibility() {
        isVisible.toggle()
        
        // If showing and we have no suggestions but have context, trigger generation
        if isVisible && suggestions.isEmpty && lastContext != nil {
            if let ctx = lastContext {
                triggerSuggestions(
                    cwd: ctx.cwd,
                    lastOutput: ctx.lastOutput,
                    lastExitCode: ctx.lastExitCode,
                    gitInfo: ctx.gitInfo,
                    recentCommands: ctx.recentCommands
                )
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func getCachedSuggestions(for context: TerminalContext) -> [CommandSuggestion]? {
        let key = context.cacheKey
        guard let cached = suggestionCache[key] else { return nil }
        
        // Check if cache is still valid
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
            suggestionCache.removeValue(forKey: key)
            return nil
        }
        
        return cached.suggestions
    }
    
    private func cacheSuggestions(_ suggestions: [CommandSuggestion], for context: TerminalContext) {
        let key = context.cacheKey
        suggestionCache[key] = (suggestions, Date())
        
        // Prune old entries by expiration
        let now = Date()
        suggestionCache = suggestionCache.filter { now.timeIntervalSince($0.value.timestamp) < cacheExpiration }
        
        // Enforce max cache size (keep most recent entries)
        if suggestionCache.count > maxCacheSize {
            let sortedEntries = suggestionCache.sorted { $0.value.timestamp > $1.value.timestamp }
            let keysToKeep = Set(sortedEntries.prefix(maxCacheSize).map { $0.key })
            suggestionCache = suggestionCache.filter { keysToKeep.contains($0.key) }
        }
    }
    
    private func parseSuggestions(from response: String, context: TerminalContext) -> [CommandSuggestion] {
        // Extract JSON array from response (handle markdown code blocks)
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            var inCodeBlock = false
            var jsonLines: [String] = []
            
            for line in lines {
                if line.hasPrefix("```") {
                    inCodeBlock.toggle()
                    continue
                }
                if inCodeBlock {
                    jsonLines.append(line)
                }
            }
            jsonString = jsonLines.joined(separator: "\n")
        }
        
        // Find the JSON array in the response
        if let startIdx = jsonString.firstIndex(of: "["),
           let endIdx = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[startIdx...endIdx])
        }
        
        guard let data = jsonString.data(using: .utf8) else { return [] }
        
        struct RawSuggestion: Decodable {
            let command: String
            let reason: String
            let source: String?
        }
        
        guard let raw = try? JSONDecoder().decode([RawSuggestion].self, from: data) else { return [] }
        
        return raw.prefix(3).compactMap { item in
            let source = SuggestionSource(rawValue: item.source ?? "generalContext") ?? .generalContext
            return CommandSuggestion(
                command: item.command,
                reason: String(item.reason.prefix(35)),  // Keep reasons concise
                confidence: 0.8,
                source: source
            )
        }
    }
    
    // MARK: - Project Detection
    
    /// Detect the project type based on files in the directory (cached)
    func detectProjectType(at path: String) -> ProjectType {
        // Check cache first
        if let cached = projectTypeCache[path] {
            if Date().timeIntervalSince(cached.timestamp) < projectTypeCacheExpiration {
                return cached.type
            }
            // Cache expired, remove it
            projectTypeCache.removeValue(forKey: path)
        }
        
        // Perform detection
        let detectedType = performProjectTypeDetection(at: path)
        
        // Cache the result
        projectTypeCache[path] = (type: detectedType, timestamp: Date())
        
        // Prune cache if too large (keep most recent 20 entries)
        if projectTypeCache.count > 20 {
            let sortedKeys = projectTypeCache.sorted { $0.value.timestamp > $1.value.timestamp }
            let keysToRemove = sortedKeys.dropFirst(20).map { $0.key }
            for key in keysToRemove {
                projectTypeCache.removeValue(forKey: key)
            }
        }
        
        return detectedType
    }
    
    /// Perform the actual project type detection (file system checks)
    private func performProjectTypeDetection(at path: String) -> ProjectType {
        let fm = FileManager.default
        
        // Check for various project markers
        let markers: [(file: String, type: ProjectType)] = [
            ("package.json", .node),
            ("Package.swift", .swift),
            ("Cargo.toml", .rust),
            ("pyproject.toml", .python),
            ("setup.py", .python),
            ("requirements.txt", .python),
            ("go.mod", .go),
            ("Gemfile", .ruby),
            ("pom.xml", .java),
            ("build.gradle", .java),
            ("build.gradle.kts", .java)
        ]
        
        for marker in markers {
            let filePath = (path as NSString).appendingPathComponent(marker.file)
            if fm.fileExists(atPath: filePath) {
                return marker.type
            }
        }
        
        // Check for .csproj or .sln files (dotnet)
        if let contents = try? fm.contentsOfDirectory(atPath: path) {
            for file in contents {
                if file.hasSuffix(".csproj") || file.hasSuffix(".sln") {
                    return .dotnet
                }
            }
        }
        
        return .unknown
    }
    
    // MARK: - Startup Suggestions
    
    /// Trigger startup suggestions when terminal opens or user changes directory
    /// Uses the full agentic pipeline for quality suggestions
    func triggerStartupSuggestions(
        cwd: String,
        gitInfo: GitInfo?,
        isNewDirectory: Bool = false
    ) {
        suggestionLogger.info("triggerStartupSuggestions called - cwd: \(cwd), isNew: \(isNewDirectory)")
        
        // Pause suggestions while chat agent is running
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Startup: Skipping - chat agent is currently running")
            setPhase(.idle)
            return
        }
        
        let settings = AgentSettings.shared
        
        // Check if feature is enabled
        guard settings.terminalSuggestionsEnabled else {
            suggestionLogger.debug("Suggestions disabled, returning")
            suggestions = []
            isVisible = false
            setPhase(.idle)
            return
        }
        
        updateNeedsModelSetup()
        suggestionLogger.debug("needsModelSetup: \(self.needsModelSetup)")
        
        // If AI model is configured, run the full agentic pipeline
        if settings.isTerminalSuggestionsConfigured {
            let projectType = detectProjectType(at: cwd)
            suggestionLogger.info("Model configured, starting agentic startup pipeline")
            suggestionLogger.info("Project type detected: \(projectType.rawValue, privacy: .public)")
            suggestionLogger.info("Git info present: \(gitInfo != nil)")
            if let git = gitInfo {
                suggestionLogger.info("Git: branch=\(git.branch, privacy: .public), dirty=\(git.isDirty), ahead=\(git.ahead)")
            }
            
            isVisible = true
            
            // Capture values needed in Task before closure to minimize self captures
            let recentCmds = sessionContext.recentCommandStrings(limit: 5)
            
            Task { [weak self] in
                guard let self = self else { return }
                
                // Build the terminal context for the pipeline
                let terminalContext = TerminalContext(
                    cwd: cwd,
                    lastOutput: "",  // No output on startup
                    lastExitCode: 0,  // Clean start
                    gitInfo: gitInfo,
                    recentCommands: recentCmds
                )
                
                // Run the full agentic pipeline (startup flow)
                await self.runAgenticPipeline(context: terminalContext, isStartup: true)
                
                suggestionLogger.info("Startup pipeline complete: \(self.suggestions.count) suggestions")
                // If pipeline returned nothing, hide the bar
                if self.suggestions.isEmpty {
                    suggestionLogger.info("No suggestions returned, hiding bar")
                    self.isVisible = false
                } else {
                    suggestionLogger.info("Suggestions: \(self.suggestions.map { $0.command }.joined(separator: ", "), privacy: .public)")
                }
            }
        } else {
            // No AI configured - just show setup prompt, no generic suggestions
            suggestionLogger.info("No AI configured, showing setup prompt only")
            suggestions = []
            isVisible = true // Shows the "Configure AI" prompt
            setPhase(.idle)
        }
        
        // Mark directory as visited
        CommandHistoryStore.shared.markVisited(cwd)
    }
    
    // MARK: - Environment Context Gathering
    
    /// Gather environment information for context
    private func gatherEnvironmentInfo() -> [String] {
        var info: [String] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        
        // 1. Parse shell config files for aliases, functions, and customizations
        let shellConfigInfo = parseShellConfigs(homeDir: home)
        if !shellConfigInfo.isEmpty {
            info.append(contentsOf: shellConfigInfo)
        }
        
        // 2. Check for common dev tool config files
        let devConfigs: [(file: String, description: String)] = [
            (".npmrc", "Node.js/npm"),
            (".yarnrc", "Yarn"),
            (".pnpmrc", "pnpm"),
            (".cargo/config.toml", "Rust/Cargo"),
            (".docker", "Docker"),
            (".kube/config", "Kubernetes"),
            (".aws/credentials", "AWS CLI"),
            (".gcloud", "Google Cloud"),
            (".azure", "Azure CLI"),
            (".ssh", "SSH"),
            (".gitconfig", "Git"),
            (".pyenv", "pyenv"),
            (".nvm", "nvm"),
            (".rbenv", "rbenv"),
            (".goenv", "goenv"),
            (".terraform.d", "Terraform"),
            (".volta", "Volta (Node)"),
            (".rustup", "Rustup"),
            (".sdkman", "SDKMAN (Java)"),
            ("go", "Go workspace"),
            (".config/gh", "GitHub CLI"),
            (".config/glab-cli", "GitLab CLI")
        ]
        
        // Detect installed tools - included for reference but command history
        // is a better signal of what the user actually uses regularly
        var foundTools: [String] = []
        for config in devConfigs {
            let path = (home as NSString).appendingPathComponent(config.file)
            if fm.fileExists(atPath: path) {
                foundTools.append(config.description)
            }
        }
        
        if !foundTools.isEmpty {
            info.append("Installed tools (ref): \(foundTools.joined(separator: ", "))")
        }
        
        // 3. Check current directory for project indicators
        if let ctx = lastContext {
            var projectIndicators: [String] = []
            let projectFiles: [(file: String, meaning: String)] = [
                ("package.json", "Node.js"),
                ("Cargo.toml", "Rust"),
                ("go.mod", "Go"),
                ("requirements.txt", "Python"),
                ("pyproject.toml", "Python (modern)"),
                ("Gemfile", "Ruby"),
                ("pom.xml", "Java/Maven"),
                ("build.gradle", "Java/Gradle"),
                ("Package.swift", "Swift"),
                ("docker-compose.yml", "Docker Compose"),
                ("docker-compose.yaml", "Docker Compose"),
                ("Dockerfile", "Docker"),
                ("Makefile", "Make"),
                (".terraform", "Terraform"),
                ("terraform.tf", "Terraform"),
                ("k8s/", "Kubernetes"),
                ("kubernetes/", "Kubernetes"),
                ("helm/", "Helm"),
                ("Chart.yaml", "Helm chart"),
                (".github/workflows", "GitHub Actions"),
                (".gitlab-ci.yml", "GitLab CI"),
                ("Jenkinsfile", "Jenkins"),
                ("serverless.yml", "Serverless Framework"),
                ("sam.yaml", "AWS SAM"),
                ("cdk.json", "AWS CDK")
            ]
            
            for pf in projectFiles {
                let path = (ctx.cwd as NSString).appendingPathComponent(pf.file)
                if fm.fileExists(atPath: path) {
                    projectIndicators.append(pf.meaning)
                }
            }
            
            if !projectIndicators.isEmpty {
                info.append("Current project technologies: \(projectIndicators.joined(separator: ", "))")
            }
        }
        
        return info
    }
    
    /// Parse shell configuration files to extract aliases, functions, and customizations
    private func parseShellConfigs(homeDir: String) -> [String] {
        var configInfo: [String] = []
        let fm = FileManager.default
        
        // Shell config files to check (in order of priority)
        let shellConfigs = [
            ".zshrc",
            ".bashrc", 
            ".bash_profile",
            ".profile",
            ".zprofile",
            ".config/fish/config.fish",
            ".aliases",
            ".zsh_aliases"
        ]
        
        var allAliases: [String] = []
        var directoryAliases: [String] = []  // Special tracking for cd aliases
        var allFunctions: [String] = []
        var allExports: [String] = []
        var allSources: [String] = []
        var shellFramework: String? = nil
        var importantPaths: [String] = []
        
        for configFile in shellConfigs {
            let path = (homeDir as NSString).appendingPathComponent(configFile)
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            
            suggestionLogger.debug("Parsing shell config: \(configFile), length: \(content.count)")
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Skip comments and empty lines
                guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
                
                // Detect shell framework (oh-my-zsh, prezto, etc.)
                if trimmed.contains("oh-my-zsh") || trimmed.contains("ZSH_THEME") {
                    shellFramework = "oh-my-zsh"
                } else if trimmed.contains("prezto") {
                    shellFramework = "prezto"
                } else if trimmed.contains("zinit") || trimmed.contains("zdharma") {
                    shellFramework = "zinit"
                } else if trimmed.contains("antigen") {
                    shellFramework = "antigen"
                } else if trimmed.contains("starship") {
                    shellFramework = "starship prompt"
                } else if trimmed.contains("powerlevel10k") || trimmed.contains("p10k") {
                    shellFramework = "powerlevel10k"
                }
                
                // Extract aliases with special handling for directory shortcuts
                if trimmed.hasPrefix("alias ") {
                    if let aliasInfo = extractAliasWithDetails(from: trimmed) {
                        allAliases.append(aliasInfo.display)
                        // Track directory navigation aliases specially
                        if aliasInfo.command.hasPrefix("cd ") {
                            let dirPath = aliasInfo.command.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            directoryAliases.append("\(aliasInfo.name) → \(dirPath)")
                        }
                    }
                }
                
                // Extract function names
                if trimmed.hasPrefix("function ") || (trimmed.contains("()") && trimmed.contains("{")) {
                    if let funcName = extractFunctionName(from: trimmed) {
                        allFunctions.append(funcName)
                    }
                }
                
                // Extract meaningful exports and paths
                if trimmed.hasPrefix("export ") {
                    if let exportInfo = extractMeaningfulExport(from: trimmed) {
                        allExports.append(exportInfo)
                    }
                    // Look for important paths in exports
                    if let pathInfo = extractPathFromExport(trimmed) {
                        importantPaths.append(pathInfo)
                    }
                }
                
                // Detect sourced files/plugins
                if trimmed.hasPrefix("source ") || trimmed.hasPrefix(". ") {
                    if let sourceInfo = extractSourceInfo(from: trimmed) {
                        allSources.append(sourceInfo)
                    }
                }
                
                // Look for common directory patterns in any line
                // e.g., PROJECTS_DIR=~/projects or similar
                if trimmed.contains("=") && (trimmed.contains("~/") || trimmed.contains("$HOME")) {
                    if let dirVar = extractDirectoryVariable(from: trimmed) {
                        importantPaths.append(dirVar)
                    }
                }
            }
        }
        
        suggestionLogger.info("Shell config parsing: \(allAliases.count) aliases, \(directoryAliases.count) dir shortcuts, \(allFunctions.count) functions")
        
        // Build summary - prioritize directory shortcuts for navigation suggestions
        if let framework = shellFramework {
            configInfo.append("Shell framework: \(framework)")
        }
        
        // Directory shortcuts are VERY important for personalized navigation
        if !directoryAliases.isEmpty {
            configInfo.append("📁 Directory shortcuts: \(directoryAliases.joined(separator: ", "))")
        }
        
        if !importantPaths.isEmpty {
            configInfo.append("📂 Important paths: \(importantPaths.prefix(10).joined(separator: ", "))")
        }
        
        if !allAliases.isEmpty {
            // Show most interesting aliases (prioritize non-trivial ones)
            let interestingAliases = allAliases.filter { alias in
                // Skip single-letter aliases and very common ones
                !["l", "ll", "la", "g", "v"].contains(where: { alias.hasPrefix("\($0)=") })
            }
            let displayAliases = interestingAliases.prefix(20)
            configInfo.append("Custom aliases (\(allAliases.count) total): \(displayAliases.joined(separator: ", "))")
        }
        
        if !allFunctions.isEmpty {
            let displayFuncs = allFunctions.prefix(10)
            configInfo.append("Shell functions: \(displayFuncs.joined(separator: ", "))")
        }
        
        if !allExports.isEmpty {
            configInfo.append("Environment: \(allExports.joined(separator: ", "))")
        }
        
        if !allSources.isEmpty {
            configInfo.append("Plugins: \(allSources.joined(separator: ", "))")
        }
        
        return configInfo
    }
    
    /// Extract alias with full details including the command
    private func extractAliasWithDetails(from line: String) -> (name: String, command: String, display: String)? {
        let withoutPrefix = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        
        guard let equalsIndex = withoutPrefix.firstIndex(of: "=") else { return nil }
        
        let name = String(withoutPrefix[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        var command = String(withoutPrefix[withoutPrefix.index(after: equalsIndex)...])
        
        // Remove surrounding quotes
        if (command.hasPrefix("'") && command.hasSuffix("'")) ||
           (command.hasPrefix("\"") && command.hasSuffix("\"")) {
            command = String(command.dropFirst().dropLast())
        }
        
        guard name.count > 1 else { return nil }
        
        let display = command.count < 30 ? "\(name)=\(command)" : name
        return (name, command, display)
    }
    
    /// Extract path information from export statements
    private func extractPathFromExport(_ line: String) -> String? {
        // Look for patterns like PROJECTS=~/projects or WORK_DIR="$HOME/work"
        let withoutExport = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        
        guard let equalsIndex = withoutExport.firstIndex(of: "=") else { return nil }
        
        let varName = String(withoutExport[..<equalsIndex])
        var value = String(withoutExport[withoutExport.index(after: equalsIndex)...])
        
        // Remove quotes
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        // Only interested in path-like values
        guard value.contains("/") || value.contains("$HOME") || value.hasPrefix("~") else { return nil }
        
        // Skip standard paths
        let skipVars = ["PATH", "MANPATH", "FPATH", "INFOPATH"]
        if skipVars.contains(varName) { return nil }
        
        // Look for project/work related paths
        let interestingKeywords = ["PROJECT", "WORK", "CODE", "DEV", "REPO", "GIT", "SRC"]
        if interestingKeywords.contains(where: { varName.uppercased().contains($0) }) {
            return "\(varName)=\(value)"
        }
        
        return nil
    }
    
    /// Extract directory variable definitions
    private func extractDirectoryVariable(from line: String) -> String? {
        guard let equalsIndex = line.firstIndex(of: "=") else { return nil }
        
        let varPart = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        var valuePart = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
        
        // Remove quotes and export prefix
        let varName = varPart.replacingOccurrences(of: "export ", with: "")
                            .replacingOccurrences(of: "local ", with: "")
                            .trimmingCharacters(in: .whitespaces)
        
        valuePart = valuePart.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        // Must be a path
        guard valuePart.hasPrefix("~/") || valuePart.hasPrefix("$HOME") || valuePart.hasPrefix("/") else { return nil }
        
        // Look for meaningful directory names
        let meaningfulPatterns = ["github", "projects", "code", "work", "dev", "repos", "src", "workspace"]
        let lowerValue = valuePart.lowercased()
        
        if meaningfulPatterns.contains(where: { lowerValue.contains($0) }) {
            return "\(varName)=\(valuePart)"
        }
        
        return nil
    }
    
    /// Extract function name from a function definition
    private func extractFunctionName(from line: String) -> String? {
        var cleaned = line
        
        // Handle "function name" or "function name()"
        if cleaned.hasPrefix("function ") {
            cleaned = String(cleaned.dropFirst(9))
            if let spaceOrParen = cleaned.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "{" }) {
                return String(cleaned[..<spaceOrParen]).trimmingCharacters(in: .whitespaces)
            }
            return cleaned.trimmingCharacters(in: .whitespaces)
        }
        
        // Handle "name() {" style
        if let parenIndex = cleaned.firstIndex(of: "(") {
            let name = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespaces)
            // Skip underscore-prefixed private functions
            if !name.hasPrefix("_") && !name.isEmpty {
                return name
            }
        }
        
        return nil
    }
    
    /// Extract meaningful export information
    private func extractMeaningfulExport(from line: String) -> String? {
        let withoutPrefix = line.dropFirst(7).trimmingCharacters(in: .whitespaces) // Remove "export "
        
        guard let equalsIndex = withoutPrefix.firstIndex(of: "=") else { return nil }
        
        let varName = String(withoutPrefix[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        
        // Skip common/boring exports
        let skipVars = ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "LC_ALL", 
                        "EDITOR", "VISUAL", "PAGER", "LESS", "MANPATH", "HISTSIZE",
                        "HISTFILESIZE", "SAVEHIST", "HISTFILE"]
        if skipVars.contains(varName) { return nil }
        
        // Return interesting exports that reveal tool usage
        let interestingPrefixes = ["DOCKER", "KUBE", "AWS", "AZURE", "GCP", "GOOGLE", 
                                   "JAVA", "PYTHON", "NODE", "NPM", "YARN", "GO", "RUST",
                                   "CARGO", "REDIS", "POSTGRES", "MYSQL", "MONGO", "KAFKA"]
        
        for prefix in interestingPrefixes {
            if varName.hasPrefix(prefix) {
                return varName
            }
        }
        
        // Return custom-looking exports (not all caps standard vars)
        if varName.contains("_") && !varName.allSatisfy({ $0.isUppercase || $0 == "_" }) {
            return varName
        }
        
        return nil
    }
    
    /// Extract source file/plugin info
    private func extractSourceInfo(from line: String) -> String? {
        var cleaned = line
        if cleaned.hasPrefix("source ") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix(". ") {
            cleaned = String(cleaned.dropFirst(2))
        }
        
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        
        // Remove quotes
        if (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) ||
           (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        
        // Extract just the filename/plugin name
        let filename = (cleaned as NSString).lastPathComponent
        
        // Skip if it looks like a variable expansion we can't resolve
        if filename.contains("$") { return nil }
        
        // Return recognizable plugin/tool names
        let interestingPatterns = ["nvm", "rvm", "pyenv", "rbenv", "sdkman", "cargo", "rust",
                                   "kubectl", "helm", "aws", "gcloud", "azure", "fzf", "zoxide",
                                   "autojump", "thefuck", "zsh-syntax", "zsh-autosuggestions",
                                   "zsh-completions", "git", "docker", "k8s", "kube"]
        
        let lowerFilename = filename.lowercased()
        for pattern in interestingPatterns {
            if lowerFilename.contains(pattern) {
                return filename
            }
        }
        
        return nil
    }
    
    /// Get frequently visited directories from command history
    private func gatherFrequentDirectories() -> [String] {
        // This would ideally come from shell history with directory tracking
        // For now, return empty - could be enhanced with zsh HIST_STAMPS or similar
        return []
    }
    
    }


