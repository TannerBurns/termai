import Foundation

// MARK: - Agent Tool Protocol

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var schema: ToolSchema { get }
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult
}

extension AgentTool {
    /// Resolve a path relative to the given working directory
    func resolvePath(_ path: String, cwd: String?) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        
        // If path is absolute, use it as-is
        if expandedPath.hasPrefix("/") {
            return expandedPath
        }
        
        // If we have a CWD, resolve relative to it
        if let cwd = cwd, !cwd.isEmpty {
            let cwdURL = URL(fileURLWithPath: cwd)
            let resolvedURL = cwdURL.appendingPathComponent(expandedPath)
            return resolvedURL.path
        }
        
        // Fall back to expanding the path (will be relative to app's CWD)
        return expandedPath
    }
    
    /// Notify observers that a file was modified on disk
    /// This allows open file editors to refresh their content
    func notifyFileModified(path: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .TermAIFileModifiedOnDisk,
                object: nil,
                userInfo: ["path": path]
            )
        }
    }
}

struct AgentToolResult {
    let success: Bool
    let output: String
    let error: String?
    /// For file operations, includes the before/after content for diff display
    let fileChange: FileChange?
    /// When true, the caller already displayed a result message (e.g., approval rejection)
    let skipResultMessage: Bool
    
    static func success(_ output: String, fileChange: FileChange? = nil) -> AgentToolResult {
        AgentToolResult(success: true, output: output, error: nil, fileChange: fileChange, skipResultMessage: false)
    }
    
    static func failure(_ error: String, fileChange: FileChange? = nil, skipResultMessage: Bool = false) -> AgentToolResult {
        AgentToolResult(success: false, output: "", error: error, fileChange: fileChange, skipResultMessage: skipResultMessage)
    }
}

// MARK: - Shell Command Executor Protocol

/// Protocol for executing shell commands in the terminal PTY
/// ChatSession implements this to allow ShellCommandTool to delegate execution
protocol ShellCommandExecutor: AnyObject {
    /// Execute a shell command and return the result
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - requireApproval: Whether to require user approval before execution
    ///   - timeout: Optional custom timeout (nil uses default from settings)
    /// - Returns: Tuple of (success, output, exitCode)
    func executeShellCommand(_ command: String, requireApproval: Bool, timeout: TimeInterval?) async -> (success: Bool, output: String, exitCode: Int)
}

// MARK: - Plan and Track Delegate Protocol

/// Protocol for managing agent goal and task tracking
/// ChatSession implements this to allow PlanAndTrackTool to update the UI
@MainActor
protocol PlanTrackDelegate: AnyObject {
    /// Set the agent's goal and optionally create a task checklist
    /// - Parameters:
    ///   - goal: The goal statement for this agent run
    ///   - tasks: Optional list of task descriptions to create a checklist
    func setGoalAndTasks(goal: String, tasks: [String]?)
    
    /// Mark a task as in-progress (starting work on it)
    /// - Parameter id: The 1-based task ID
    func markTaskInProgress(id: Int)
    
    /// Mark a task as complete
    /// - Parameters:
    ///   - id: The 1-based task ID
    ///   - note: Optional completion note
    func markTaskComplete(id: Int, note: String?)
    
    /// Get the current checklist status for context
    func getChecklistStatus() -> String?
}

// MARK: - File Operation Protocol

/// Protocol for tools that modify files and can provide change previews
protocol FileOperationTool: AgentTool {
    /// Prepare a preview of the file change without actually applying it
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange?
}

// MARK: - Process Manager (for background processes)

/// Observable process info for UI display
struct BackgroundProcessInfo: Identifiable, Equatable {
    let id: Int32  // PID
    let command: String
    let startTime: Date
    var isRunning: Bool
    var recentOutput: String
    
    var uptimeString: String {
        let interval = Date().timeIntervalSince(startTime)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h \(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))m"
        }
    }
    
    var shortCommand: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 40 {
            return String(trimmed.prefix(37)) + "..."
        }
        return trimmed
    }
}

@MainActor
final class ProcessManager: ObservableObject {
    static let shared = ProcessManager()
    
    /// Use a class so readability handlers can mutate the buffers
    class ManagedProcess {
        let pid: Int32
        let command: String
        let process: Process
        let outputPipe: Pipe
        let errorPipe: Pipe
        let startTime: Date
        var outputBuffer: String = ""
        var errorBuffer: String = ""
        let bufferLock = NSLock()
        
        init(pid: Int32, command: String, process: Process, outputPipe: Pipe, errorPipe: Pipe, startTime: Date) {
            self.pid = pid
            self.command = command
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.startTime = startTime
        }
        
        func appendOutput(_ text: String) {
            bufferLock.lock()
            outputBuffer += text
            // Keep buffer from growing too large
            if outputBuffer.count > 50000 {
                outputBuffer = String(outputBuffer.suffix(40000))
            }
            bufferLock.unlock()
        }
        
        func appendError(_ text: String) {
            bufferLock.lock()
            errorBuffer += text
            if errorBuffer.count > 10000 {
                errorBuffer = String(errorBuffer.suffix(8000))
            }
            bufferLock.unlock()
        }
        
        func getOutput() -> String {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return outputBuffer
        }
        
        func getError() -> String {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return errorBuffer
        }
    }
    
    /// Published list of running processes for UI
    @Published var runningProcesses: [BackgroundProcessInfo] = []
    
    /// Count of running processes (for badge)
    var runningCount: Int { runningProcesses.count }
    
    // Thread safety handled manually via queue - opt out of actor isolation
    nonisolated(unsafe) private var processes: [Int32: ManagedProcess] = [:]
    private let queue = DispatchQueue(label: "com.termai.processmanager")
    private var refreshTimer: Timer?
    
    private init() {
        // Timer will be started on-demand when processes are added
    }
    
    /// Start the refresh timer if not already running and there are processes
    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProcessList()
            }
        }
    }
    
    /// Stop the refresh timer if no processes are running
    private func stopRefreshTimerIfEmpty() {
        var isEmpty = false
        queue.sync {
            isEmpty = processes.isEmpty
        }
        if isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
    
    /// Refresh the published process list (uses pre-buffered output, no blocking reads)
    func refreshProcessList() {
        var updatedList: [BackgroundProcessInfo] = []
        
        queue.sync {
            for (pid, managed) in processes {
                let isRunning = managed.process.isRunning
                let recentOutput = managed.getOutput()
                
                updatedList.append(BackgroundProcessInfo(
                    id: pid,
                    command: managed.command,
                    startTime: managed.startTime,
                    isRunning: isRunning,
                    recentOutput: String(recentOutput.suffix(500))
                ))
            }
        }
        
        // Remove stopped processes from the internal list after a delay
        let stoppedPids = updatedList.filter { !$0.isRunning }.map { $0.id }
        if !stoppedPids.isEmpty {
            queue.async {
                for pid in stoppedPids {
                    // Clean up handlers before removing
                    self.processes[pid]?.outputPipe.fileHandleForReading.readabilityHandler = nil
                    self.processes[pid]?.errorPipe.fileHandleForReading.readabilityHandler = nil
                    self.processes.removeValue(forKey: pid)
                }
            }
            // Remove stopped processes from published list after showing briefly
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await MainActor.run {
                    self.runningProcesses.removeAll { stoppedPids.contains($0.id) }
                }
            }
        }
        
        runningProcesses = updatedList.sorted { $0.startTime > $1.startTime }
        
        // Stop timer if no processes remain
        stopRefreshTimerIfEmpty()
    }
    
    nonisolated func startProcess(command: String, cwd: String?, waitForOutput: String? = nil, timeout: TimeInterval = 5.0) async -> (pid: Int32, initialOutput: String, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        if let cwd = cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
        } catch {
            return (pid: -1, initialOutput: "", error: "Failed to start process: \(error.localizedDescription)")
        }
        
        let pid = process.processIdentifier
        
        // Create managed process object
        let managedProcess = ManagedProcess(
            pid: pid,
            command: command,
            process: process,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            startTime: Date()
        )
        
        // Store the managed process first so handlers can update it
        queue.sync {
            self.processes[pid] = managedProcess
        }
        
        // Set up readability handlers that update the stored process (non-blocking)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak managedProcess] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                managedProcess?.appendOutput(text)
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak managedProcess] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                managedProcess?.appendError(text)
            }
        }
        
        // Set up termination handler for immediate cleanup when process exits
        // This ensures readability handlers are cleaned up right away instead of
        // waiting for the periodic refreshProcessList() timer
        process.terminationHandler = { [weak managedProcess] _ in
            managedProcess?.outputPipe.fileHandleForReading.readabilityHandler = nil
            managedProcess?.errorPipe.fileHandleForReading.readabilityHandler = nil
        }
        
        let startTime = Date()
        
        // If waiting for specific output, poll until we see it or timeout
        if let waitFor = waitForOutput {
            while Date().timeIntervalSince(startTime) < timeout {
                let currentOutput = managedProcess.getOutput()
                let currentError = managedProcess.getError()
                
                if currentOutput.lowercased().contains(waitFor.lowercased()) || 
                   currentError.lowercased().contains(waitFor.lowercased()) {
                    break
                }
                
                // Check if process terminated
                if !process.isRunning {
                    break
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        } else {
            // Just wait a brief moment for initial output
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
        
        // Get collected output
        let finalOutput = managedProcess.getOutput()
        let finalError = managedProcess.getError()
        
        // Update the published list on main actor and start timer if needed
        await MainActor.run {
            self.startRefreshTimerIfNeeded()
            self.refreshProcessList()
        }
        
        let combinedOutput = finalOutput + (finalError.isEmpty ? "" : "\nSTDERR: \(finalError)")
        return (pid: pid, initialOutput: combinedOutput, error: nil)
    }
    
    nonisolated func checkProcess(pid: Int32, fullOutput: Bool = false) -> (running: Bool, output: String, error: String) {
        var result: (running: Bool, output: String, error: String) = (false, "", "")
        
        queue.sync {
            guard let managed = processes[pid] else {
                result = (false, "", "Process \(pid) not found in manager")
                return
            }
            
            let isRunning = managed.process.isRunning
            
            // Use buffered output (collected by readability handlers)
            let output: String
            let error: String
            if fullOutput {
                // Return complete output for cases like test runners where we need all output
                output = managed.getOutput()
                error = managed.getError()
            } else {
                // Return truncated output for normal status checks
                output = String(managed.getOutput().suffix(2000))
                error = String(managed.getError().suffix(500))
            }
            
            result = (isRunning, output, error)
        }
        
        return result
    }
    
    nonisolated func checkProcessByPort(port: Int) async -> (running: Bool, pid: Int32?, output: String) {
        // Run lsof on background queue to avoid blocking main thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                task.arguments = ["-i", ":\(port)", "-t"]
                
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let pid = Int32(output.components(separatedBy: .newlines).first ?? "") {
                        // Check if this is one of our managed processes
                        var managedOutput = ""
                        queue.sync {
                            if let managed = processes[pid] {
                                managedOutput = String(managed.outputBuffer.suffix(1000))
                            }
                        }
                        let result = (true, pid as Int32?, managedOutput.isEmpty ? "Process \(pid) running on port \(port)" : managedOutput)
                        continuation.resume(returning: result)
                        return
                    }
                } catch {
                    // lsof failed
                }
                
                continuation.resume(returning: (false, nil, "No process found on port \(port)"))
            }
        }
    }
    
    nonisolated func stopProcessSync(pid: Int32) -> Bool {
        var success = false
        queue.sync {
            if let managed = processes[pid] {
                managed.process.terminate()
                processes.removeValue(forKey: pid)
                success = true
            }
        }
        return success
    }
    
    func stopProcess(pid: Int32) -> Bool {
        let success = stopProcessSync(pid: pid)
        // Refresh the UI list
        refreshProcessList()
        return success
    }
    
    nonisolated func stopAllProcessesSync() {
        queue.sync {
            for (_, managed) in processes {
                managed.process.terminate()
            }
            processes.removeAll()
        }
    }
    
    func stopAllProcesses() {
        stopAllProcessesSync()
        // Refresh the UI list
        refreshProcessList()
    }
    
    nonisolated func listProcesses() -> [(pid: Int32, command: String, running: Bool, uptime: TimeInterval)] {
        var list: [(pid: Int32, command: String, running: Bool, uptime: TimeInterval)] = []
        queue.sync {
            for (pid, managed) in processes {
                list.append((
                    pid: pid,
                    command: managed.command,
                    running: managed.process.isRunning,
                    uptime: Date().timeIntervalSince(managed.startTime)
                ))
            }
        }
        return list.sorted { $0.pid < $1.pid }
    }
}

// MARK: - Agent Tool Registry

final class AgentToolRegistry {
    static let shared = AgentToolRegistry()
    
    private var tools: [String: AgentTool] = [:]
    private var outputBuffer: OutputBuffer
    private var memoryStore: MemoryStore
    
    /// Reference to the shell command tool for executor configuration
    private var shellCommandTool: ShellCommandTool?
    
    /// Reference to the plan and track tool for delegate configuration
    private var planAndTrackTool: PlanAndTrackTool?
    
    /// Reference to the create plan tool for delegate configuration (Navigator mode)
    private var createPlanTool: CreatePlanTool?
    
    private init() {
        self.outputBuffer = OutputBuffer()
        self.memoryStore = MemoryStore()
        registerDefaultTools()
    }
    
    private func registerDefaultTools() {
        register(ReadFileTool())
        register(WriteFileTool())
        register(EditFileTool())
        register(InsertLinesTool())
        register(DeleteLinesTool())
        register(DeleteFileTool())
        register(ListDirectoryTool())
        register(SearchOutputTool(buffer: outputBuffer))
        register(MemoryTool(store: memoryStore))
        register(SearchFilesTool())
        // Verification tools
        register(RunBackgroundTool())
        register(CheckProcessTool())
        register(StopProcessTool())
        register(HttpRequestTool())
        // Shell command tool (executor set later by ChatSession)
        let shellTool = ShellCommandTool()
        shellCommandTool = shellTool
        register(shellTool)
        // Plan and track tool (delegate set later by ChatSession)
        let planTool = PlanAndTrackTool()
        planAndTrackTool = planTool
        register(planTool)
        // Create plan tool for Navigator mode (delegate set later by ChatSession)
        let createPlan = CreatePlanTool()
        createPlanTool = createPlan
        register(createPlan)
    }
    
    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }
    
    func get(_ name: String) -> AgentTool? {
        tools[name]
    }
    
    func allTools() -> [AgentTool] {
        Array(tools.values)
    }
    
    // MARK: - Tool Categories by Agent Mode
    
    /// Tools available in Scout mode (read-only exploration)
    private static let scoutToolNames: Set<String> = [
        "read_file",
        "list_dir",
        "search_files",
        "search_output",
        "check_process",
        "http_request",
        "memory"
    ]
    
    /// Tools available in Navigator mode (read-only + plan creation)
    private static let navigatorToolNames: Set<String> = [
        "read_file",
        "list_dir",
        "search_files",
        "search_output",
        "check_process",
        "http_request",
        "memory",
        "create_plan"  // Navigator-specific tool
    ]
    
    /// Tools added in Copilot mode (file operations, no shell)
    private static let copilotToolNames: Set<String> = [
        "write_file",
        "edit_file",
        "insert_lines",
        "delete_lines",
        "delete_file",
        "plan_and_track"
    ]
    
    /// Tools added in Pilot mode (shell execution)
    private static let pilotToolNames: Set<String> = [
        "shell",
        "run_background",
        "stop_process"
    ]
    
    /// Get tools available for a specific agent mode
    func tools(for mode: AgentMode) -> [AgentTool] {
        let allowedNames: Set<String>
        switch mode {
        case .scout:
            allowedNames = Self.scoutToolNames
        case .navigator:
            allowedNames = Self.navigatorToolNames
        case .copilot:
            allowedNames = Self.scoutToolNames.union(Self.copilotToolNames)
        case .pilot:
            allowedNames = Self.scoutToolNames.union(Self.copilotToolNames).union(Self.pilotToolNames)
        }
        
        return tools.values.filter { allowedNames.contains($0.name) }
    }
    
    /// Get tool schemas for a specific agent mode and provider
    func schemas(for mode: AgentMode, provider: ProviderType) -> [[String: Any]] {
        tools(for: mode).map { tool in
            switch provider {
            case .cloud(.openai):
                return tool.schema.toOpenAI()
            case .cloud(.anthropic):
                return tool.schema.toAnthropic()
            case .cloud(.google):
                return tool.schema.toGoogle()
            case .local:
                return tool.schema.toOpenAI()
            }
        }
    }
    
    /// Get tool schemas wrapped for Google API format for a specific mode
    func googleToolsPayload(for mode: AgentMode) -> [[String: Any]] {
        [["functionDeclarations": tools(for: mode).map { $0.schema.toGoogle() }]]
    }
    
    /// Get tool descriptions for a specific agent mode
    func toolDescriptions(for mode: AgentMode) -> String {
        tools(for: mode).map { "- \($0.name): \($0.description)" }.sorted().joined(separator: "\n")
    }
    
    /// Check if a tool is available in the given mode
    func isToolAvailable(_ toolName: String, in mode: AgentMode) -> Bool {
        let allowedNames: Set<String>
        switch mode {
        case .scout:
            allowedNames = Self.scoutToolNames
        case .navigator:
            allowedNames = Self.navigatorToolNames
        case .copilot:
            allowedNames = Self.scoutToolNames.union(Self.copilotToolNames)
        case .pilot:
            allowedNames = Self.scoutToolNames.union(Self.copilotToolNames).union(Self.pilotToolNames)
        }
        return allowedNames.contains(toolName)
    }
    
    /// Set the shell command executor (called by ChatSession when starting agent mode)
    func setShellExecutor(_ executor: ShellCommandExecutor?) {
        shellCommandTool?.executor = executor
    }
    
    /// Set the plan track delegate (called by ChatSession when starting agent mode)
    func setPlanTrackDelegate(_ delegate: PlanTrackDelegate?) {
        planAndTrackTool?.delegate = delegate
    }
    
    /// Set the create plan delegate (called by ChatSession when in Navigator mode)
    func setCreatePlanDelegate(_ delegate: CreatePlanDelegate?) {
        createPlanTool?.delegate = delegate
    }
    
    /// Store output in the buffer for later search
    func storeOutput(_ output: String, command: String) {
        outputBuffer.store(output, command: command)
    }
    
    /// Clear session-specific data
    func clearSession() {
        outputBuffer.clear()
        memoryStore.clear()
    }
    
    /// Get tool descriptions for the agent prompt
    func toolDescriptions() -> String {
        tools.values.map { "- \($0.name): \($0.description)" }.sorted().joined(separator: "\n")
    }
    
    /// Get all tool schemas in provider-specific format
    /// - Parameter provider: The provider type to format schemas for
    /// - Returns: Array of schema dictionaries ready for API requests
    func allSchemas(for provider: ProviderType) -> [[String: Any]] {
        allTools().map { tool in
            switch provider {
            case .cloud(.openai):
                return tool.schema.toOpenAI()
            case .cloud(.anthropic):
                return tool.schema.toAnthropic()
            case .cloud(.google):
                return tool.schema.toGoogle()
            case .local:
                // Local providers use OpenAI-compatible format
                return tool.schema.toOpenAI()
            }
        }
    }
    
    /// Get tool schemas wrapped for Google API format (needs functionDeclarations wrapper)
    func googleToolsPayload() -> [[String: Any]] {
        [["functionDeclarations": allTools().map { $0.schema.toGoogle() }]]
    }
}

// MARK: - Output Buffer for Search

final class OutputBuffer {
    struct Entry {
        let command: String
        let output: String
        let timestamp: Date
    }
    
    private var entries: [Entry] = []
    private let maxEntries = 50
    private let maxTotalSize: Int
    
    init(maxTotalSize: Int = AgentSettings.shared.maxFullOutputBuffer) {
        self.maxTotalSize = maxTotalSize
    }
    
    func store(_ output: String, command: String) {
        entries.append(Entry(command: command, output: output, timestamp: Date()))
        
        // Trim old entries if exceeding limits
        while entries.count > maxEntries {
            entries.removeFirst()
        }
        
        // Trim by size
        var totalSize = entries.reduce(0) { $0 + $1.output.count }
        while totalSize > maxTotalSize && !entries.isEmpty {
            let removed = entries.removeFirst()
            totalSize -= removed.output.count
        }
    }
    
    func search(pattern: String, contextLines: Int = 3) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        
        for entry in entries {
            let lines = entry.output.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(pattern) {
                    let start = max(0, index - contextLines)
                    let end = min(lines.count - 1, index + contextLines)
                    let context = lines[start...end].joined(separator: "\n")
                    matches.append(SearchMatch(
                        command: entry.command,
                        lineNumber: index + 1,
                        matchedLine: line,
                        context: context
                    ))
                }
            }
        }
        
        return matches
    }
    
    func getFullOutput(forCommand command: String) -> String? {
        entries.last(where: { $0.command == command })?.output
    }
    
    func clear() {
        entries.removeAll()
    }
}

struct SearchMatch {
    let command: String
    let lineNumber: Int
    let matchedLine: String
    let context: String
}

// MARK: - Memory Store

final class MemoryStore {
    private var store: [String: String] = [:]
    
    func save(key: String, value: String) {
        store[key] = value
    }
    
    func recall(key: String) -> String? {
        store[key]
    }
    
    func list() -> [String] {
        Array(store.keys).sorted()
    }
    
    func clear() {
        store.removeAll()
    }
}

// MARK: - Read File Tool

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read contents of a file. Args: path (required), start_line (optional), end_line (optional)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Read the contents of a file at the specified path",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to read", required: true),
                ToolParameter(name: "start_line", type: .integer, description: "Starting line number (1-based, optional)", required: false),
                ToolParameter(name: "end_line", type: .integer, description: "Ending line number (1-based, inclusive, optional)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            
            // Handle line range if specified
            if let startStr = args["start_line"], let startLine = Int(startStr) {
                let endLine = args["end_line"].flatMap { Int($0) }
                let lines = content.components(separatedBy: .newlines)
                let start = max(0, startLine - 1)
                let end = min(lines.count, endLine ?? lines.count)
                
                if start >= lines.count {
                    return .failure("Start line \(startLine) exceeds file length (\(lines.count) lines)")
                }
                
                let selectedLines = lines[start..<end]
                let numberedLines = selectedLines.enumerated().map { 
                    "\(start + $0.offset + 1)| \($0.element)" 
                }.joined(separator: "\n")
                return .success(numberedLines)
            }
            
            // Get dynamic output limit from settings
            // Use _contextTokens arg if provided by session, otherwise use minimum
            let contextTokens = args["_contextTokens"].flatMap { Int($0) } ?? 32_000
            let maxSize = AgentSettings.shared.effectiveOutputCaptureLimit(forContextTokens: contextTokens)
            
            if content.count > maxSize {
                let lines = content.components(separatedBy: .newlines)
                // Use head+tail truncation to show file structure (imports at top, exports/main at bottom)
                let truncated = SmartTruncator.headTail(content, maxChars: maxSize, headRatio: 0.6)
                return .success("File has \(lines.count) lines, \(content.count) chars. Use start_line/end_line for specific sections.\n\n\(truncated)")
            }
            
            return .success(content)
        } catch {
            return .failure("Error reading file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Write File Tool

struct WriteFileTool: AgentTool, FileOperationTool {
    let name = "write_file"
    let description = "Create a NEW file or COMPLETELY REWRITE an existing file. For small edits to existing files, prefer edit_file, insert_lines, or delete_lines instead. Args: path (required), content (required), mode ('overwrite' or 'append', default: overwrite)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a NEW file or COMPLETELY REWRITE an existing file. For small changes to existing files, prefer edit_file (search/replace), insert_lines, or delete_lines instead - they are safer and more precise.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to write", required: true),
                ToolParameter(name: "content", type: .string, description: "Content to write to the file", required: true),
                ToolParameter(name: "mode", type: .string, description: "Write mode: 'overwrite' (default) or 'append'", required: false, enumValues: ["overwrite", "append"])
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let content = args["content"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let mode = args["mode"] ?? "overwrite"
        let fileExists = FileManager.default.fileExists(atPath: expandedPath)
        
        // Read current content if file exists
        var beforeContent: String? = nil
        if fileExists {
            beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8)
        }
        
        // Compute after content
        let afterContent: String
        if mode == "append" && beforeContent != nil {
            afterContent = beforeContent! + content
        } else {
            afterContent = content
        }
        
        let operationType: FileOperationType = fileExists ? (mode == "append" ? .insert : .overwrite) : .create
        
        return FileChange(
            filePath: expandedPath,
            operationType: operationType,
            beforeContent: beforeContent,
            afterContent: afterContent
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let content = args["content"] else {
            return .failure("Missing required argument: content")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let mode = args["mode"] ?? "overwrite"
        let writeMode: FileOperation.WriteMode = mode == "append" ? .append : .overwrite
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.write(path: expandedPath, content: content, mode: writeMode)
        
        // Acquire lock and execute via FileLockManager
        let lockResult = await MainActor.run {
            Task {
                await FileLockManager.shared.acquireLock(for: operation, sessionId: sessionId)
            }
        }
        let acquisitionResult = await lockResult.value
        
        defer {
            Task { @MainActor in
                FileLockManager.shared.releaseLock(for: expandedPath, sessionId: sessionId)
            }
        }
        
        switch acquisitionResult {
        case .acquired:
            // Execute the operation directly
            return await executeWriteOperation(path: expandedPath, content: content, mode: writeMode, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeWriteOperation(path: String, content: String, mode: FileOperation.WriteMode, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            if mode == .append && FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                try handle.close()
                notifyFileModified(path: path)
                return .success("Appended \(content.count) chars to \(path)", fileChange: fileChange)
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
                notifyFileModified(path: path)
                return .success("Wrote \(content.count) chars to \(path)", fileChange: fileChange)
            }
        } catch {
            return .failure("Error writing file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Edit File Tool (Search/Replace)

struct EditFileTool: AgentTool, FileOperationTool {
    let name = "edit_file"
    let description = "PREFERRED for modifying existing files. Search and replace specific text. Args: path (required), old_text (required - exact text to find, include enough context to be unique), new_text (required - replacement text), replace_all (optional, 'true'/'false', default: false)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "PREFERRED tool for modifying existing files. Finds and replaces specific text. Include enough surrounding context in old_text to ensure a unique match.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to edit", required: true),
                ToolParameter(name: "old_text", type: .string, description: "Exact text to find and replace (must match exactly including whitespace)", required: true),
                ToolParameter(name: "new_text", type: .string, description: "Replacement text (can be empty to delete)", required: true),
                ToolParameter(name: "replace_all", type: .boolean, description: "Replace all occurrences (default: false, only first match)", required: false)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let oldText = args["old_text"], !oldText.isEmpty,
              let newText = args["new_text"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let replaceAll = args["replace_all"]?.lowercased() == "true"
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Check if old_text exists
        guard beforeContent.contains(oldText) else {
            return nil
        }
        
        // Compute after content
        let afterContent: String
        if replaceAll {
            afterContent = beforeContent.replacingOccurrences(of: oldText, with: newText)
        } else {
            if let range = beforeContent.range(of: oldText) {
                afterContent = beforeContent.replacingCharacters(in: range, with: newText)
            } else {
                afterContent = beforeContent
            }
        }
        
        return FileChange(
            filePath: expandedPath,
            operationType: .edit,
            beforeContent: beforeContent,
            afterContent: afterContent,
            oldText: oldText,
            newText: newText
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let oldText = args["old_text"], !oldText.isEmpty else {
            return .failure("Missing required argument: old_text (the text to find and replace)")
        }
        guard let newText = args["new_text"] else {
            return .failure("Missing required argument: new_text (replacement text, can be empty string to delete)")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let replaceAll = args["replace_all"]?.lowercased() == "true"
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.edit(path: expandedPath, oldText: oldText, newText: newText, replaceAll: replaceAll)
        
        // Acquire lock and execute via FileLockManager
        let lockResult = await MainActor.run {
            Task {
                await FileLockManager.shared.acquireLock(for: operation, sessionId: sessionId)
            }
        }
        let acquisitionResult = await lockResult.value
        
        defer {
            Task { @MainActor in
                FileLockManager.shared.releaseLock(for: expandedPath, sessionId: sessionId)
            }
        }
        
        switch acquisitionResult {
        case .acquired:
            // Execute the operation directly
            return await executeEditOperation(path: expandedPath, oldText: oldText, newText: newText, replaceAll: replaceAll, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeEditOperation(path: String, oldText: String, newText: String, replaceAll: Bool, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            
            guard content.contains(oldText) else {
                let lines = content.components(separatedBy: .newlines)
                let preview = lines.prefix(10).joined(separator: "\n")
                return .failure("Text not found in file. The old_text must match exactly (including whitespace/indentation).\n\nFile has \(lines.count) lines. First 10 lines:\n\(preview)")
            }
            
            let occurrences = content.components(separatedBy: oldText).count - 1
            
            if replaceAll {
                content = content.replacingOccurrences(of: oldText, with: newText)
            } else {
                if let range = content.range(of: oldText) {
                    content = content.replacingCharacters(in: range, with: newText)
                }
            }
            
            try content.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let resultLines = content.components(separatedBy: "\n")
            let previewLines = resultLines.prefix(20).enumerated().map { "\($0.offset + 1)| \($0.element)" }.joined(separator: "\n")
            let suffix = resultLines.count > 20 ? "\n... (\(resultLines.count - 20) more lines)" : ""
            
            if replaceAll {
                return .success("Replaced \(occurrences) occurrence(s) in \(path).\n\nFile preview:\n\(previewLines)\(suffix)", fileChange: fileChange)
            } else {
                return .success("Replaced 1 occurrence in \(path).\n\nFile preview:\n\(previewLines)\(suffix)", fileChange: fileChange)
            }
        } catch {
            return .failure("Error editing file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Insert Lines Tool

struct InsertLinesTool: AgentTool, FileOperationTool {
    let name = "insert_lines"
    let description = "Insert lines at a specific position in a file. Args: path (required), line_number (required - 1-based, lines inserted BEFORE this line), content (required). TIP: For markdown, include a leading blank line if inserting after content."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Insert lines at a specific position in a file (lines inserted BEFORE the specified line number)",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file", required: true),
                ToolParameter(name: "line_number", type: .integer, description: "Line number where to insert (1-based, content inserted BEFORE this line)", required: true),
                ToolParameter(name: "content", type: .string, description: "Content to insert (can be multiple lines)", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let lineNumStr = args["line_number"], let lineNumber = Int(lineNumStr), lineNumber >= 1,
              let insertContent = args["content"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Compute after content
        var lines = beforeContent.components(separatedBy: "\n")
        let insertIndex = min(lineNumber - 1, lines.count)
        let newLines = insertContent.components(separatedBy: "\n")
        lines.insert(contentsOf: newLines, at: insertIndex)
        let afterContent = lines.joined(separator: "\n")
        
        return FileChange(
            filePath: expandedPath,
            operationType: .insert,
            beforeContent: beforeContent,
            afterContent: afterContent,
            startLine: lineNumber,
            endLine: lineNumber + newLines.count - 1
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let lineNumStr = args["line_number"], let lineNumber = Int(lineNumStr), lineNumber >= 1 else {
            return .failure("Missing or invalid line_number (must be >= 1)")
        }
        guard let insertContent = args["content"] else {
            return .failure("Missing required argument: content")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.insertLines(path: expandedPath, lineNumber: lineNumber, content: insertContent)
        
        // Acquire lock and execute via FileLockManager
        let lockResult = await MainActor.run {
            Task {
                await FileLockManager.shared.acquireLock(for: operation, sessionId: sessionId)
            }
        }
        let acquisitionResult = await lockResult.value
        
        defer {
            Task { @MainActor in
                FileLockManager.shared.releaseLock(for: expandedPath, sessionId: sessionId)
            }
        }
        
        switch acquisitionResult {
        case .acquired:
            // Execute the operation directly
            return await executeInsertOperation(path: expandedPath, lineNumber: lineNumber, content: insertContent, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeInsertOperation(path: String, lineNumber: Int, content insertContent: String, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            
            let normalizedInsert = insertContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.contains(normalizedInsert) {
                return .success("ALREADY EXISTS: The content you're trying to insert already exists in the file. No changes made. Use read_file to verify the current state.", fileChange: nil)
            }
            
            var lines = content.components(separatedBy: "\n")
            let insertIndex = min(lineNumber - 1, lines.count)
            let newLines = insertContent.components(separatedBy: "\n")
            lines.insert(contentsOf: newLines, at: insertIndex)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let previewStart = max(0, insertIndex - 2)
            let previewEnd = min(lines.count, insertIndex + newLines.count + 2)
            let preview = lines[previewStart..<previewEnd].enumerated().map { 
                "\(previewStart + $0.offset + 1)| \($0.element)" 
            }.joined(separator: "\n")
            
            return .success("Inserted \(newLines.count) line(s) at line \(lineNumber).\n\nPreview around insertion:\n\(preview)", fileChange: fileChange)
        } catch {
            return .failure("Error inserting lines: \(error.localizedDescription)")
        }
    }
}

// MARK: - Delete Lines Tool

struct DeleteLinesTool: AgentTool, FileOperationTool {
    let name = "delete_lines"
    let description = "Delete a range of lines from a file. Args: path (required), start_line (required, 1-based), end_line (required, 1-based, inclusive)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a range of lines from a file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file", required: true),
                ToolParameter(name: "start_line", type: .integer, description: "Starting line number to delete (1-based)", required: true),
                ToolParameter(name: "end_line", type: .integer, description: "Ending line number to delete (1-based, inclusive)", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let startStr = args["start_line"], let startLine = Int(startStr), startLine >= 1,
              let endStr = args["end_line"], let endLine = Int(endStr), endLine >= startLine else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Compute after content
        var lines = beforeContent.components(separatedBy: "\n")
        let start = max(0, startLine - 1)
        let end = min(lines.count, endLine)
        
        if start < lines.count {
            lines.removeSubrange(start..<end)
        }
        
        let afterContent = lines.joined(separator: "\n")
        
        return FileChange(
            filePath: expandedPath,
            operationType: .delete,
            beforeContent: beforeContent,
            afterContent: afterContent,
            startLine: startLine,
            endLine: endLine
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let startStr = args["start_line"], let startLine = Int(startStr), startLine >= 1 else {
            return .failure("Missing or invalid start_line (must be >= 1)")
        }
        guard let endStr = args["end_line"], let endLine = Int(endStr), endLine >= startLine else {
            return .failure("Missing or invalid end_line (must be >= start_line)")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.deleteLines(path: expandedPath, startLine: startLine, endLine: endLine)
        
        // Acquire lock and execute via FileLockManager
        let lockResult = await MainActor.run {
            Task {
                await FileLockManager.shared.acquireLock(for: operation, sessionId: sessionId)
            }
        }
        let acquisitionResult = await lockResult.value
        
        defer {
            Task { @MainActor in
                FileLockManager.shared.releaseLock(for: expandedPath, sessionId: sessionId)
            }
        }
        
        switch acquisitionResult {
        case .acquired:
            // Execute the operation directly
            return await executeDeleteOperation(path: expandedPath, startLine: startLine, endLine: endLine, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.")
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.")
        }
    }
    
    private func executeDeleteOperation(path: String, startLine: Int, endLine: Int, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            
            let start = max(0, startLine - 1)
            let end = min(lines.count, endLine)
            
            if start >= lines.count {
                return .failure("start_line \(startLine) exceeds file length (\(lines.count) lines)")
            }
            
            let deletedCount = end - start
            lines.removeSubrange(start..<end)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            return .success("Deleted \(deletedCount) line(s) from \(path)", fileChange: fileChange)
        } catch {
            return .failure("Error deleting lines: \(error.localizedDescription)")
        }
    }
}

// MARK: - Delete File Tool

/// A tool that always requires user approval before execution
protocol RequiresApprovalTool: AgentTool {
    /// This tool always requires user approval, regardless of settings
    var alwaysRequiresApproval: Bool { get }
}

extension RequiresApprovalTool {
    var alwaysRequiresApproval: Bool { true }
}

struct DeleteFileTool: AgentTool, FileOperationTool, RequiresApprovalTool {
    let name = "delete_file"
    let description = "Delete a file. ALWAYS requires user approval. Args: path (required)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a file at the specified path. This operation ALWAYS requires user approval before execution.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to delete", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        // Read current content for preview
        let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8)
        
        return FileChange(
            filePath: expandedPath,
            operationType: .deleteFile,
            beforeContent: beforeContent,
            afterContent: nil  // File will be deleted, no after content
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Prepare file change for diff display
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Delete the file
        do {
            try FileManager.default.removeItem(atPath: expandedPath)
            notifyFileModified(path: expandedPath)  // Notify so any open tabs can react
            return .success("Deleted file: \(expandedPath)", fileChange: fileChange)
        } catch {
            return .failure("Error deleting file: \(error.localizedDescription)")
        }
    }
}

// MARK: - List Directory Tool

struct ListDirectoryTool: AgentTool {
    let name = "list_dir"
    let description = "List contents of a directory. Args: path (required), recursive (optional, 'true'/'false', default: false)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List contents of a directory",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the directory to list", required: true),
                ToolParameter(name: "recursive", type: .boolean, description: "List recursively (default: false)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        let recursive = args["recursive"]?.lowercased() == "true"
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("Directory not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/dir' if CWD is unknown.")
            }
            return .failure("Directory not found: '\(path)'. Use an absolute path if needed.")
        }
        
        do {
            let contents: [URL]
            if recursive {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                var urls: [URL] = []
                while let fileURL = enumerator?.nextObject() as? URL {
                    urls.append(fileURL)
                    if urls.count > 500 { break } // Limit for safety
                }
                contents = urls
            } else {
                contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            }
            
            var output: [String] = []
            let baseURL = URL(fileURLWithPath: expandedPath).standardized
            for item in contents.sorted(by: { $0.path < $1.path }) {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // Use proper path relativization instead of string replacement
                let itemStandardized = item.standardized
                let relativePath: String
                if itemStandardized.path.hasPrefix(baseURL.path + "/") {
                    relativePath = String(itemStandardized.path.dropFirst(baseURL.path.count + 1))
                } else if itemStandardized.path == baseURL.path {
                    relativePath = "."
                } else {
                    // Fallback to just the filename if paths don't match
                    relativePath = item.lastPathComponent
                }
                let suffix = isDir ? "/" : ""
                output.append("\(relativePath)\(suffix)")
            }
            
            if output.isEmpty {
                return .success("(empty directory)")
            }
            
            return .success(output.joined(separator: "\n"))
        } catch {
            return .failure("Error listing directory: \(error.localizedDescription)")
        }
    }
}

// MARK: - Search Output Tool

struct SearchOutputTool: AgentTool {
    let name = "search_output"
    let description = "Search through previous command outputs. Args: pattern (required), context_lines (optional, default: 3)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search through previous command outputs for a pattern",
            parameters: [
                ToolParameter(name: "pattern", type: .string, description: "Search pattern to find in previous outputs", required: true),
                ToolParameter(name: "context_lines", type: .integer, description: "Number of context lines around matches (default: 3)", required: false)
            ]
        )
    }
    
    private let buffer: OutputBuffer
    
    init(buffer: OutputBuffer) {
        self.buffer = buffer
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let pattern = args["pattern"], !pattern.isEmpty else {
            return .failure("Missing required argument: pattern")
        }
        
        let contextLines = args["context_lines"].flatMap { Int($0) } ?? 3
        let matches = buffer.search(pattern: pattern, contextLines: contextLines)
        
        if matches.isEmpty {
            return .success("No matches found for '\(pattern)'")
        }
        
        var output: [String] = ["Found \(matches.count) matches for '\(pattern)':\n"]
        for (index, match) in matches.prefix(20).enumerated() {
            output.append("--- Match \(index + 1) (from '\(match.command)', line \(match.lineNumber)) ---")
            output.append(match.context)
            output.append("")
        }
        
        if matches.count > 20 {
            output.append("... and \(matches.count - 20) more matches")
        }
        
        return .success(output.joined(separator: "\n"))
    }
}

// MARK: - Memory Tool

struct MemoryTool: AgentTool {
    let name = "memory"
    let description = "Store and recall notes during task execution. Args: action ('save'/'recall'/'list'), key (for save/recall), value (for save)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Store and recall notes during task execution",
            parameters: [
                ToolParameter(name: "action", type: .string, description: "Action to perform", required: true, enumValues: ["save", "recall", "list"]),
                ToolParameter(name: "key", type: .string, description: "Key for save/recall operations", required: false),
                ToolParameter(name: "value", type: .string, description: "Value to save (required for save action)", required: false)
            ]
        )
    }
    
    private let store: MemoryStore
    
    init(store: MemoryStore) {
        self.store = store
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let action = args["action"]?.lowercased() else {
            return .failure("Missing required argument: action (save/recall/list)")
        }
        
        switch action {
        case "save":
            guard let key = args["key"], !key.isEmpty else {
                return .failure("Missing required argument: key")
            }
            guard let value = args["value"] else {
                return .failure("Missing required argument: value")
            }
            store.save(key: key, value: value)
            return .success("Saved '\(key)'")
            
        case "recall":
            guard let key = args["key"], !key.isEmpty else {
                return .failure("Missing required argument: key")
            }
            if let value = store.recall(key: key) {
                return .success(value)
            } else {
                return .success("No value stored for '\(key)'")
            }
            
        case "list":
            let keys = store.list()
            if keys.isEmpty {
                return .success("No stored memories")
            }
            return .success("Stored keys: \(keys.joined(separator: ", "))")
            
        default:
            return .failure("Unknown action: \(action). Use save/recall/list")
        }
    }
}

// MARK: - Search Files Tool

struct SearchFilesTool: AgentTool {
    let name = "search_files"
    let description = "Search for files by name pattern. Args: path (required), pattern (required, e.g. '*.swift'), recursive (optional, default: true)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search for files by name pattern (glob)",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Directory path to search in", required: true),
                ToolParameter(name: "pattern", type: .string, description: "Glob pattern to match (e.g., '*.swift', 'test_*.py')", required: true),
                ToolParameter(name: "recursive", type: .boolean, description: "Search recursively (default: true)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let pattern = args["pattern"], !pattern.isEmpty else {
            return .failure("Missing required argument: pattern")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        let recursive = args["recursive"]?.lowercased() != "false"
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("Directory not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/dir' if CWD is unknown.")
            }
            return .failure("Directory not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Convert glob pattern to a simple check
        let patternParts = pattern.components(separatedBy: "*")
        
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent
            
            // Simple glob matching
            var isMatch = true
            var remaining = filename
            for (index, part) in patternParts.enumerated() {
                if part.isEmpty { continue }
                if index == 0 && !part.isEmpty {
                    // Must start with this
                    if !remaining.hasPrefix(part) {
                        isMatch = false
                        break
                    }
                    remaining = String(remaining.dropFirst(part.count))
                } else if index == patternParts.count - 1 && !part.isEmpty {
                    // Must end with this
                    if !remaining.hasSuffix(part) {
                        isMatch = false
                        break
                    }
                } else if !part.isEmpty {
                    // Must contain this
                    if let range = remaining.range(of: part) {
                        remaining = String(remaining[range.upperBound...])
                    } else {
                        isMatch = false
                        break
                    }
                }
            }
            
            if isMatch {
                let relativePath = fileURL.path.replacingOccurrences(of: expandedPath, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                matches.append(relativePath)
                
                if matches.count > 200 { break } // Limit for safety
            }
        }
        
        if matches.isEmpty {
            return .success("No files matching '\(pattern)' found in \(path)")
        }
        
        return .success("Found \(matches.count) files:\n\(matches.joined(separator: "\n"))")
    }
}

// MARK: - Run Background Tool

struct RunBackgroundTool: AgentTool {
    let name = "run_background"
    let description = "Start a process in the background (e.g., a server). Args: command (required), wait_for (optional - text to wait for in output to confirm startup), timeout (optional - seconds to wait, default: 5)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Start a process in the background (useful for servers, watchers, etc.)",
            parameters: [
                ToolParameter(name: "command", type: .string, description: "Command to run in the background", required: true),
                ToolParameter(name: "wait_for", type: .string, description: "Text to wait for in output to confirm startup", required: false),
                ToolParameter(name: "timeout", type: .integer, description: "Seconds to wait for startup confirmation (default: 5)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let command = args["command"], !command.isEmpty else {
            return .failure("Missing required argument: command")
        }
        
        let waitFor = args["wait_for"]
        let timeout = Double(args["timeout"] ?? "5") ?? 5.0
        
        let result = await ProcessManager.shared.startProcess(
            command: command,
            cwd: cwd,
            waitForOutput: waitFor,
            timeout: timeout
        )
        
        if let error = result.error {
            return .failure(error)
        }
        
        var output = "Started background process with PID: \(result.pid)"
        if !result.initialOutput.isEmpty {
            output += "\n\nInitial output:\n\(String(result.initialOutput.prefix(1500)))"
        }
        
        return .success(output)
    }
}

// MARK: - Check Process Tool

struct CheckProcessTool: AgentTool {
    let name = "check_process"
    let description = "Check if a background process is running. Args: pid (optional - process ID), port (optional - check by port number), list (optional - 'true' to list all managed processes)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Check if a background process is running by PID, port, or list all",
            parameters: [
                ToolParameter(name: "pid", type: .integer, description: "Process ID to check", required: false),
                ToolParameter(name: "port", type: .integer, description: "Port number to check for listening process", required: false),
                ToolParameter(name: "list", type: .boolean, description: "List all managed background processes", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        // List all processes
        if args["list"]?.lowercased() == "true" {
            let processes = await MainActor.run { ProcessManager.shared.listProcesses() }
            if processes.isEmpty {
                return .success("No managed background processes")
            }
            
            var output = "Managed background processes:\n"
            for proc in processes {
                let status = proc.running ? "RUNNING" : "STOPPED"
                let uptime = Int(proc.uptime)
                output += "  PID \(proc.pid): \(status) (uptime: \(uptime)s) - \(proc.command.prefix(50))\n"
            }
            return .success(output)
        }
        
        // Check by PID
        if let pidStr = args["pid"], let pid = Int32(pidStr) {
            let result = await MainActor.run { ProcessManager.shared.checkProcess(pid: pid) }
            
            var output = "Process \(pid): \(result.running ? "RUNNING" : "NOT RUNNING")"
            if !result.output.isEmpty {
                output += "\n\nRecent output:\n\(result.output)"
            }
            if !result.error.isEmpty && result.error != "Process \(pid) not found in manager" {
                output += "\n\nRecent errors:\n\(result.error)"
            }
            
            return .success(output)
        }
        
        // Check by port
        if let portStr = args["port"], let port = Int(portStr) {
            let result = await ProcessManager.shared.checkProcessByPort(port: port)
            
            var output = "Port \(port): \(result.running ? "IN USE" : "FREE")"
            if let pid = result.pid {
                output += " (PID: \(pid))"
            }
            if !result.output.isEmpty {
                output += "\n\(result.output)"
            }
            
            return .success(output)
        }
        
        return .failure("Must provide either 'pid', 'port', or 'list=true'")
    }
}

// MARK: - Stop Process Tool

struct StopProcessTool: AgentTool {
    let name = "stop_process"
    let description = "Stop a background process. Args: pid (required - process ID to stop), all (optional - 'true' to stop all managed processes)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Stop a background process by PID or stop all managed processes",
            parameters: [
                ToolParameter(name: "pid", type: .integer, description: "Process ID to stop", required: false),
                ToolParameter(name: "all", type: .boolean, description: "Stop all managed background processes", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        // Stop all processes
        if args["all"]?.lowercased() == "true" {
            await MainActor.run {
                ProcessManager.shared.stopAllProcessesSync()
                ProcessManager.shared.refreshProcessList()
            }
            return .success("Stopped all managed background processes")
        }
        
        // Stop specific PID
        guard let pidStr = args["pid"], let pid = Int32(pidStr) else {
            return .failure("Missing required argument: pid")
        }
        
        let success = await MainActor.run { ProcessManager.shared.stopProcessSync(pid: pid) }
        if success {
            await MainActor.run {
                ProcessManager.shared.refreshProcessList()
            }
            return .success("Stopped process \(pid)")
        } else {
            return .failure("Process \(pid) not found or already stopped")
        }
    }
}

// MARK: - HTTP Request Tool

struct HttpRequestTool: AgentTool {
    let name = "http_request"
    let description = "Make an HTTP request to test APIs. Args: url (required), method (optional: GET/POST/PUT/DELETE, default: GET), body (optional - JSON string for POST/PUT), headers (optional - comma-separated key:value pairs)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Make an HTTP request to test APIs and web endpoints",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "URL to request", required: true),
                ToolParameter(name: "method", type: .string, description: "HTTP method", required: false, enumValues: ["GET", "POST", "PUT", "DELETE", "PATCH"]),
                ToolParameter(name: "body", type: .string, description: "Request body (JSON string for POST/PUT/PATCH)", required: false),
                ToolParameter(name: "headers", type: .string, description: "Headers as comma-separated key:value pairs", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let urlString = args["url"], !urlString.isEmpty else {
            return .failure("Missing required argument: url")
        }
        
        guard let url = URL(string: urlString) else {
            return .failure("Invalid URL: \(urlString)")
        }
        
        let method = args["method"]?.uppercased() ?? "GET"
        let body = args["body"]
        let headersStr = args["headers"]
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = AgentSettings.shared.httpRequestTimeout
        
        // Parse headers
        if let headersStr = headersStr {
            for pair in headersStr.components(separatedBy: ",") {
                let parts = pair.components(separatedBy: ":")
                if parts.count >= 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }
        
        // Set content type for POST/PUT with body
        if let body = body, !body.isEmpty, (method == "POST" || method == "PUT" || method == "PATCH") {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body.data(using: .utf8)
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response type")
            }
            
            let statusCode = httpResponse.statusCode
            let statusEmoji = (200..<300).contains(statusCode) ? "✓" : "✗"
            
            var output = "\(statusEmoji) HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
            output += "\nURL: \(method) \(urlString)"
            
            // Add response headers summary
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                output += "\nContent-Type: \(contentType)"
            }
            
            // Add response body
            if let bodyString = String(data: data, encoding: .utf8) {
                let truncated = String(bodyString.prefix(2000))
                output += "\n\nResponse body:\n\(truncated)"
                if bodyString.count > 2000 {
                    output += "\n... (truncated, \(bodyString.count) total chars)"
                }
            } else {
                output += "\n\nResponse: \(data.count) bytes (non-text)"
            }
            
            return .success(output)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure("Request timed out after \(AgentSettings.shared.httpRequestTimeout)s")
            case .cannotConnectToHost:
                return .failure("Cannot connect to host. Is the server running?")
            case .networkConnectionLost:
                return .failure("Network connection lost")
            default:
                return .failure("Request failed: \(error.localizedDescription)")
            }
        } catch {
            return .failure("Request failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Shell Command Tool

/// Executes shell commands in the user's terminal PTY
/// This tool delegates to a ShellCommandExecutor (typically ChatSession) for actual execution
final class ShellCommandTool: AgentTool {
    let name = "shell"
    let description = "Execute a shell command in the user's terminal. Environment changes (cd, source, export) persist. Args: command (required), timeout (optional - seconds to wait for output)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Execute a shell command in the user's terminal. Environment changes (cd, source, export) persist in the session.",
            parameters: [
                ToolParameter(name: "command", type: .string, description: "Shell command to execute", required: true),
                ToolParameter(name: "timeout", type: .integer, description: "Seconds to wait for command output (default: 300, use higher for long builds/tests)", required: false)
            ]
        )
    }
    
    /// Weak reference to the executor (set by ChatSession when starting agent mode)
    weak var executor: ShellCommandExecutor?
    
    init(executor: ShellCommandExecutor? = nil) {
        self.executor = executor
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let command = args["command"], !command.isEmpty else {
            return .failure("Missing required argument: command")
        }
        
        guard let executor = executor else {
            return .failure("Shell command executor not configured. This is an internal error.")
        }
        
        // Parse optional timeout (nil uses default from settings)
        let timeout: TimeInterval? = args["timeout"].flatMap { Double($0) }
        
        // Execute through the session's terminal
        let result = await executor.executeShellCommand(command, requireApproval: AgentSettings.shared.requireCommandApproval, timeout: timeout)
        
        if result.success {
            var output = result.output
            if output.isEmpty {
                output = "(command completed with no output, exit code: \(result.exitCode))"
            }
            return .success(output)
        } else {
            let errorMsg = result.output.isEmpty 
                ? "Command failed with exit code \(result.exitCode)" 
                : "Command failed (exit \(result.exitCode)): \(result.output)"
            return .failure(errorMsg)
        }
    }
}

// MARK: - Create Plan Tool (Navigator Mode)

/// Protocol for handling plan creation from Navigator mode
@MainActor
protocol CreatePlanDelegate: AnyObject {
    /// Create a new implementation plan
    /// - Parameters:
    ///   - title: The plan title
    ///   - content: The markdown content with implementation checklist
    /// - Returns: The created plan ID
    func createPlan(title: String, content: String) async -> UUID
}

/// Tool for creating implementation plans in Navigator mode
final class CreatePlanTool: AgentTool {
    let name = "create_plan"
    let description = "Create an implementation plan. Use after exploring codebase and clarifying requirements with the user."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create an implementation plan. Structure: 1) Summary, 2) Phases with context (NO checkboxes), 3) Technical notes, 4) Final flat checklist of high-level objectives at the end.",
            parameters: [
                ToolParameter(name: "title", type: .string, description: "Clear, descriptive title for the plan (e.g., 'Add User Authentication System')", required: true),
                ToolParameter(name: "content", type: .string, description: "Markdown content with phases/context first (no checkboxes), then a single flat checklist at the end with high-level objectives using - [ ] syntax", required: true)
            ]
        )
    }
    
    /// Weak reference to the delegate (set by ChatSession when in Navigator mode)
    weak var delegate: CreatePlanDelegate?
    
    init(delegate: CreatePlanDelegate? = nil) {
        self.delegate = delegate
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let delegate = delegate else {
            return .failure("Create plan delegate not configured. This is an internal error.")
        }
        
        guard let title = args["title"], !title.isEmpty else {
            return .failure("Missing required argument: title. Provide a clear, descriptive title for the plan.")
        }
        
        guard let content = args["content"], !content.isEmpty else {
            return .failure("Missing required argument: content. Provide the full markdown plan with implementation checklist.")
        }
        
        // Validate content has checklist items
        let hasChecklist = content.contains("- [ ]") || content.contains("- [x]")
        if !hasChecklist {
            return .failure("Plan content must include a checklist with '- [ ]' items. Please restructure the plan with actionable checklist items.")
        }
        
        // Create the plan through the delegate
        let planId = await delegate.createPlan(title: title, content: content)
        
        return .success("""
            ✅ PLAN CREATED SUCCESSFULLY
            
            Plan ID: \(planId.uuidString)
            Title: \(title)
            
            Your work as Navigator is complete. STOP HERE.
            
            The user will now review the plan and can:
            - View the full plan
            - Build with Copilot (file operations only)
            - Build with Pilot (full shell access)
            
            Do not create any more plans or continue exploring.
            """)
    }
}

// MARK: - Plan and Track Tool

/// Tool for setting goals and managing task checklists during agent execution
/// The agent calls this at the start of complex tasks to establish a plan
final class PlanAndTrackTool: AgentTool {
    let name = "plan_and_track"
    let description = "CALL THIS FIRST to set a goal and create a task checklist. Essential for multi-step work. Also use to mark tasks complete."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "IMPORTANT: Call this FIRST before starting any multi-step work. Sets your goal and creates a trackable task checklist. Also use to mark tasks as complete when done. Only skip for trivial single-command requests.",
            parameters: [
                ToolParameter(name: "goal", type: .string, description: "Clear, actionable goal statement (required when setting up a new plan)", required: false),
                ToolParameter(name: "tasks", type: .string, description: "JSON array of task descriptions, e.g. [\"task 1\", \"task 2\"]. Break work into 3-7 concrete steps.", required: false),
                ToolParameter(name: "start_task", type: .integer, description: "Task ID to mark as in-progress (1-based)", required: false),
                ToolParameter(name: "complete_task", type: .integer, description: "Task ID to mark complete (1-based). Call this after finishing each task.", required: false),
                ToolParameter(name: "task_note", type: .string, description: "Optional note for the completed task", required: false)
            ]
        )
    }
    
    /// Weak reference to the delegate (set by ChatSession when starting agent mode)
    weak var delegate: PlanTrackDelegate?
    
    init(delegate: PlanTrackDelegate? = nil) {
        self.delegate = delegate
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let delegate = delegate else {
            return .failure("Plan tracking delegate not configured. This is an internal error.")
        }
        
        // Check if this is a start_task operation (marking task as in-progress)
        if let startTaskStr = args["start_task"], let taskId = Int(startTaskStr) {
            await delegate.markTaskInProgress(id: taskId)
            
            // Return current status
            if let status = await delegate.getChecklistStatus() {
                return .success("Started task \(taskId).\n\nCurrent checklist:\n\(status)")
            } else {
                return .success("Started task \(taskId).")
            }
        }
        
        // Check if this is a complete_task operation
        if let completeTaskStr = args["complete_task"], let taskId = Int(completeTaskStr) {
            let note = args["task_note"]
            
            await delegate.markTaskComplete(id: taskId, note: note)
            
            // Return current status
            if let status = await delegate.getChecklistStatus() {
                return .success("Marked task \(taskId) complete.\n\nCurrent checklist:\n\(status)")
            } else {
                return .success("Marked task \(taskId) complete.")
            }
        }
        
        // This is a setup operation - need a goal
        guard let goal = args["goal"], !goal.isEmpty else {
            return .failure("Missing required argument: goal. Provide a clear, actionable goal statement.")
        }
        
        // Parse tasks array if provided (comes as JSON string)
        var taskList: [String]? = nil
        if let tasksJson = args["tasks"], !tasksJson.isEmpty {
            // Try to parse as JSON array
            if let data = tasksJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                taskList = parsed
            } else {
                // If not valid JSON array, try splitting by newlines or commas
                let cleaned = tasksJson.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if cleaned.contains("\n") {
                    taskList = cleaned.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else if cleaned.contains(",") {
                    taskList = cleaned.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) }
                        .filter { !$0.isEmpty }
                }
            }
        }
        
        await delegate.setGoalAndTasks(goal: goal, tasks: taskList)
        
        // Build response
        var response = "Goal set: \(goal)"
        if let tasks = taskList, !tasks.isEmpty {
            response += "\n\nTask checklist created with \(tasks.count) items:"
            for (idx, task) in tasks.enumerated() {
                response += "\n  \(idx + 1). \(task)"
            }
        }
        
        return .success(response)
    }
}

