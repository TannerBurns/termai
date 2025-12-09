import Foundation

// MARK: - Suggestion Source

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

// MARK: - Project Type

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

// MARK: - Command Suggestion

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

// MARK: - Command Context Type

/// Classification of a command's context requirements
enum CommandContextType {
    case universal           // Works anywhere (ls, pwd, git status, cd ~, etc.)
    case projectSpecific(ProjectType)  // Requires specific project type (npm→node, cargo→rust)
    case pathDependent       // References specific paths/files that may not exist elsewhere
    case ambiguous           // Cannot determine, treat as universal
}

// MARK: - Terminal Context

/// Context passed to the suggestion engine
struct TerminalContext {
    let cwd: String
    let lastOutput: String
    let lastExitCode: Int32
    let gitInfo: GitInfo?
    let recentCommands: [String]
    
    init(cwd: String, lastOutput: String, lastExitCode: Int32, gitInfo: GitInfo?, recentCommands: [String]) {
        self.cwd = cwd
        self.lastOutput = lastOutput
        self.lastExitCode = lastExitCode
        self.gitInfo = gitInfo
        self.recentCommands = recentCommands
    }
    
    /// Create a hash for cache lookup
    var cacheKey: String {
        let gitPart = gitInfo.map { "\($0.branch):\($0.isDirty)" } ?? "nogit"
        let exitPart = lastExitCode != 0 ? "err\(lastExitCode)" : "ok"
        return "\(cwd)|\(gitPart)|\(exitPart)|\(lastOutput.prefix(100).hashValue)"
    }
}

// MARK: - Session Command

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

// MARK: - Gathered Context

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
    
    init() {}
    
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

// MARK: - Suggestion Plan

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
    
    init() {}
}

// MARK: - Research Findings

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
    
    init() {}
    
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

// MARK: - Environment Context

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
    
    init() {}
    
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

// MARK: - Session Context

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
    
    init() {}
    
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
