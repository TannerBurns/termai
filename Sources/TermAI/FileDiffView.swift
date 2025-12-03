import SwiftUI

// MARK: - File Diff View

/// IDE-style side-by-side diff viewer with syntax highlighting
struct FileDiffView: View {
    let fileChange: FileChange
    let diff: FileDiff
    
    @Environment(\.colorScheme) var colorScheme
    @State private var scrollOffset: CGFloat = 0
    @State private var viewMode: DiffViewMode = .sideBySide
    
    enum DiffViewMode: String, CaseIterable {
        case sideBySide = "Side by Side"
        case unified = "Unified"
    }
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // File header
            fileHeader
            
            Divider()
            
            // View mode selector
            viewModeSelector
            
            Divider()
            
            // Diff content
            if viewMode == .sideBySide {
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
            
            // File path
            VStack(alignment: .leading, spacing: 2) {
                Text(fileChange.fileName)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.foreground)
                
                Text(fileChange.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
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
                    .fill(theme.headerBackground)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        case .delete: return .red
        case .overwrite: return .orange
        }
    }
    
    // MARK: - View Mode Selector
    
    private var viewModeSelector: some View {
        HStack {
            Picker("View Mode", selection: $viewMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            
            Spacer()
            
            // Language indicator
            if let lang = fileChange.language {
                Text(lang.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.headerBackground)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.background)
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
            // Stats
            HStack(spacing: 12) {
                Label("\(diff.addedCount) additions", systemImage: "plus.circle.fill")
                    .foregroundColor(theme.addedText)
                
                Label("\(diff.removedCount) deletions", systemImage: "minus.circle.fill")
                    .foregroundColor(theme.removedText)
                
                Label("\(diff.unchangedCount) unchanged", systemImage: "equal.circle.fill")
                    .foregroundColor(theme.secondaryText)
            }
            .font(.system(size: 11))
            
            Spacer()
            
            // Timestamp
            Text(fileChange.timestamp, style: .relative)
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    
    static let dark = DiffTheme(
        background: Color(white: 0.1),
        foreground: Color(white: 0.9),
        secondaryText: Color(white: 0.5),
        lineNumber: Color(white: 0.4),
        divider: Color(white: 0.2),
        headerBackground: Color(white: 0.12),
        panelHeader: Color(white: 0.14),
        gutterBackground: Color(white: 0.08),
        addedBackground: Color(red: 0.1, green: 0.3, blue: 0.15).opacity(0.5),
        removedBackground: Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.5),
        contextBackground: Color(white: 0.08).opacity(0.3),
        addedText: Color(red: 0.4, green: 0.85, blue: 0.5),
        removedText: Color(red: 0.95, green: 0.4, blue: 0.4)
    )
    
    static let light = DiffTheme(
        background: Color(white: 0.98),
        foreground: Color(white: 0.1),
        secondaryText: Color(white: 0.5),
        lineNumber: Color(white: 0.55),
        divider: Color(white: 0.85),
        headerBackground: Color(white: 0.95),
        panelHeader: Color(white: 0.93),
        gutterBackground: Color(white: 0.96),
        addedBackground: Color(red: 0.85, green: 0.95, blue: 0.87),
        removedBackground: Color(red: 0.98, green: 0.88, blue: 0.88),
        contextBackground: Color(white: 0.97),
        addedText: Color(red: 0.15, green: 0.55, blue: 0.25),
        removedText: Color(red: 0.7, green: 0.2, blue: 0.2)
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
        
        FileDiffView(fileChange: fileChange, diff: diff)
            .frame(width: 800, height: 500)
    }
}
#endif

