import Foundation
import os.log

private let envLogger = Logger(subsystem: "com.termai.app", category: "EnvironmentContext")

/// Provides environment context for the suggestion pipeline
/// Handles detection of project types, installed tools, and shell configuration with caching
class EnvironmentContextProvider {
    
    // MARK: - Singleton
    
    static let shared = EnvironmentContextProvider()
    
    // MARK: - Cache Configuration
    
    private let projectTypeCacheExpiration: TimeInterval = 60 // 1 minute
    private let installedToolsCacheExpiration: TimeInterval = 600 // 10 minutes
    private let shellConfigCacheExpiration: TimeInterval = 600 // 10 minutes
    
    // MARK: - Cache Storage
    
    private var projectTypeCache: [String: (type: ProjectType, timestamp: Date)] = [:]
    private var installedToolsCache: (tools: [String], timestamp: Date)?
    private var shellConfigCache: (framework: String?, aliases: [(name: String, path: String)], functions: [String], paths: [String], timestamp: Date)?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
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
    
    /// Gather environment information for context (used in pipeline)
    func gatherEnvironmentInfo(lastContextCwd: String?) -> [String] {
        var info: [String] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        
        // 1. Parse shell config files for aliases, functions, and customizations
        let shellResult = ShellConfigParser.parseShellConfigs(homeDir: home)
        info.append(contentsOf: shellResult.configInfo)
        
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
        if let cwd = lastContextCwd {
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
                let path = (cwd as NSString).appendingPathComponent(pf.file)
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
    
    // MARK: - Project Type Detection
    
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
        
        // Check for various project markers (order determines priority)
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
    
    // MARK: - Installed Tools Detection
    
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
    
    // MARK: - Project Technologies Detection
    
    /// Detect project technologies for a specific directory (not cached - cwd specific)
    func detectProjectTechnologies(at cwd: String) -> [String] {
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
    
    // MARK: - Shell Config Detection
    
    /// Get shell config info with caching (10 minute TTL)
    private func getCachedShellConfigInfo() -> (framework: String?, aliases: [(name: String, path: String)], functions: [String], paths: [String]) {
        // Check cache validity
        if let cached = shellConfigCache,
           Date().timeIntervalSince(cached.timestamp) < shellConfigCacheExpiration {
            return (cached.framework, cached.aliases, cached.functions, cached.paths)
        }
        
        // Use ShellConfigParser to parse configs
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        
        let result = ShellConfigParser.parseShellConfigs(homeDir: home)
        
        // Cache the result
        shellConfigCache = (
            framework: result.framework,
            aliases: result.aliases,
            functions: result.functions,
            paths: result.paths,
            timestamp: Date()
        )
        
        return (result.framework, result.aliases, result.functions, result.paths)
    }
    
    // MARK: - Cache Management
    
    /// Clear all caches (useful for testing or when user changes shell config)
    func clearCaches() {
        projectTypeCache.removeAll()
        installedToolsCache = nil
        shellConfigCache = nil
        envLogger.info("All environment caches cleared")
    }
}
