import SwiftUI

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
    @Published var currentWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var lastExitCode: Int32 = 0
    // Controls whether to perform heavy buffer processing on terminal updates
    @Published var captureActive: Bool = false
    // Theme selection id, used to apply a preset theme to the terminal view
    @Published var themeId: String = "system"
    // Agent helpers
    var markNextOutputStart: (() -> Void)?
    @Published var lastSentCommandForCapture: String? = nil
    
    // Keep a reference to the terminal view for cleanup
    fileprivate weak var terminalView: BridgedLocalProcessTerminalView?
    
    deinit {
        // Send exit command to the shell process when PTYModel is deallocated
        terminalView?.terminateShell()
    }
    
    func terminateProcess() {
        terminalView?.terminateShell()
    }
}

#if canImport(SwiftTerm)
import SwiftTerm

private final class BridgedLocalProcessTerminalView: LocalProcessTerminalView {
    weak var bridgeModel: PTYModel?
    
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
        // Send exit command to the shell
        self.send(txt: "exit\n")
        // Give it a moment to process, then force terminate if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If process is still running after exit command, we can't force it
            // since we don't have access to the internal process variable
            // The exit command should handle most cases
        }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        let selection = self.getSelection() ?? ""
        // Update lightweight state immediately without heavy buffer copies
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let model = self.bridgeModel else { return }
            model.hasSelection = !selection.isEmpty
            model.visibleRows = self.terminal.rows
        }
        // Only perform heavy buffer processing when actively capturing command output
        guard let model = bridgeModel, (model.captureActive || model.lastSentCommandForCapture != nil) else { return }
        let data = self.getTerminal().getBufferAsData()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let model = self.bridgeModel else { return }
            // Determine last output chunk
            var newChunk = ""
            if let start = model.lastOutputStartOffset, start <= text.count {
                let idx = text.index(text.startIndex, offsetBy: start)
                newChunk = String(text[idx...])
            }
            var trimmedChunk = Self.trimPrompt(from: newChunk)
            if let lastCmd = model.lastSentCommandForCapture, !lastCmd.isEmpty {
                trimmedChunk = Self.trimEcho(of: lastCmd, from: trimmedChunk)
            }
            // Extract and remove both exit code and cwd markers if present
            let rcProcessed = Self.stripExitCodeMarker(from: trimmedChunk)
            trimmedChunk = rcProcessed.cleaned
            if let rc = rcProcessed.code { model.lastExitCode = rc }
            let cwdProcessed = Self.stripCwdMarker(from: trimmedChunk)
            trimmedChunk = cwdProcessed.cleaned
            if let cwd = cwdProcessed.cwd, !cwd.isEmpty {
                model.currentWorkingDirectory = cwd
            }
            if !trimmedChunk.isEmpty {
                model.lastOutputChunk = trimmedChunk
                // Also compute line range based on viewport start
                if let startRow = model.lastOutputStartViewportRow {
                    let rows = self.terminal.rows
                    let chunkLines = trimmedChunk.split(separator: "\n", omittingEmptySubsequences: false).count
                    model.lastOutputLineRange = (start: max(0, startRow), end: min(rows - 1, max(0, startRow + chunkLines - 1)))
                }
            }
            model.previousBuffer = text
            model.collectedOutput = text
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // When user presses Enter (\r or \n), mark buffer offset as the start of next output
        if data.contains(10) || data.contains(13) { // \n or \r
            markOutputStart()
        }
        super.send(source: source, data: data)
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
            (term as? BridgedLocalProcessTerminalView)?.markOutputStart()
        }
        // Start shell in user's home directory by injecting cd via login shell
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let escaped = home.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "cd \"\(escaped)\"; exec /bin/zsh -l"
        term.startProcess(executable: "/bin/zsh", args: ["-lc", cmd])
        // Apply initial theme
        if let theme = TerminalTheme.presets.first(where: { $0.id == model.themeId }) ?? TerminalTheme.presets.first {
            term.apply(theme: theme)
        }
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if let theme = TerminalTheme.presets.first(where: { $0.id == model.themeId }) ?? TerminalTheme.presets.first {
            nsView.apply(theme: theme)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate, TerminalViewDelegate {
        let model: PTYModel
        init(model: PTYModel) { self.model = model }

        // LocalProcessTerminalViewDelegate
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}

        // TerminalViewDelegate (unused here, but kept for future use)
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let dir = directory, !dir.isEmpty else { return }
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



