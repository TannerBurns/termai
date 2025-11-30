import SwiftUI
// Removed Down to avoid NSView bridging issues in SwiftUI chat bubbles
 
struct MarkdownRenderer: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseBlocks(text), id: \.self) { block in
                switch block {
                case .paragraph(let p):
                    ParagraphView(text: p)
                        .padding(.vertical, 2)
                case .code(let lang, let code, let isClosed):
                    CodeBlockView(language: lang, code: code, isClosed: isClosed)
                        .padding(.vertical, 4)
                case .table(let headers, let rows):
                    TableView(headers: headers, rows: rows)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private enum Block: Hashable {
        case paragraph(String)
        case code(language: String?, content: String, isClosed: Bool)
        case table(headers: [String], rows: [[String]])
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
                    let lang = afterTicks.trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                    codeIsClosed = false
                }
            } else if inCode {
                codeLines.append(line)
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

private struct CodeBlockView: View {
    @EnvironmentObject private var ptyModel: PTYModel
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
    
    var body: some View {
        let isShell = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).matchesAny(["bash", "sh", "shell", "zsh"]) == true
        
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
            
            // Code block
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
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
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
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
                        attr[run.range].font = .system(.body, design: .monospaced)
                        attr[run.range].backgroundColor = Color.primary.opacity(0.06)
                    }
                }
                return attr
            }()
            Text(processed)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .lineSpacing(4)
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
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
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
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
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


