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

// MARK: - Requires Approval Protocol

/// A tool that always requires user approval before execution
protocol RequiresApprovalTool: AgentTool {
    /// This tool always requires user approval, regardless of settings
    var alwaysRequiresApproval: Bool { get }
}

extension RequiresApprovalTool {
    var alwaysRequiresApproval: Bool { true }
}

// MARK: - Create Plan Delegate Protocol

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
