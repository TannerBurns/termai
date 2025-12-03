import SwiftUI
import Combine

// MARK: - Test Runner Panel

/// Main panel for displaying test runner status and results
struct TestRunnerPanel: View {
    @ObservedObject var agent: TestRunnerAgent
    let onDismiss: () -> Void
    let onRerun: () -> Void
    let onRerunFailed: () -> Void
    let onRunFix: ((String) -> Void)?
    
    @Environment(\.colorScheme) var colorScheme
    @State private var showRawOutput = false
    @State private var expandedFiles: Set<String> = []
    
    init(agent: TestRunnerAgent, onDismiss: @escaping () -> Void, onRerun: @escaping () -> Void, onRerunFailed: @escaping () -> Void, onRunFix: ((String) -> Void)? = nil) {
        self.agent = agent
        self.onDismiss = onDismiss
        self.onRerun = onRerun
        self.onRerunFailed = onRerunFailed
        self.onRunFix = onRunFix
    }
    
    private var theme: TestRunnerTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content based on status
            contentView
            
            Divider()
            
            // Footer with actions
            footer
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(maxWidth: 900, maxHeight: 700)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: agent.status.icon)
                    .font(.system(size: 18))
                    .foregroundColor(statusColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Test Runner")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.foreground)
                
                Text(agent.status.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            
            Spacer()
            
            // Framework badge if known
            if let analysis = agent.analysisResult {
                HStack(spacing: 4) {
                    Image(systemName: analysis.framework.icon)
                        .font(.system(size: 10))
                    Text(analysis.framework.displayName)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.secondaryText.opacity(0.1))
                )
            }
            
            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.headerBackground)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.headerBackground)
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        switch agent.status {
        case .idle:
            idleView
        case .analyzing:
            analyzingView
        case .blocked(let blockers):
            blockedView(blockers: blockers)
        case .running(let progress):
            runningView(progress: progress)
        case .completed(let summary):
            completedView(summary: summary)
        case .failed(let error):
            failedView(error: error)
        case .cancelled:
            cancelledView
        }
    }
    
    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle")
                .font(.system(size: 48))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            
            Text("Ready to run tests")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var analyzingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Analyzing project structure...")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func blockedView(blockers: [TestBlocker]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Warning header
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Cannot run tests - \(blockers.count) issue\(blockers.count == 1 ? "" : "s") found")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.foreground)
                }
                .padding(.bottom, 8)
                
                // Blocker cards
                ForEach(blockers) { blocker in
                    BlockerCard(blocker: blocker, theme: theme, onRunFix: onRunFix)
                }
            }
            .padding(20)
        }
    }
    
    private func runningView(progress: TestRunProgress) -> some View {
        VStack(spacing: 20) {
            // Progress indicator
            if let percent = progress.progressPercent {
                VStack(spacing: 8) {
                    ProgressView(value: percent)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                    
                    Text(progress.progressDescription)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                
                Text(progress.progressDescription)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            
            // Current test
            if let currentTest = progress.currentTest {
                Text(currentTest)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
                    .lineLimit(1)
            }
            
            // Elapsed time
            Text(formatDuration(progress.elapsedTime))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.6))
            
            // Live output preview
            if !agent.currentOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    
                    ScrollView {
                        Text(String(agent.currentOutput.suffix(1000)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.foreground.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.background)
                    )
                }
                .padding(.horizontal, 20)
            }
            
            // Cancel button
            Button(action: { agent.cancel() }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func completedView(summary: TestRunSummary) -> some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar(summary: summary)
            
            // Analysis notes from LLM (if available)
            if !summary.analysisNotes.isEmpty {
                Divider()
                analysisNotesView(notes: summary.analysisNotes, isSuccess: summary.isSuccess)
            }
            
            Divider()
            
            // Toggle for raw output vs structured results
            Picker("View", selection: $showRawOutput) {
                Text("Results").tag(false)
                Text("Raw Output").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            
            Divider()
            
            // Content
            if showRawOutput {
                rawOutputView(output: summary.rawOutput)
            } else {
                resultsTreeView(summary: summary)
            }
        }
    }
    
    private func analysisNotesView(notes: String, isSuccess: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.purple)
                Text("Analysis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.foreground)
            }
            
            Text(notes)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSuccess ? Color.green.opacity(0.03) : Color.orange.opacity(0.05))
    }
    
    private func summaryBar(summary: TestRunSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // Status badge
                HStack(spacing: 6) {
                    Image(systemName: summary.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(summary.isSuccess ? .green : .red)
                    Text(summary.isSuccess ? "All tests passed" : "Some tests failed")
                        .font(.system(size: 13, weight: .medium))
                }
                
                Spacer()
                
                // Counts
                HStack(spacing: 12) {
                    countBadge(count: summary.passed, label: "passed", color: .green)
                    countBadge(count: summary.failed, label: "failed", color: .red)
                    if summary.skipped > 0 {
                        countBadge(count: summary.skipped, label: "skipped", color: .yellow)
                    }
                    if summary.errors > 0 {
                        countBadge(count: summary.errors, label: "errors", color: .orange)
                    }
                }
                
                // Duration
                Text(summary.durationText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            
            // Test scope indicator
            HStack(spacing: 6) {
                Image(systemName: summary.testScope.icon)
                    .font(.system(size: 10))
                Text(summary.testScope.displayName)
                    .font(.system(size: 11))
                
                if summary.testScope == .unitOnly {
                    Text("• Integration tests skipped")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                
                Spacer()
                
                Text(summary.framework.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }
            .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(summary.isSuccess ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
    }
    
    private func countBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundColor(color)
    }
    
    private func resultsTreeView(summary: TestRunSummary) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Show failures first, expanded by default
                let failedTests = summary.failedTests
                if !failedTests.isEmpty {
                    Section {
                        ForEach(failedTests) { result in
                            TestResultRow(result: result, theme: theme)
                        }
                    } header: {
                        SectionHeaderWithCopy(
                            title: "Failed Tests",
                            count: failedTests.count,
                            color: .red,
                            onCopy: { copyAllErrors(failedTests) }
                        )
                    }
                }
                
                // Group by file
                let resultsByFile = summary.resultsByFile
                ForEach(Array(resultsByFile.keys.sorted()), id: \.self) { file in
                    let fileResults = resultsByFile[file] ?? []
                    let isExpanded = expandedFiles.contains(file)
                    let hasFailed = fileResults.contains { $0.status == .failed || $0.status == .error }
                    
                    Button(action: { toggleFile(file) }) {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText)
                            
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                            
                            Text(file)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.foreground)
                            
                            Spacer()
                            
                            // File summary
                            let passed = fileResults.filter { $0.status == .passed }.count
                            let failed = fileResults.filter { $0.status == .failed || $0.status == .error }.count
                            
                            if failed > 0 {
                                Text("\(failed) failed")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                            }
                            if passed > 0 {
                                Text("\(passed) passed")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(hasFailed ? Color.red.opacity(0.05) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    
                    if isExpanded {
                        ForEach(fileResults) { result in
                            TestResultRow(result: result, theme: theme)
                                .padding(.leading, 24)
                        }
                    }
                    
                    Divider()
                }
            }
        }
    }
    
    private func rawOutputView(output: String) -> some View {
        VStack(spacing: 0) {
            // Copy button bar
            HStack {
                Spacer()
                Button(action: { copyToClipboard(output) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text("Copy Output")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(theme.background.opacity(0.8))
            
            Divider()
            
            ScrollView([.horizontal, .vertical]) {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(theme.background)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func copyAllErrors(_ failedTests: [TestResult]) {
        var errorText = "Failed Tests Summary\n"
        errorText += "====================\n\n"
        
        for (index, result) in failedTests.enumerated() {
            errorText += "[\(index + 1)] \(result.name)\n"
            if let file = result.file {
                errorText += "    File: \(file)"
                if let line = result.line {
                    errorText += ":\(line)"
                }
                errorText += "\n"
            }
            if let error = result.errorMessage {
                errorText += "    Error: \(error)\n"
            }
            if let stackTrace = result.stackTrace {
                errorText += "    Stack Trace:\n"
                for line in stackTrace.components(separatedBy: "\n") {
                    errorText += "        \(line)\n"
                }
            }
            errorText += "\n"
        }
        
        copyToClipboard(errorText)
    }
    
    private func failedView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
            Text("Test run failed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.foreground)
            
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 40)
            
            // Copy error button
            Button(action: { copyToClipboard(error) }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                    Text("Copy Error")
                        .font(.system(size: 12))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var cancelledView: some View {
        VStack(spacing: 16) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("Test run cancelled")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack(spacing: 12) {
            // Analysis notes
            if let analysis = agent.analysisResult, !analysis.analysisNotes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text(analysis.analysisNotes)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundColor(theme.secondaryText)
            }
            
            Spacer()
            
            // Action buttons based on status
            switch agent.status {
            case .completed(let summary):
                if !summary.failedTests.isEmpty {
                    Button(action: onRerunFailed) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10))
                            Text("Re-run Failed")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: onRerun) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Run All Tests")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                
            case .blocked, .failed, .cancelled, .idle:
                Button(action: onRerun) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Run Tests")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.headerBackground)
    }
    
    // MARK: - Helpers
    
    private var statusColor: Color {
        switch agent.status {
        case .idle: return .gray
        case .analyzing: return .blue
        case .blocked: return .orange
        case .running: return .blue
        case .completed(let summary): return summary.isSuccess ? .green : .red
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
    
    private func toggleFile(_ file: String) {
        if expandedFiles.contains(file) {
            expandedFiles.remove(file)
        } else {
            expandedFiles.insert(file)
        }
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            let minutes = Int(interval / 60)
            let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

// MARK: - Blocker Card

struct BlockerCard: View {
    let blocker: TestBlocker
    let theme: TestRunnerTheme
    let onRunFix: ((String) -> Void)?
    
    @State private var isRunningFix = false
    
    init(blocker: TestBlocker, theme: TestRunnerTheme, onRunFix: ((String) -> Void)? = nil) {
        self.blocker = blocker
        self.theme = theme
        self.onRunFix = onRunFix
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: blocker.kind.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                
                Text(blocker.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.foreground)
            }
            
            // Message
            Text(blocker.message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            
            // Suggestion
            if let suggestion = blocker.suggestion {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                    
                    Text(suggestion)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                }
            }
            
            // Command suggestion with Fix button
            if let command = blocker.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.background)
                        )
                    
                    Button(action: { copyToClipboard(command) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Copy command")
                    
                    Spacer()
                    
                    // Fix & Retry button
                    if let onRunFix = onRunFix {
                        Button(action: {
                            isRunningFix = true
                            onRunFix(command)
                        }) {
                            HStack(spacing: 4) {
                                if isRunningFix {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9))
                                }
                                Text(isRunningFix ? "Running..." : "Fix & Retry")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isRunningFix ? Color.gray : Color.green)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunningFix)
                        .help("Run this command and retry tests")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Test Result Row

struct TestResultRow: View {
    let result: TestResult
    let theme: TestRunnerTheme
    
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { 
                if result.errorMessage != nil || result.stackTrace != nil {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    // Status icon
                    Image(systemName: result.status.icon)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                    
                    // Test name
                    Text(result.name)
                        .font(.system(size: 12))
                        .foregroundColor(theme.foreground)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Duration
                    if let duration = result.duration {
                        Text(formatDuration(duration))
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    
                    // Expand indicator for failed tests
                    if result.errorMessage != nil || result.stackTrace != nil {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(result.status == .failed || result.status == .error ? Color.red.opacity(0.05) : Color.clear)
            }
            .buttonStyle(.plain)
            
            // Error details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = result.errorMessage {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    
                    if let stackTrace = result.stackTrace {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(stackTrace)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        if let fileRef = result.fileReference {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 9))
                                Text(fileRef)
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundColor(.accentColor)
                        }
                        
                        Spacer()
                        
                        // Copy error button
                        Button(action: { copyError() }) {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(copied ? "Copied!" : "Copy Error")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(copied ? .green : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
                .padding(.bottom, 8)
                .background(Color.red.opacity(0.03))
            }
        }
    }
    
    @State private var copied = false
    
    private func copyError() {
        var errorText = "Test: \(result.name)\n"
        if let file = result.file {
            errorText += "File: \(file)"
            if let line = result.line {
                errorText += ":\(line)"
            }
            errorText += "\n"
        }
        errorText += "\n"
        if let error = result.errorMessage {
            errorText += "Error:\n\(error)\n"
        }
        if let stackTrace = result.stackTrace {
            errorText += "\nStack Trace:\n\(stackTrace)"
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(errorText, forType: .string)
        
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
    
    private var statusColor: Color {
        switch result.status {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .yellow
        case .error: return .orange
        case .running: return .blue
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(color)
                )
        }
        .foregroundColor(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
    }
}

struct SectionHeaderWithCopy: View {
    let title: String
    let count: Int
    let color: Color
    let onCopy: () -> Void
    
    @State private var copied = false
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(color)
                )
            
            Spacer()
            
            // Copy all errors button
            Button(action: {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(copied ? "Copied!" : "Copy All")
                        .font(.system(size: 10))
                }
                .foregroundColor(copied ? .green : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
    }
}

// MARK: - Test Runner Theme

struct TestRunnerTheme {
    let background: Color
    let headerBackground: Color
    let foreground: Color
    let secondaryText: Color
    
    static let light = TestRunnerTheme(
        background: Color(nsColor: .textBackgroundColor),
        headerBackground: Color(nsColor: .windowBackgroundColor),
        foreground: Color(nsColor: .textColor),
        secondaryText: Color(nsColor: .secondaryLabelColor)
    )
    
    static let dark = TestRunnerTheme(
        background: Color(nsColor: .textBackgroundColor),
        headerBackground: Color(nsColor: .windowBackgroundColor),
        foreground: Color(nsColor: .textColor),
        secondaryText: Color(nsColor: .secondaryLabelColor)
    )
}

// MARK: - Test Runner Agent Wrapper

/// Wrapper to help with observing an optional TestRunnerAgent
@MainActor
class TestRunnerAgentWrapper: ObservableObject {
    @Published var agent: TestRunnerAgent?
    private var cancellable: AnyCancellable?
    
    init(agent: TestRunnerAgent?) {
        self.agent = agent
        setupObservation()
    }
    
    func setAgent(_ newAgent: TestRunnerAgent?) {
        self.agent = newAgent
        setupObservation()
    }
    
    private func setupObservation() {
        cancellable?.cancel()
        guard let agent = agent else { return }
        // Forward objectWillChange from the agent to trigger our own updates
        cancellable = agent.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - Test Runner Button

/// Button to trigger the test runner from the UI - shows progress when active
struct TestRunnerButton: View {
    let agent: TestRunnerAgent?
    let onStart: () -> Void
    let onShowPanel: () -> Void
    
    @State private var isHovered = false
    @State private var isPulsing = false
    
    private var isActive: Bool {
        guard let agent = agent else { return false }
        return agent.status.isActive
    }
    
    private var statusText: String {
        guard let agent = agent else { return "Run Tests" }
        switch agent.status {
        case .idle: return "Run Tests"
        case .analyzing: return "Analyzing..."
        case .blocked: return "Blocked"
        case .running(let progress):
            if let total = progress.totalTests {
                return "\(progress.testsRun)/\(total)"
            }
            return "\(progress.testsRun) tests"
        case .completed(let summary):
            return summary.isSuccess ? "✓ Passed" : "✗ Failed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    
    private var statusColor: Color {
        guard let agent = agent else { return .accentColor }
        switch agent.status {
        case .idle: return .accentColor
        case .analyzing, .running: return .blue
        case .blocked: return .orange
        case .completed(let summary): return summary.isSuccess ? .green : .red
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
    
    var body: some View {
        Button(action: {
            if agent == nil || agent?.status == .idle {
                onStart()
            } else {
                onShowPanel()
            }
        }) {
            HStack(spacing: 6) {
                if isActive {
                    // Show spinner when active
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11))
                }
                
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? statusColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(isPulsing && isActive ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
        .onAppear {
            isPulsing = true
        }
        .help(isActive ? "Click to view test progress" : "Analyze project and run tests")
    }
    
    private var statusIcon: String {
        guard let agent = agent else { return "testtube.2" }
        switch agent.status {
        case .idle: return "testtube.2"
        case .analyzing: return "magnifyingglass"
        case .blocked: return "exclamationmark.triangle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed(let summary): return summary.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
    
    private var foregroundColor: Color {
        if isHovered && !isActive {
            return .white
        }
        return statusColor
    }
    
    private var backgroundColor: Color {
        if isHovered && !isActive {
            return statusColor
        }
        return statusColor.opacity(0.1)
    }
}

// MARK: - Legacy Test Runner Button (for backwards compatibility)

/// Simple button that just triggers an action
struct SimpleTestRunnerButton: View {
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "testtube.2")
                    .font(.system(size: 11))
                Text("Run Tests")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? .white : .accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor : Color.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help("Analyze project and run tests")
    }
}

// MARK: - Preview

#if DEBUG
struct TestRunnerPanel_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock agent for preview
        let agent = TestRunnerAgent(
            provider: .cloud(.openai),
            modelId: "gpt-4",
            projectPath: "/Users/test/project"
        )
        
        TestRunnerPanel(
            agent: agent,
            onDismiss: {},
            onRerun: {},
            onRerunFailed: {}
        )
        .frame(width: 700, height: 500)
    }
}
#endif


