import Foundation

/// Represents Git repository state for a directory
struct GitInfo: Equatable {
    let branch: String
    let isDirty: Bool
    let ahead: Int
    let behind: Int
    
    /// Returns true if there are commits ahead or behind upstream
    var hasUpstreamDelta: Bool {
        ahead > 0 || behind > 0
    }
}

/// Service to fetch Git repository information for a given directory
final class GitInfoService {
    
    static let shared = GitInfoService()
    
    private init() {}
    
    /// Fetches Git info for the specified directory path
    /// Returns nil if the directory is not inside a Git repository
    func fetchGitInfo(for directoryPath: String) async -> GitInfo? {
        // Check if we're in a git repo
        guard await isGitRepository(at: directoryPath) else {
            return nil
        }
        
        async let branchResult = getCurrentBranch(at: directoryPath)
        async let dirtyResult = isDirty(at: directoryPath)
        async let upstreamResult = getUpstreamCounts(at: directoryPath)
        
        guard let branch = await branchResult else {
            return nil
        }
        
        let isDirty = await dirtyResult
        let (ahead, behind) = await upstreamResult
        
        return GitInfo(
            branch: branch,
            isDirty: isDirty,
            ahead: ahead,
            behind: behind
        )
    }
    
    // MARK: - Private Helpers
    
    private func isGitRepository(at path: String) async -> Bool {
        let result = await runGitCommand(["rev-parse", "--is-inside-work-tree"], at: path)
        return result?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
    
    private func getCurrentBranch(at path: String) async -> String? {
        // First try to get the branch name
        if let branch = await runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], at: path) {
            let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "HEAD" {
                return trimmed
            }
        }
        
        // If HEAD is detached, try to get a short SHA
        if let sha = await runGitCommand(["rev-parse", "--short", "HEAD"], at: path) {
            let trimmed = sha.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "(\(trimmed))"
            }
        }
        
        return nil
    }
    
    private func isDirty(at path: String) async -> Bool {
        // git status --porcelain returns nothing if clean
        if let status = await runGitCommand(["status", "--porcelain"], at: path) {
            return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
    
    private func getUpstreamCounts(at path: String) async -> (ahead: Int, behind: Int) {
        // Check if there's an upstream configured
        guard let _ = await runGitCommand(["rev-parse", "--abbrev-ref", "@{u}"], at: path) else {
            return (0, 0)
        }
        
        var ahead = 0
        var behind = 0
        
        // Get commits ahead of upstream
        if let aheadStr = await runGitCommand(["rev-list", "--count", "@{u}..HEAD"], at: path) {
            ahead = Int(aheadStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        
        // Get commits behind upstream
        if let behindStr = await runGitCommand(["rev-list", "--count", "HEAD..@{u}"], at: path) {
            behind = Int(behindStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        
        return (ahead, behind)
    }
    
    private func runGitCommand(_ args: [String], at path: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: path)
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                
                // Set environment to avoid any git hooks or pagers
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_PAGER"] = ""
                process.environment = env
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8)
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

