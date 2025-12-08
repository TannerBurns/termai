import SwiftUI

// MARK: - File Diff View

/// IDE-style side-by-side diff viewer with syntax highlighting
struct FileDiffView: View {
    let fileChange: FileChange
    let diff: FileDiff
    
    /// Whether this view is in approval mode (showing accept/reject buttons per hunk)
    var isApprovalMode: Bool = false
    
    /// Binding for tracking hunk decisions (only used in approval mode)
    @Binding var hunkDecisions: [UUID: HunkDecision]
    
    @Environment(\.colorScheme) var colorScheme
    @State private var scrollOffset: CGFloat = 0
    @State private var viewMode: DiffViewMode = .unified
    
    enum DiffViewMode: String, CaseIterable {
        case sideBySide = "Side by Side"
        case unified = "Unified"
    }
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    /// Convenience initializer for non-approval mode (read-only diff viewing)
    init(fileChange: FileChange, diff: FileDiff) {
        self.fileChange = fileChange
        self.diff = diff
        self.isApprovalMode = false
        self._hunkDecisions = .constant([:])
    }
    
    /// Full initializer for approval mode with hunk decision tracking
    init(fileChange: FileChange, diff: FileDiff, isApprovalMode: Bool, hunkDecisions: Binding<[UUID: HunkDecision]>) {
        self.fileChange = fileChange
        self.diff = diff
        self.isApprovalMode = isApprovalMode
        self._hunkDecisions = hunkDecisions
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // File header
            fileHeader
            
            Divider()
            
            // View mode selector (and bulk actions in approval mode)
            viewModeSelector
            
            Divider()
            
            // Diff content - show hunk-based view in approval mode
            if isApprovalMode {
                hunkBasedView
            } else if viewMode == .sideBySide {
                sideBySideView
            } else {
                unifiedView
            }
            
            Divider()
            
            // Summary footer
            summaryFooter
        }
        .background(theme.background)
    }
    
    // MARK: - File Header
    
    private var fileHeader: some View {
        HStack(spacing: 12) {
            // Operation badge
            operationBadge
            
            // Filename only (full path shown in parent sheet header)
            Text(fileChange.fileName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
            
            Spacer()
            
            // Change summary
            HStack(spacing: 8) {
                if diff.addedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(diff.addedCount)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(theme.addedText)
                }
                
                if diff.removedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(diff.removedCount)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(theme.removedText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.background)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.headerBackground)
    }
    
    private var operationBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: fileChange.operationType.icon)
                .font(.system(size: 12, weight: .semibold))
            Text(fileChange.operationType.description)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(operationColor)
        )
    }
    
    private var operationColor: Color {
        switch fileChange.operationType {
        case .create: return .green
        case .edit: return .blue
        case .insert: return .cyan
        case .delete, .deleteFile: return .red
        case .overwrite: return .orange
        }
    }
    
    // MARK: - View Mode Selector
    
    private var viewModeSelector: some View {
        HStack(spacing: 12) {
            if !isApprovalMode {
                Picker("", selection: $viewMode) {
                    ForEach(DiffViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                // Hunk count indicator in approval mode
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 11))
                    Text("\(diff.hunks.count) hunk\(diff.hunks.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.background)
                )
            }
            
            Spacer()
            
            // Bulk actions in approval mode
            if isApprovalMode && !diff.hunks.isEmpty {
                HStack(spacing: 8) {
                    Button(action: acceptAllHunks) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Accept All")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.addedText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(theme.addedBackground)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: rejectAllHunks) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Reject All")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.removedText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(theme.removedBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.background)
    }
    
    private func acceptAllHunks() {
        for hunk in diff.hunks {
            hunkDecisions[hunk.id] = .accepted
        }
    }
    
    private func rejectAllHunks() {
        for hunk in diff.hunks {
            hunkDecisions[hunk.id] = .rejected
        }
    }
    
    // MARK: - Side by Side View
    
    private var sideBySideView: some View {
        HStack(spacing: 0) {
            // Before panel
            diffPanel(
                title: "Before",
                lines: beforeLines,
                isLeft: true
            )
            
            // Divider
            Rectangle()
                .fill(theme.divider)
                .frame(width: 1)
            
            // After panel
            diffPanel(
                title: "After",
                lines: afterLines,
                isLeft: false
            )
        }
    }
    
    private func diffPanel(title: String, lines: [(lineNum: Int?, content: String, type: DiffLine.DiffLineType)], isLeft: Bool) -> some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.panelHeader)
            
            Divider()
            
            // Lines
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        diffLineRow(
                            lineNumber: line.lineNum,
                            content: line.content,
                            type: line.type,
                            isLeft: isLeft
                        )
                    }
                }
            }
        }
    }
    
    private var beforeLines: [(lineNum: Int?, content: String, type: DiffLine.DiffLineType)] {
        var result: [(Int?, String, DiffLine.DiffLineType)] = []
        var lineNum = 1
        
        for line in diff.lines {
            switch line.type {
            case .removed:
                result.append((lineNum, line.content, .removed))
                lineNum += 1
            case .unchanged:
                result.append((lineNum, line.content, .unchanged))
                lineNum += 1
            case .added:
                // Show empty placeholder on left side
                result.append((nil, "", .context))
            default:
                break
            }
        }
        
        return result
    }
    
    private var afterLines: [(lineNum: Int?, content: String, type: DiffLine.DiffLineType)] {
        var result: [(Int?, String, DiffLine.DiffLineType)] = []
        var lineNum = 1
        
        for line in diff.lines {
            switch line.type {
            case .added:
                result.append((lineNum, line.content, .added))
                lineNum += 1
            case .unchanged:
                result.append((lineNum, line.content, .unchanged))
                lineNum += 1
            case .removed:
                // Show empty placeholder on right side
                result.append((nil, "", .context))
            default:
                break
            }
        }
        
        return result
    }
    
    // MARK: - Unified View
    
    private var unifiedView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { index, line in
                    unifiedLineRow(line: line, index: index)
                }
            }
        }
    }
    
    // MARK: - Hunk-Based View (Approval Mode)
    
    private var hunkBasedView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(diff.hunks) { hunk in
                    hunkView(hunk: hunk)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }
    
    private func hunkView(hunk: DiffHunk) -> some View {
        let decision = hunkDecisions[hunk.id] ?? .pending
        
        return VStack(spacing: 0) {
            // Hunk header with actions
            hunkHeader(hunk: hunk, decision: decision)
            
            // Hunk lines
            VStack(spacing: 0) {
                ForEach(hunk.lines) { line in
                    hunkLineRow(line: line, decision: decision)
                }
            }
            .opacity(decision == .rejected ? 0.5 : 1.0)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hunkBorderColor(for: decision), lineWidth: decision == .pending ? 0.5 : 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func hunkHeader(hunk: DiffHunk, decision: HunkDecision) -> some View {
        HStack(spacing: 8) {
            // Hunk header text (git-style, already includes line counts)
            Text(hunk.header)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.secondaryText)
            
            Spacer()
            
            // Decision indicator or action buttons
            if decision == .accepted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Accepted")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.addedText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.addedBackground)
                )
                .onTapGesture {
                    hunkDecisions[hunk.id] = .pending
                }
            } else if decision == .rejected {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Rejected")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.removedText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.removedBackground)
                )
                .onTapGesture {
                    hunkDecisions[hunk.id] = .pending
                }
            } else {
                // Pending - show action buttons
                HStack(spacing: 6) {
                    Button(action: { hunkDecisions[hunk.id] = .accepted }) {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Accept")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.green)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { hunkDecisions[hunk.id] = .rejected }) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Reject")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panelHeader)
    }
    
    private func hunkLineRow(line: DiffLine, decision: HunkDecision) -> some View {
        HStack(spacing: 0) {
            // Line number
            Text(line.lineNumber.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.lineNumber)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 6)
                .background(theme.gutterBackground)
            
            // Change indicator
            Text(changeIndicator(for: line.type))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(indicatorColor(for: line.type))
                .frame(width: 16)
            
            // Line content with syntax highlighting
            highlightedLine(line.content)
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strikethrough(decision == .rejected && line.type == .added, color: theme.removedText)
        }
        .padding(.vertical, 1)
        .background(backgroundColor(for: line.type))
    }
    
    private func hunkBorderColor(for decision: HunkDecision) -> Color {
        switch decision {
        case .pending: return theme.divider
        case .accepted: return theme.addedText
        case .rejected: return theme.removedText
        }
    }
    
    private func unifiedLineRow(line: DiffLine, index: Int) -> some View {
        HStack(spacing: 0) {
            // Line number gutter
            HStack(spacing: 0) {
                // Old line number
                Text(line.type == .removed || line.type == .unchanged ? "\(index + 1)" : "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.lineNumber)
                    .frame(width: 40, alignment: .trailing)
                
                // New line number
                Text(line.type == .added || line.type == .unchanged ? "\(line.lineNumber ?? index + 1)" : "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.lineNumber)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .background(theme.gutterBackground)
            
            // Change indicator
            Text(changeIndicator(for: line.type))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(indicatorColor(for: line.type))
                .frame(width: 20)
            
            // Line content with syntax highlighting
            highlightedLine(line.content)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(backgroundColor(for: line.type))
    }
    
    private func diffLineRow(lineNumber: Int?, content: String, type: DiffLine.DiffLineType, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            // Line number gutter
            Text(lineNumber.map { String($0) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.lineNumber)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)
                .background(theme.gutterBackground)
            
            // Change indicator
            let indicator = isLeft ? (type == .removed ? "-" : " ") : (type == .added ? "+" : " ")
            Text(indicator)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(indicatorColor(for: type))
                .frame(width: 16)
            
            // Line content
            if content.isEmpty && type == .context {
                Color.clear
                    .frame(maxWidth: .infinity)
            } else {
                highlightedLine(content)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 1)
        .background(backgroundColor(for: type))
    }
    
    private func changeIndicator(for type: DiffLine.DiffLineType) -> String {
        switch type {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }
    
    private func indicatorColor(for type: DiffLine.DiffLineType) -> Color {
        switch type {
        case .added: return theme.addedText
        case .removed: return theme.removedText
        default: return theme.secondaryText
        }
    }
    
    private func backgroundColor(for type: DiffLine.DiffLineType) -> Color {
        switch type {
        case .added: return theme.addedBackground
        case .removed: return theme.removedBackground
        case .context: return theme.contextBackground
        default: return Color.clear
        }
    }
    
    // MARK: - Syntax Highlighting
    
    private func highlightedLine(_ content: String) -> some View {
        let highlighter = MultiLanguageHighlighter(colorScheme: colorScheme)
        return highlighter.highlight(content, language: fileChange.language)
            .font(.system(size: 12, design: .monospaced))
    }
    
    // MARK: - Summary Footer
    
    private var summaryFooter: some View {
        HStack(spacing: 16) {
            // Language indicator
            if let lang = fileChange.language {
                Text(lang.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.background)
                    )
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.headerBackground)
    }
}

// MARK: - Diff Theme

struct DiffTheme {
    let background: Color
    let foreground: Color
    let secondaryText: Color
    let lineNumber: Color
    let divider: Color
    let headerBackground: Color
    let panelHeader: Color
    let gutterBackground: Color
    let addedBackground: Color
    let removedBackground: Color
    let contextBackground: Color
    let addedText: Color
    let removedText: Color
    
    // Atom One Dark colors
    static let dark = DiffTheme(
        background: Color(red: 0.16, green: 0.17, blue: 0.20),           // #282c34
        foreground: Color(red: 0.67, green: 0.70, blue: 0.75),           // #abb2bf
        secondaryText: Color(red: 0.36, green: 0.39, blue: 0.44),        // #5c6370
        lineNumber: Color(red: 0.39, green: 0.43, blue: 0.51),           // #636d83
        divider: Color(red: 0.24, green: 0.27, blue: 0.32),              // #3e4451
        headerBackground: Color(red: 0.13, green: 0.15, blue: 0.17),     // #21252b
        panelHeader: Color(red: 0.17, green: 0.19, blue: 0.23),          // #2c313a
        gutterBackground: Color(red: 0.13, green: 0.15, blue: 0.17),     // #21252b
        addedBackground: Color(red: 0.60, green: 0.76, blue: 0.47).opacity(0.2),  // #98c379
        removedBackground: Color(red: 0.88, green: 0.42, blue: 0.46).opacity(0.2), // #e06c75
        contextBackground: Color(red: 0.16, green: 0.17, blue: 0.20).opacity(0.5), // #282c34
        addedText: Color(red: 0.60, green: 0.76, blue: 0.47),            // #98c379
        removedText: Color(red: 0.88, green: 0.42, blue: 0.46)           // #e06c75
    )
    
    // Atom One Light colors
    static let light = DiffTheme(
        background: Color(red: 0.98, green: 0.98, blue: 0.98),           // #fafafa
        foreground: Color(red: 0.22, green: 0.23, blue: 0.26),           // #383a42
        secondaryText: Color(red: 0.63, green: 0.63, blue: 0.65),        // #a0a1a7
        lineNumber: Color(red: 0.62, green: 0.62, blue: 0.62),           // #9d9d9f
        divider: Color(red: 0.82, green: 0.82, blue: 0.82),              // #d0d0d0
        headerBackground: Color(red: 0.94, green: 0.94, blue: 0.94),     // #f0f0f0
        panelHeader: Color(red: 0.90, green: 0.90, blue: 0.90),          // #e5e5e6
        gutterBackground: Color(red: 0.94, green: 0.94, blue: 0.94),     // #f0f0f0
        addedBackground: Color(red: 0.31, green: 0.63, blue: 0.31).opacity(0.15), // #50a14f
        removedBackground: Color(red: 0.89, green: 0.34, blue: 0.29).opacity(0.15), // #e45649
        contextBackground: Color(red: 0.98, green: 0.98, blue: 0.98).opacity(0.5), // #fafafa
        addedText: Color(red: 0.31, green: 0.63, blue: 0.31),            // #50a14f
        removedText: Color(red: 0.89, green: 0.34, blue: 0.29)           // #e45649
    )
}

// MARK: - Compact Diff Badge

/// A small badge showing diff summary for inline display
struct DiffSummaryBadge: View {
    let diff: FileDiff
    
    @Environment(\.colorScheme) var colorScheme
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: diff.fileChange.operationType.icon)
                .font(.system(size: 10))
            
            if diff.addedCount > 0 {
                Text("+\(diff.addedCount)")
                    .foregroundColor(theme.addedText)
            }
            
            if diff.removedCount > 0 {
                Text("-\(diff.removedCount)")
                    .foregroundColor(theme.removedText)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.headerBackground)
        )
        .overlay(
            Capsule()
                .stroke(theme.divider, lineWidth: 0.5)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct FileDiffView_Previews: PreviewProvider {
    static var previews: some View {
        let fileChange = FileChange(
            filePath: "/Users/test/project/src/App.swift",
            operationType: .edit,
            beforeContent: """
            import SwiftUI
            
            struct App: View {
                var body: some View {
                    Text("Hello")
                }
            }
            """,
            afterContent: """
            import SwiftUI
            
            struct App: View {
                @State private var message = "Hello, World!"
                
                var body: some View {
                    VStack {
                        Text(message)
                        Button("Tap me") {
                            message = "Tapped!"
                        }
                    }
                }
            }
            """
        )
        
        let diff = FileDiff(fileChange: fileChange)
        
        Group {
            // Read-only mode
            FileDiffView(fileChange: fileChange, diff: diff)
                .frame(width: 800, height: 500)
                .previewDisplayName("Read-Only Mode")
            
            // Approval mode with hunk actions
            FileDiffViewApprovalPreview(fileChange: fileChange, diff: diff)
                .frame(width: 800, height: 500)
                .previewDisplayName("Approval Mode")
        }
    }
}

/// Helper view for previewing approval mode
private struct FileDiffViewApprovalPreview: View {
    let fileChange: FileChange
    let diff: FileDiff
    @State private var hunkDecisions: [UUID: HunkDecision] = [:]
    
    var body: some View {
        FileDiffView(
            fileChange: fileChange,
            diff: diff,
            isApprovalMode: true,
            hunkDecisions: $hunkDecisions
        )
    }
}
#endif

