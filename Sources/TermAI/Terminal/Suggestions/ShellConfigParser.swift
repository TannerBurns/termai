import Foundation
import os.log

private let parserLogger = Logger(subsystem: "com.termai.app", category: "ShellConfigParser")

/// Parses shell configuration files to extract aliases, functions, and customizations
struct ShellConfigParser {
    
    // MARK: - Public API
    
    /// Parse shell configuration files and return structured info
    /// - Parameter homeDir: The user's home directory path
    /// - Returns: Tuple containing framework, aliases, functions, and paths
    static func parseShellConfigs(homeDir: String) -> (
        framework: String?,
        aliases: [(name: String, path: String)],
        functions: [String],
        paths: [String],
        configInfo: [String]
    ) {
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
        var directoryAliases: [(name: String, path: String)] = []
        var allFunctions: [String] = []
        var allExports: [String] = []
        var allSources: [String] = []
        var shellFramework: String? = nil
        var importantPaths: [String] = []
        var configInfo: [String] = []
        
        for configFile in shellConfigs {
            let path = (homeDir as NSString).appendingPathComponent(configFile)
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            
            parserLogger.debug("Parsing shell config: \(configFile), length: \(content.count)")
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Skip comments and empty lines
                guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
                
                // Detect shell framework
                if shellFramework == nil {
                    if let detected = detectShellFramework(from: trimmed) {
                        shellFramework = detected
                    }
                }
                
                // Extract aliases with special handling for directory shortcuts
                if trimmed.hasPrefix("alias ") {
                    if let aliasInfo = extractAliasWithDetails(from: trimmed) {
                        allAliases.append(aliasInfo.display)
                        // Track directory navigation aliases specially
                        if aliasInfo.command.hasPrefix("cd ") {
                            let dirPath = aliasInfo.command.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            directoryAliases.append((aliasInfo.name, dirPath))
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
        
        parserLogger.info("Shell config parsing: \(allAliases.count) aliases, \(directoryAliases.count) dir shortcuts, \(allFunctions.count) functions")
        
        // Build summary - prioritize directory shortcuts for navigation suggestions
        if let framework = shellFramework {
            configInfo.append("Shell framework: \(framework)")
        }
        
        // Directory shortcuts are VERY important for personalized navigation
        if !directoryAliases.isEmpty {
            configInfo.append("📁 Directory shortcuts: \(directoryAliases.map { "\($0.0) → \($0.1)" }.joined(separator: ", "))")
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
        
        return (shellFramework, directoryAliases, allFunctions, importantPaths, configInfo)
    }
    
    // MARK: - Framework Detection
    
    private static func detectShellFramework(from line: String) -> String? {
        if line.contains("oh-my-zsh") || line.contains("ZSH_THEME") {
            return "oh-my-zsh"
        } else if line.contains("prezto") {
            return "prezto"
        } else if line.contains("zinit") || line.contains("zdharma") {
            return "zinit"
        } else if line.contains("antigen") {
            return "antigen"
        } else if line.contains("starship") {
            return "starship prompt"
        } else if line.contains("powerlevel10k") || line.contains("p10k") {
            return "powerlevel10k"
        }
        return nil
    }
    
    // MARK: - Alias Extraction
    
    /// Extract alias with full details including the command
    static func extractAliasWithDetails(from line: String) -> (name: String, command: String, display: String)? {
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
    
    // MARK: - Function Extraction
    
    /// Extract function name from a function definition
    static func extractFunctionName(from line: String) -> String? {
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
    
    // MARK: - Export Extraction
    
    /// Extract meaningful export information
    static func extractMeaningfulExport(from line: String) -> String? {
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
    
    /// Extract path information from export statements
    static func extractPathFromExport(_ line: String) -> String? {
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
    
    // MARK: - Directory Variable Extraction
    
    /// Extract directory variable definitions
    static func extractDirectoryVariable(from line: String) -> String? {
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
    
    // MARK: - Source Extraction
    
    /// Extract source file/plugin info
    static func extractSourceInfo(from line: String) -> String? {
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
        if filename.contains("$") || filename.contains("<") { return nil }
        
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
}
