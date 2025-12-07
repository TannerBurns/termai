import SwiftUI
// Removed Down to avoid NSView bridging issues in SwiftUI chat bubbles
 
struct MarkdownRenderer: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parseBlocks(text), id: \.self) { block in
                switch block {
                case .paragraph(let p):
                    ParagraphView(text: p)
                        .padding(.vertical, 1)
                case .header(let level, let text):
                    HeaderView(level: level, text: text)
                        .padding(.top, level == 1 ? 6 : 3)
                        .padding(.bottom, 1)
                case .listItem(let text):
                    ListItemView(text: text)
                case .code(let lang, let code, let isClosed):
                    CodeBlockView(language: lang, code: code, isClosed: isClosed)
                        .padding(.vertical, 3)
                case .table(let headers, let rows):
                    TableView(headers: headers, rows: rows)
                        .padding(.vertical, 3)
                }
            }
        }
    }

    private enum Block: Hashable {
        case paragraph(String)
        case header(level: Int, text: String)
        case listItem(String)
        case code(language: String?, content: String, isClosed: Bool)
        case table(headers: [String], rows: [[String]])
    }
    
    /// Check if a line is a markdown header
    private func isHeader(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == "#" && level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }
    
    /// Check if a line is a markdown list item
    private func isListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Unordered list: starts with -, *, or + followed by space
        if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")) {
            return String(trimmed.dropFirst(2))
        }
        // Ordered list: starts with number followed by . or ) and space
        if let match = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(trimmed[match.upperBound...])
        }
        return nil
    }

    private func parseBlocks(_ input: String) -> [Block] {
        var result: [Block] = []
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var idx = 0
        var paragraph: [String] = []
        var inCode = false
        var codeLang: String? = nil
        var codeLines: [String] = []
        var codeIsClosed: Bool = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                let joined = paragraph.joined(separator: "\n")
                result.append(.paragraph(joined))
                paragraph.removeAll()
            }
        }

        while idx < lines.count {
            let line = lines[idx]
            // Simple GitHub-style table detection
            if line.contains("|") && idx+1 < lines.count && lines[idx+1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "").allSatisfy({ $0 == "-" || $0 == ":" }) {
                flushParagraph()
                let headerCols = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                idx += 2 // skip the separator row
                var bodyRows: [[String]] = []
                while idx < lines.count {
                    let rline = lines[idx]
                    if rline.contains("|") {
                        let cols = rline.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        bodyRows.append(cols)
                        idx += 1
                    } else {
                        break
                    }
                }
                result.append(.table(headers: headerCols, rows: bodyRows))
                continue
            }
            if line.hasPrefix("```") {
                if inCode {
                    // end code block
                    codeIsClosed = true
                    result.append(.code(language: codeLang, content: codeLines.joined(separator: "\n"), isClosed: codeIsClosed))
                    inCode = false
                    codeLang = nil
                    codeLines.removeAll()
                    codeIsClosed = false
                } else {
                    // start code block
                    flushParagraph()
                    let afterTicks = String(line.dropFirst(3))
                    let lang = afterTicks.trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                    codeIsClosed = false
                }
            } else if inCode {
                codeLines.append(line)
            } else if let header = isHeader(line) {
                // Headers are always separate blocks
                flushParagraph()
                result.append(.header(level: header.level, text: header.text))
            } else if let listText = isListItem(line) {
                // List items are separate blocks
                flushParagraph()
                result.append(.listItem(listText))
            } else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // paragraph break
                    flushParagraph()
                } else {
                    paragraph.append(line)
                }
            }
            idx += 1
        }

        if inCode {
            // Unclosed code block (still streaming)
            result.append(.code(language: codeLang, content: codeLines.joined(separator: "\n"), isClosed: false))
        } else {
            flushParagraph()
        }
        return result
    }
}

private struct ParagraphView: View {
    let text: String
    var body: some View {
        MarkdownText(text: text)
    }
}

private struct HeaderView: View {
    let level: Int
    let text: String
    
    var body: some View {
        MarkdownText(text: text)
            .font(fontForLevel)
            .fontWeight(level <= 2 ? .bold : .semibold)
    }
    
    private var fontForLevel: Font {
        switch level {
        case 1: return .system(size: 14, weight: .bold)
        case 2: return .system(size: 13, weight: .bold)
        case 3: return .system(size: 12, weight: .semibold)
        case 4: return .system(size: 11.5, weight: .semibold)
        default: return .system(size: 11, weight: .medium)
        }
    }
}

private struct ListItemView: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)
            MarkdownText(text: text)
        }
        .padding(.leading, 4)
    }
}

private struct CodeBlockView: View {
    @EnvironmentObject private var ptyModel: PTYModel
    @Environment(\.colorScheme) private var colorScheme
    let language: String?
    let code: String
    let isClosed: Bool
    
    /// Removes inline bash comments from a command line while preserving comments inside quotes
    private func stripBashComment(from line: String) -> String {
        var result = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        
        for char in line {
            if escaped {
                result.append(char)
                escaped = false
                continue
            }
            
            if char == "\\" {
                escaped = true
                result.append(char)
                continue
            }
            
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(char)
                continue
            }
            
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(char)
                continue
            }
            
            if char == "#" && !inSingleQuote && !inDoubleQuote {
                // Found start of comment, stop here
                break
            }
            
            result.append(char)
        }
        
        return result.trimmingCharacters(in: .whitespaces)
    }
    
    private func extractCommands() -> [String] {
        code.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return nil }
                
                // Skip comment lines (any line starting with #)
                if trimmed.hasPrefix("#") { return nil }
                
                // Remove shell prompts
                var command = trimmed
                if trimmed.hasPrefix("$ ") { 
                    command = String(trimmed.dropFirst(2))
                } else if trimmed.hasPrefix("% ") { 
                    command = String(trimmed.dropFirst(2))
                } else if trimmed.hasPrefix("> ") {
                    command = String(trimmed.dropFirst(2))
                }
                
                // Strip inline comments
                command = stripBashComment(from: command)
                return command.isEmpty ? nil : command
            }
    }
    
    /// Returns syntax-highlighted code as a Text view
    private var highlightedCode: Text {
        let highlighter = MultiLanguageHighlighter(colorScheme: colorScheme)
        return highlighter.highlight(code, language: language)
    }
    
    var body: some View {
        let isShell = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).matchesAny(["bash", "sh", "shell", "zsh", "fish", "ksh", "csh", "tcsh", "console", "terminal", "command"]) == true
        
        VStack(alignment: .leading, spacing: 0) {
            // Language badge and copy button
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                        )
                    
                    Spacer()
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy code")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            
            // Code block with syntax highlighting
            ScrollView(.horizontal, showsIndicators: false) {
                highlightedCode
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Action buttons bar (only for shell code blocks)
            if isClosed && isShell {
                HStack(spacing: 8) {
                    CodeActionButton(
                        title: "Copy to terminal",
                        icon: "terminal",
                        color: .blue
                    ) {
                        let commands = extractCommands()
                        if !commands.isEmpty {
                            let compoundCommand = commands.joined(separator: " && ")
                            ptyModel.sendInput?(compoundCommand)
                        }
                    }
                    
                    CodeActionButton(
                        title: "Run",
                        icon: "play.fill",
                        color: .green
                    ) {
                        let commands = extractCommands()
                        if !commands.isEmpty {
                            let compoundCommand = commands.joined(separator: " && ")
                            ptyModel.sendInput?(compoundCommand + "\n")
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.1), Color.primary.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Code Action Button
private struct CodeActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isHovered ? .white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered ? color : color.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(isHovered ? 0 : 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.spring(response: 0.2), value: isHovered)
        .animation(.spring(response: 0.15), value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

private extension String {
    func matchesAny(_ options: [String]) -> Bool {
        let lowerSelf = self.lowercased()
        return options.contains(where: { lowerSelf == $0 })
    }
}

private struct MarkdownText: View {
    let text: String
    var body: some View {
        if #available(macOS 13.0, *) {
            // Convert single newlines to markdown line breaks (two trailing spaces)
            let hardBreaks = text.replacingOccurrences(of: "\n", with: "  \n")
            let processed: AttributedString = {
                var attr = (try? AttributedString(markdown: hardBreaks, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)
                for run in attr.runs {
                    if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                        attr[run.range].font = .system(size: 10.5, design: .monospaced)
                        attr[run.range].backgroundColor = Color.primary.opacity(0.06)
                    }
                }
                return attr
            }()
            Text(processed)
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(headers.indices, id: \.self) { i in
                    MarkdownText(text: headers[i])
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if i < headers.count - 1 {
                        Divider()
                    }
                }
            }
            .background(.ultraThinMaterial)
            
            Divider()
            
            // Body rows
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        MarkdownText(text: rows[r][c])
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if c < rows[r].count - 1 {
                            Divider()
                        }
                    }
                }
                .background(r % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                
                if r < rows.count - 1 {
                    Divider()
                        .opacity(0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Removed NSView-based renderer to keep SwiftUI layout stable


