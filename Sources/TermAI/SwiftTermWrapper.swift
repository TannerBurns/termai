import SwiftUI
import os.log

private let ptyLogger = Logger(subsystem: "com.termai.app", category: "PTY")

final class PTYModel: ObservableObject {
    @Published var collectedOutput: String = ""
    // Closures set by the SwiftTerm wrapper to provide selection and screen text
    var getSelectionText: (() -> String?)?
    var getScreenText: (() -> String)?
    // Closure set by the SwiftTerm wrapper to allow programmatic input from UI
    var sendInput: ((String) -> Void)?
    @Published var hasSelection: Bool = false
    @Published var lastOutputChunk: String = ""
    fileprivate var previousBuffer: String = ""
    fileprivate var lastOutputStartOffset: Int? = nil
    @Published var lastOutputStartViewportRow: Int? = nil
    @Published var visibleRows: Int = 0
    @Published var lastOutputLineRange: (start: Int, end: Int)? = nil
    @Published var currentWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path {
        didSet {
            if currentWorkingDirectory != oldValue {
                NSLog("[PTY] CWD CHANGED: '%@' → '%@'", oldValue, currentWorkingDirectory)
                refreshGitInfo()
            }
        }
    }
    @Published var lastExitCode: Int32 = 0
    // Controls whether to perform heavy buffer processing on terminal updates
    @Published var captureActive: Bool = false
    // Theme selection id, used to apply a preset theme to the terminal view
    @Published var themeId: String = "system"
    // Agent helpers
    var markNextOutputStart: (() -> Void)?
    @Published var lastSentCommandForCapture: String? = nil
    
    /// Indicates that the terminal shell has finished initial startup and is ready
    /// This triggers startup suggestions
    @Published var didFinishInitialLoad: Bool = false
    
    /// Track the last command sent by the user (for history recording)
    @Published var lastUserCommand: String? = nil
    
    /// Callback invoked when command completion marker (__TERMAI_RC__) is detected
    /// This provides event-driven notification instead of relying on timer-based capture
    var onCommandCompletion: (() -> Void)?
    
    /// Timeout task for command completion (fallback if marker not detected)
    private var commandTimeoutTask: DispatchWorkItem?
    private let commandTimeout: TimeInterval = 30.0  // 30 second fallback
    
    /// Start waiting for command completion with timeout fallback
    func startCommandCapture() {
        // Cancel any existing timeout
        commandTimeoutTask?.cancel()
        
        // Set up timeout fallback
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.captureActive else { return }
            // Timeout reached, trigger completion anyway
            self.onCommandCompletion?()
        }
        commandTimeoutTask = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + commandTimeout, execute: timeoutItem)
    }
    
    /// Signal that command has completed (marker was detected)
    fileprivate func signalCommandCompletion() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        onCommandCompletion?()
    }
    
    // Git integration
    @Published var gitInfo: GitInfo? = nil
    private var gitRefreshTask: Task<Void, Never>? = nil
    private var gitDebounceWorkItem: DispatchWorkItem? = nil
    private let gitDebounceInterval: TimeInterval = 0.5  // 500ms debounce
    
    // Keep a reference to the terminal view for cleanup
    fileprivate weak var terminalView: BridgedLocalProcessTerminalView?
    
    deinit {
        // Cancel any pending git refresh tasks to prevent updates to deallocated object
        gitRefreshTask?.cancel()
        gitDebounceWorkItem?.cancel()
        commandTimeoutTask?.cancel()
        
        // Send exit command to the shell process when PTYModel is deallocated
        terminalView?.terminateShell()
    }
    
    func terminateProcess() {
        terminalView?.terminateShell()
    }
    
    /// Refresh Git info for the current working directory (debounced by 500ms)
    func refreshGitInfo() {
        // Cancel any pending debounce and existing task
        gitDebounceWorkItem?.cancel()
        gitRefreshTask?.cancel()
        
        // Capture path BEFORE the debounce to avoid race conditions
        // This ensures we know exactly which path triggered this refresh
        let capturedPath = self.currentWorkingDirectory
        
        // Debounce to avoid excessive git operations during rapid directory changes
        let workItem = DispatchWorkItem { [weak self, capturedPath] in
            guard let self = self else { return }
            // Re-check if the directory is still the one we wanted (may have changed during debounce)
            guard self.currentWorkingDirectory == capturedPath else { return }
            
            self.gitRefreshTask = Task { @MainActor [weak self, capturedPath] in
                guard let self = self else { return }
                let info = await GitInfoService.shared.fetchGitInfo(for: capturedPath)
                // Only update if we're still looking at the same directory after async fetch
                if !Task.isCancelled && self.currentWorkingDirectory == capturedPath {
                    self.gitInfo = info
                }
            }
        }
        gitDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + gitDebounceInterval, execute: workItem)
    }
}

#if canImport(SwiftTerm)
import SwiftTerm

private final class BridgedLocalProcessTerminalView: LocalProcessTerminalView {
    weak var bridgeModel: PTYModel?
    
    // Debounce timer for non-agent buffer processing
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.25  // 250ms debounce for reduced CPU usage
    
    // Track if we've detected initial shell ready state
    private var hasDetectedInitialPrompt: Bool = false
    
    // Buffer to track what user is typing (for command history)
    private var currentInputBuffer: String = ""
    
    func markOutputStart() {
        let buffer = self.getTerminal().getBufferAsData()
        let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) ?? ""
        bridgeModel?.previousBuffer = text
        bridgeModel?.lastOutputStartOffset = text.count
        // Track viewport row for alignment
        let absRow = self.terminal.buffer.y
        let viewportRow = absRow - self.terminal.buffer.yDisp
        bridgeModel?.lastOutputStartViewportRow = viewportRow
    }
    
    func terminateShell() {
        // Send exit command to the shell for graceful shutdown
        self.send(txt: "exit\n")
        // Give it a moment to process, then force terminate if still running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // Use the internal process property's terminate method (sends SIGTERM)
            if self.process.running {
                self.process.terminate()
            }
        }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        let selection = self.getSelection() ?? ""
        guard let model = bridgeModel else { return }
        
        // Always get the terminal buffer for last output tracking
        let data = self.getTerminal().getBufferAsData()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        
        let isAgentCapture = model.captureActive || model.lastSentCommandForCapture != nil
        
        // For agent mode, process immediately without debounce
        if isAgentCapture {
            processBufferUpdate(selection: selection, text: text, isAgentCapture: true)
        } else {
            // For normal use, debounce the heavy processing
            // Always extract CWD to enable real-time directory tracking via OSC 7
            debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.processBufferUpdate(selection: selection, text: text, isAgentCapture: false)
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
        }
    }
    
    private func processBufferUpdate(selection: String, text: String, isAgentCapture: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let model = self.bridgeModel else { return }
            
            // Update lightweight state
            model.hasSelection = !selection.isEmpty
            model.visibleRows = self.terminal.rows
            
            // Always extract CWD from buffer for real-time directory tracking
            // OSC 7 sequences emitted by precmd will be captured here
            if let extractedCwd = Self.extractCwdFromBuffer(text) {
                NSLog("[PTY] extractCwdFromBuffer found: %@", extractedCwd)
                model.currentWorkingDirectory = extractedCwd
            }
            
            // Detect initial shell ready state (first prompt detected)
            if !self.hasDetectedInitialPrompt && !model.didFinishInitialLoad {
                // Look for a prompt in the buffer
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for line in lines.reversed().prefix(5) {
                    if Self.looksLikePrompt(line) {
                        self.hasDetectedInitialPrompt = true
                        // Small delay to ensure CWD and git info are populated
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            model.didFinishInitialLoad = true
                        }
                        break
                    }
                }
            }
            
            // Always compute last output chunk for the "Add Last Output" button
            var newChunk = ""
            if let start = model.lastOutputStartOffset, start < text.count {
                let idx = text.index(text.startIndex, offsetBy: start)
                newChunk = String(text[idx...])
            }
            
            // For normal use, just clean up the output minimally
            var trimmedChunk = Self.cleanOutput(from: newChunk)
            
            // Only do agent-specific processing (echo trim, marker extraction) when in capture mode
            if isAgentCapture {
                if let lastCmd = model.lastSentCommandForCapture, !lastCmd.isEmpty {
                    trimmedChunk = Self.trimEcho(of: lastCmd, from: trimmedChunk)
                }
                // Extract and remove both exit code and cwd markers if present
                let rcProcessed = Self.stripExitCodeMarker(from: trimmedChunk)
                trimmedChunk = rcProcessed.cleaned
                let exitCodeDetected = rcProcessed.code != nil
                if let rc = rcProcessed.code { model.lastExitCode = rc }
                let cwdProcessed = Self.stripCwdMarker(from: trimmedChunk)
                trimmedChunk = cwdProcessed.cleaned
                if let cwd = cwdProcessed.cwd, !cwd.isEmpty {
                    model.currentWorkingDirectory = cwd
                }
                model.previousBuffer = text
                model.collectedOutput = text
                
                // Signal command completion when exit code marker is detected
                // This triggers the event-driven capture instead of relying on a timer
                if exitCodeDetected {
                    model.signalCommandCompletion()
                }
            }
            
            // Always update lastOutputChunk for UI buttons (keep raw if cleaned is empty)
            let finalChunk = trimmedChunk.isEmpty ? newChunk.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedChunk
            if !finalChunk.isEmpty {
                model.lastOutputChunk = finalChunk
                // Also compute line range based on viewport start
                if let startRow = model.lastOutputStartViewportRow {
                    let rows = self.terminal.rows
                    let chunkLines = finalChunk.split(separator: "\n", omittingEmptySubsequences: false).count
                    model.lastOutputLineRange = (start: max(0, startRow), end: min(rows - 1, max(0, startRow + chunkLines - 1)))
                }
            }
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Track typed characters for command history
        for byte in data {
            if byte == 10 || byte == 13 { // \n or \r (Enter)
                // User pressed Enter - capture the current command
                let command = currentInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    bridgeModel?.lastUserCommand = command
                    
                    // Detect cd commands and update CWD after execution
                    if command.hasPrefix("cd ") || command == "cd" {
                        scheduleCwdUpdate(for: command)
                    }
                }
                currentInputBuffer = ""
                markOutputStart()
            } else if byte == 127 || byte == 8 { // Backspace or Delete
                if !currentInputBuffer.isEmpty {
                    currentInputBuffer.removeLast()
                }
            } else if byte == 21 { // Ctrl+U (clear line)
                currentInputBuffer = ""
            } else if byte == 23 { // Ctrl+W (delete word)
                // Remove last word
                while !currentInputBuffer.isEmpty && currentInputBuffer.last != " " {
                    currentInputBuffer.removeLast()
                }
                while !currentInputBuffer.isEmpty && currentInputBuffer.last == " " {
                    currentInputBuffer.removeLast()
                }
            } else if byte >= 32 && byte < 127 { // Printable ASCII
                currentInputBuffer.append(Character(UnicodeScalar(byte)))
            }
        }
        super.send(source: source, data: data)
    }

    /// Schedule a CWD update after a cd command executes
    private func scheduleCwdUpdate(for command: String) {
        guard let model = bridgeModel else { return }
        let currentCWD = model.currentWorkingDirectory
        
        // Parse the cd target
        var cdTarget = command.hasPrefix("cd ") ? String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
        
        // Handle quoted paths
        if (cdTarget.hasPrefix("\"") && cdTarget.hasSuffix("\"")) ||
           (cdTarget.hasPrefix("'") && cdTarget.hasSuffix("'")) {
            cdTarget = String(cdTarget.dropFirst().dropLast())
        }
        
        // Empty cd goes to home
        if cdTarget.isEmpty {
            cdTarget = "~"
        }
        
        // Schedule update after command executes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak model, currentCWD, cdTarget] in
            guard let model = model else { return }
            
            // Resolve the target path
            let resolvedPath: String
            if cdTarget.hasPrefix("~") {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                resolvedPath = home + cdTarget.dropFirst()
            } else if cdTarget.hasPrefix("/") {
                resolvedPath = cdTarget
            } else if cdTarget == "-" {
                // cd - goes to previous directory, skip manual update (we can't track this)
                return
            } else if cdTarget == ".." {
                resolvedPath = (currentCWD as NSString).deletingLastPathComponent
            } else if cdTarget.hasPrefix("..") {
                // Handle paths like ../foo or ../../bar
                resolvedPath = (currentCWD as NSString).appendingPathComponent(cdTarget)
            } else {
                // Relative path
                resolvedPath = (currentCWD as NSString).appendingPathComponent(cdTarget)
            }
            
            // Normalize the path
            let normalizedPath = (resolvedPath as NSString).standardizingPath
            
            // Verify the directory exists before updating
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDir), isDir.boolValue {
                ptyLogger.info("CD detected: updating CWD from '\(currentCWD, privacy: .public)' to '\(normalizedPath, privacy: .public)'")
                model.currentWorkingDirectory = normalizedPath
            } else {
                ptyLogger.warning("CD target doesn't exist or isn't a directory: \(normalizedPath, privacy: .public)")
            }
        }
    }
    
    /// Extract CWD from terminal buffer by looking for common prompt patterns
    private static func extractCwdFromBuffer(_ buffer: String) -> String? {
        // Look for the last line that looks like a prompt with a path
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Common prompt patterns: "user@host:~/path$" or "~/path %"
            // Look for ~ or / followed by path characters before $ or %
            if let match = trimmed.range(of: #"[~\/][^\s$%#]*"#, options: .regularExpression) {
                let path = String(trimmed[match])
                
                // Validate: reject paths containing invalid filesystem characters
                // These could appear in echoed content (e.g., markdown: **aioboto3/aiobotocore**)
                let invalidPathChars = CharacterSet(charactersIn: "*?\"<>|")
                if path.unicodeScalars.contains(where: { invalidPathChars.contains($0) }) {
                    continue
                }
                
                // Reject paths that are too short (single / is not a valid detection)
                // or that look like URL fragments (contain ://)
                if path.count < 2 || path.contains("://") {
                    continue
                }
                
                // Expand ~ to home directory and validate path exists
                var expandedPath = path
                if path.hasPrefix("~") {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    expandedPath = home + path.dropFirst()
                }
                
                // Only return paths that actually exist on the filesystem
                // This prevents false positives from partial paths in terminal output
                if expandedPath.hasPrefix("/") {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                        return expandedPath
                    }
                    // Path doesn't exist, continue searching
                    continue
                }
            }
            
            // Also try to match OSC sequences that set working directory
            // Format: \x1b]7;file://hostname/path\x07 or \x1b]7;file:///path\x07
            if let oscRange = trimmed.range(of: #"\x1b\]7;file://[^\x07]*\x07"#, options: .regularExpression) {
                let oscContent = String(trimmed[oscRange])
                if let pathStart = oscContent.range(of: "file://")?.upperBound {
                    var pathPart = String(oscContent[pathStart...])
                    // Remove trailing bell character
                    pathPart = pathPart.replacingOccurrences(of: "\u{07}", with: "")
                    // Skip hostname if present (look for second /)
                    if !pathPart.hasPrefix("/") {
                        if let slashIdx = pathPart.firstIndex(of: "/") {
                            pathPart = String(pathPart[slashIdx...])
                        }
                    }
                    if !pathPart.isEmpty {
                        // URL decode the path
                        return pathPart.removingPercentEncoding ?? pathPart
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Clean output without being too aggressive - just remove trailing prompt lines
    private static func cleanOutput(from chunk: String) -> String {
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        // Remove trailing empty lines and prompt lines
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            // Only remove if it's clearly a prompt or empty
            if t.isEmpty {
                lines.removeLast()
            } else if Self.looksLikePrompt(t) {
                lines.removeLast()
            } else {
                break
            }
        }
        
        // Remove leading empty lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Check if a line looks like a shell prompt
    private static func looksLikePrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Common prompt endings
        if trimmed.hasSuffix("$") || trimmed.hasSuffix("%") || trimmed.hasSuffix("#") ||
           trimmed.hasSuffix("$ ") || trimmed.hasSuffix("% ") || trimmed.hasSuffix("# ") {
            // Make sure it's not just output that happens to end with these
            // Prompts typically have user@host or path patterns
            if trimmed.contains("@") || trimmed.contains("~") || trimmed.contains(":") {
                return true
            }
            // Short lines ending with prompt chars are likely prompts
            if trimmed.count < 80 {
                return true
            }
        }
        return false
    }
    
    private static func trimPrompt(from chunk: String) -> String {
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasSuffix("$") || t.hasSuffix("%") || t.hasSuffix("#") || t.hasSuffix("$ ") || t.hasSuffix("% ") || t.hasSuffix("# ") {
                lines.removeLast()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attempts to remove the echoed command from the start of the chunk, tolerating terminal line wraps
    private static func trimEcho(of command: String, from chunk: String) -> String {
        guard !command.isEmpty, !chunk.isEmpty else { return chunk }
        
        // First try to find where the command echo ends (it might be wrapped or truncated)
        // Look for the command text in the chunk, allowing for line breaks
        let commandChars = Array(command)
        let chunkChars = Array(chunk)
        var matchEnd = 0
        var cmdIdx = 0
        var chunkIdx = 0
        
        while chunkIdx < chunkChars.count && cmdIdx < commandChars.count {
            let ch = chunkChars[chunkIdx]
            
            // Skip ANSI escape sequences
            if ch == "\u{001B}" && chunkIdx + 1 < chunkChars.count && chunkChars[chunkIdx + 1] == "[" {
                chunkIdx += 2
                while chunkIdx < chunkChars.count {
                    let c = chunkChars[chunkIdx]
                    chunkIdx += 1
                    if c >= "@" && c <= "~" { break }
                }
                continue
            }
            
            // Skip newlines/carriage returns in the chunk
            if ch == "\n" || ch == "\r" {
                chunkIdx += 1
                continue
            }
            
            // Try to match command character
            if ch == commandChars[cmdIdx] {
                chunkIdx += 1
                cmdIdx += 1
                matchEnd = chunkIdx
            } else if cmdIdx == 0 {
                // Haven't started matching yet, skip this character
                chunkIdx += 1
            } else {
                // Was matching but stopped - might be truncated, accept what we have
                break
            }
        }
        
        // If we matched at least some of the command, trim it
        if matchEnd > 0 {
            // Skip any trailing newline after the command
            while matchEnd < chunkChars.count && (chunkChars[matchEnd] == "\n" || chunkChars[matchEnd] == "\r") {
                matchEnd += 1
            }
            let result = String(chunkChars[matchEnd...])
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return chunk
    }

    private static func stripExitCodeMarker(from chunk: String) -> (cleaned: String, code: Int32?) {
        guard !chunk.isEmpty else { return (chunk, nil) }
        let marker = "__TERMAI_RC__="
        guard let r = chunk.range(of: marker, options: .backwards) else { return (chunk, nil) }
        var idx = r.upperBound
        var numStr = ""
        while idx < chunk.endIndex, chunk[idx].isNumber || chunk[idx] == "-" {
            numStr.append(chunk[idx])
            idx = chunk.index(after: idx)
        }
        let code = Int32(numStr)
        // Remove the marker and any trailing newline
        var lineStart = r.lowerBound
        while lineStart > chunk.startIndex {
            let prev = chunk.index(before: lineStart)
            if chunk[prev] == "\n" || chunk[prev] == "\r" { break }
            lineStart = prev
        }
        var lineEnd = idx
        if lineEnd < chunk.endIndex, chunk[lineEnd] == "\n" || chunk[lineEnd] == "\r" {
            lineEnd = chunk.index(after: lineEnd)
        }
        let cleaned = chunk.replacingCharacters(in: lineStart..<lineEnd, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, code)
    }

    private static func stripCwdMarker(from chunk: String) -> (cleaned: String, cwd: String?) {
        guard !chunk.isEmpty else { return (chunk, nil) }
        let marker = "__TERMAI_CWD__="
        guard let r = chunk.range(of: marker, options: .backwards) else { return (chunk, nil) }
        var idx = r.upperBound
        var path = ""
        while idx < chunk.endIndex {
            let c = chunk[idx]
            if c == "\n" || c == "\r" { break }
            path.append(c)
            idx = chunk.index(after: idx)
        }
        // Remove the marker line
        var lineStart = r.lowerBound
        while lineStart > chunk.startIndex {
            let prev = chunk.index(before: lineStart)
            if chunk[prev] == "\n" || chunk[prev] == "\r" { break }
            lineStart = prev
        }
        var lineEnd = idx
        if lineEnd < chunk.endIndex, chunk[lineEnd] == "\n" || chunk[lineEnd] == "\r" {
            lineEnd = chunk.index(after: lineEnd)
        }
        let cleaned = chunk.replacingCharacters(in: lineStart..<lineEnd, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, path)
    }
}

struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var model: PTYModel

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = BridgedLocalProcessTerminalView(frame: .zero)
        term.bridgeModel = model
        term.processDelegate = context.coordinator
        term.notifyUpdateChanges = true
        // Store terminal reference for cleanup (as BridgedLocalProcessTerminalView)
        model.terminalView = term
        // Keep default scrollback; do not reset buffer to avoid disrupting input/echo
        // Wire helpers for selection/screen text
        model.getSelectionText = { [weak term] in
            term?.getSelection()
        }
        model.getScreenText = { [weak term] in
            guard let term else { return "" }
            let data = term.getTerminal().getBufferAsData()
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        // Wire programmatic input sender
        model.sendInput = { [weak term] text in
            term?.send(txt: text)
        }
        // Provide a helper for marking where the next output begins for programmatic commands
        model.markNextOutputStart = { [weak term] in
            term?.markOutputStart()
        }
        // Build environment with color support enabled
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"     // Full color support
        env["CLICOLOR"] = "1"              // Enable colors for ls, etc.
        env["CLICOLOR_FORCE"] = "1"        // Force colors even if not a TTY
        env["COLORTERM"] = "truecolor"     // Indicate true color support
        env["LSCOLORS"] = "GxFxCxDxBxegedabagaced"  // macOS ls colors
        env["LS_COLORS"] = "di=1;36:ln=1;35:so=1;32:pi=1;33:ex=1:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=34;43"  // GNU ls colors
        
        // Start login shell directly (without exec, which would destroy our precmd setup)
        let envArray = env.map { "\($0.key)=\($0.value)" }
        term.startProcess(executable: "/bin/zsh", args: ["-l"], environment: envArray)
        
        // Inject precmd hook after shell starts to enable OSC 7 CWD tracking
        // This MUST happen after startProcess, not via -c flag, because:
        // 1. Using exec /bin/zsh -l would replace the shell and lose the precmd function
        // 2. Injecting via stdin ensures the hook exists in the interactive shell
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let escaped = home.replacingOccurrences(of: "\"", with: "\\\"")
        // The precmd function emits OSC 7 with the current working directory before each prompt
        // Format: ESC ] 7 ; file://hostname/path BEL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak term] in
            guard let term = term else { return }
            // Define precmd hook and add to precmd_functions array, then cd to home
            let precmdSetup = "__termai_precmd() { printf '\\e]7;file://%s%s\\a' \"$(hostname)\" \"$(pwd -P)\"; }; precmd_functions+=(__termai_precmd); cd \"\(escaped)\"; clear\n"
            term.send(txt: precmdSetup)
        }
        // Apply initial theme
        if let theme = TerminalTheme.presets.first(where: { $0.id == model.themeId }) ?? TerminalTheme.presets.first {
            term.apply(theme: theme)
        }
        // Fetch initial Git info for home directory
        model.refreshGitInfo()
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Only apply theme when it has changed
        let currentThemeId = model.themeId
        if context.coordinator.lastAppliedThemeId != currentThemeId {
            if let theme = TerminalTheme.presets.first(where: { $0.id == currentThemeId }) ?? TerminalTheme.presets.first {
                nsView.apply(theme: theme)
                context.coordinator.lastAppliedThemeId = currentThemeId
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate, TerminalViewDelegate {
        let model: PTYModel
        var lastAppliedThemeId: String? = nil
        
        init(model: PTYModel) { self.model = model }

        // LocalProcessTerminalViewDelegate
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}

        // TerminalViewDelegate (unused here, but kept for future use)
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            NSLog("[PTY] hostCurrentDirectoryUpdate called with: %@", directory ?? "nil")
            guard var dir = directory, !dir.isEmpty else { return }
            
            // Parse file:// URL to extract the actual path
            // OSC 7 sends format: file://hostname/path
            if dir.hasPrefix("file://") {
                var pathPart = String(dir.dropFirst(7)) // Remove "file://"
                // Skip hostname if present (find first / after hostname)
                if !pathPart.hasPrefix("/"), let slashIdx = pathPart.firstIndex(of: "/") {
                    pathPart = String(pathPart[slashIdx...])
                }
                // URL-decode the path (handles %20 for spaces, etc.)
                dir = pathPart.removingPercentEncoding ?? pathPart
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.model.currentWorkingDirectory = dir
            }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#else
struct SwiftTermView: View {
    @ObservedObject var model: PTYModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("SwiftTerm not available.")
                .font(.headline)
            Text("Open the package in Xcode and add the SwiftTerm dependency (HTTPS).Then rebuild.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
    }
}
#endif

#if canImport(SwiftTerm)
import SwiftTerm
extension PTYModel {
    func setCaretBlinkingEnabled(_ enabled: Bool) {
        terminalView?.getTerminal().setCursorStyle(enabled ? .blinkBlock : .steadyBlock)
    }
}
#endif



