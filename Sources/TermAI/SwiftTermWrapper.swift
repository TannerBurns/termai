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
    // Theme selection id, used to apply a preset theme to the terminal view
    @Published var themeId: String = "system"
    
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
        let data = self.getTerminal().getBufferAsData()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let model = self?.bridgeModel else { return }
            model.hasSelection = !selection.isEmpty
            model.visibleRows = self?.terminal.rows ?? model.visibleRows

            // Determine last output chunk
            var newChunk = ""
            if let start = model.lastOutputStartOffset, start <= text.count {
                let idx = text.index(text.startIndex, offsetBy: start)
                newChunk = String(text[idx...])
            }
            let trimmedChunk = Self.trimPrompt(from: newChunk)
            if !trimmedChunk.isEmpty {
                model.lastOutputChunk = trimmedChunk
                // Also compute line range based on viewport start
                if let startRow = model.lastOutputStartViewportRow, let rows = self?.terminal.rows {
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
            let buffer = self.getTerminal().getBufferAsData()
            let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) ?? ""
            bridgeModel?.previousBuffer = text
            bridgeModel?.lastOutputStartOffset = text.count
            // Track viewport row for alignment
            let absRow = self.terminal.buffer.y
            let viewportRow = absRow - self.terminal.buffer.yDisp
            bridgeModel?.lastOutputStartViewportRow = viewportRow
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



