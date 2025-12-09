import Foundation

/// Classifies commands to determine if they're relevant in the current directory context
struct CommandClassifier {
    
    /// Commands that work in any directory
    private static let universalCommands: Set<String> = [
        "ls", "ll", "la", "pwd", "clear", "whoami", "date", "cal", "uptime",
        "which", "where", "type", "alias", "history", "env", "printenv",
        "echo", "cat", "less", "more", "head", "tail", "wc",
        "grep", "find", "locate", "tree", "du", "df",
        "ps", "top", "htop", "kill", "killall",
        "ssh", "scp", "rsync", "curl", "wget", "ping",
        "man", "help", "tldr", "brew", "apt", "yum", "pacman",
        "code", "vim", "nvim", "nano", "emacs", "subl",
        "open", "pbcopy", "pbpaste", "say"
    ]
    
    /// Commands that require specific project markers
    private static let projectCommands: [String: (ProjectType, marker: String)] = [
        // Node.js
        "npm": (.node, "package.json"),
        "npx": (.node, "package.json"),
        "yarn": (.node, "package.json"),
        "pnpm": (.node, "package.json"),
        "node": (.node, "package.json"),
        "bun": (.node, "package.json"),
        // Swift
        "swift": (.swift, "Package.swift"),
        // Rust
        "cargo": (.rust, "Cargo.toml"),
        "rustc": (.rust, "Cargo.toml"),
        // Python
        "pip": (.python, "requirements.txt"),
        "pip3": (.python, "requirements.txt"),
        "python": (.python, "requirements.txt"),
        "python3": (.python, "requirements.txt"),
        "pytest": (.python, "pytest.ini"),
        "poetry": (.python, "pyproject.toml"),
        "pipenv": (.python, "Pipfile"),
        // Go
        "go": (.go, "go.mod"),
        // Ruby
        "bundle": (.ruby, "Gemfile"),
        "rails": (.ruby, "Gemfile"),
        "rake": (.ruby, "Rakefile"),
        "gem": (.ruby, "Gemfile"),
        // Java
        "mvn": (.java, "pom.xml"),
        "gradle": (.java, "build.gradle"),
        "gradlew": (.java, "build.gradle"),
        // .NET
        "dotnet": (.dotnet, "*.csproj"),
        // Generic build
        "make": (.unknown, "Makefile"),
        "cmake": (.unknown, "CMakeLists.txt"),
    ]
    
    /// Classify a command to determine its context requirements
    static func classify(_ command: String, currentCWD: String) -> CommandContextType {
        let parts = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        
        guard let baseCommand = parts.first else { return .ambiguous }
        
        // Check for universal commands
        if universalCommands.contains(baseCommand.lowercased()) {
            return .universal
        }
        
        // Check for cd command - special handling
        if baseCommand == "cd" {
            // cd with no args or ~ is universal
            if parts.count == 1 { return .universal }
            let target = parts.dropFirst().joined(separator: " ")
            if target == "~" || target == "-" || target.hasPrefix("~") || target.hasPrefix("/") {
                return .universal
            }
            // cd to relative paths might not exist elsewhere
            return .pathDependent
        }
        
        // Check for git - universal if just checking status, project-related for commits/push
        if baseCommand == "git" {
            let gitSubcommand = parts.dropFirst().first ?? ""
            let universalGitCommands = ["status", "log", "branch", "remote", "config", "help", "version"]
            if universalGitCommands.contains(gitSubcommand) {
                return .universal
            }
            // Other git commands are more project-specific
            return .projectSpecific(.unknown)
        }
        
        // Check for project-specific commands
        if let (projectType, _) = projectCommands[baseCommand.lowercased()] {
            return .projectSpecific(projectType)
        }
        
        // Check for path-dependent commands (references relative paths or specific files)
        if command.contains("./") || command.contains("../") {
            return .pathDependent
        }
        
        // Check if command contains what looks like a file/path reference
        let hasPathLikeArg = parts.dropFirst().contains { arg in
            arg.contains("/") || arg.contains(".") && !arg.hasPrefix("-")
        }
        if hasPathLikeArg {
            return .pathDependent
        }
        
        return .ambiguous
    }
    
    /// Check if a project-specific command is relevant in the given directory
    static func isRelevantInDirectory(_ command: String, cwd: String, envContext: EnvironmentContext) -> Bool {
        let classification = classify(command, currentCWD: cwd)
        
        switch classification {
        case .universal:
            return true
            
        case .projectSpecific(let requiredType):
            // Check if the current directory has the right project type
            if requiredType == .unknown {
                // Generic project command - allow if in any project
                return envContext.projectType != .unknown
            }
            return envContext.projectType == requiredType
            
        case .pathDependent:
            // For path-dependent commands, we'd need to check if paths exist
            // For now, be conservative and exclude from suggestions in different directories
            return false
            
        case .ambiguous:
            // When unsure, include it
            return true
        }
    }
    
    /// Filter a list of frequent commands to only those relevant in the current context
    static func filterForCurrentContext(
        commands: [CommandFrequency],
        cwd: String,
        envContext: EnvironmentContext
    ) -> [CommandFrequency] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let isInHomeDir = cwd == homeDir || cwd == "~"
        
        return commands.filter { freq in
            // If in home directory, be more strict about what we suggest
            if isInHomeDir {
                let classification = classify(freq.command, currentCWD: cwd)
                switch classification {
                case .universal:
                    return true
                case .projectSpecific:
                    // Don't suggest project commands when in home directory
                    return false
                case .pathDependent:
                    // Don't suggest path-dependent commands when in home
                    return false
                case .ambiguous:
                    // Be conservative in home - include simple commands only
                    return !freq.command.contains("/") && !freq.command.contains(".")
                }
            }
            
            // In other directories, use the full relevance check
            return isRelevantInDirectory(freq.command, cwd: cwd, envContext: envContext)
        }
    }
}
