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
                case .code(let lang, let code, let isClosed):
                    CodeBlockView(language: lang, code: code, isClosed: isClosed)
                case .table(let headers, let rows):
                    TableView(headers: headers, rows: rows)
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
    
    var body: some View {
        let isShell = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).matchesAny(["bash", "sh", "shell", "zsh"]) == true
        
        VStack(alignment: .leading, spacing: 0) {
            // Code block
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.gray.opacity(0.12))
            
            // Action buttons bar (only for shell code blocks)
            if isClosed && isShell {
                Divider()
                HStack(spacing: 8) {
                    Button("Add to terminal") {
                        let commands = code
                            .components(separatedBy: .newlines)
                            .compactMap { line -> String? in
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.isEmpty { return nil }
                                
                                // Skip comment lines (any line starting with #)
                                if trimmed.hasPrefix("#") {
                                    // All lines starting with # are comments
                                    return nil
                                }
                                
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
                        
                        // Send commands separated by && so they appear as a single compound command
                        // but can be edited before execution
                        if !commands.isEmpty {
                            let compoundCommand = commands.joined(separator: " && ")
                            ptyModel.sendInput?(compoundCommand)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("▶️ Run in terminal") {
                        let commands = code
                            .components(separatedBy: .newlines)
                            .compactMap { line -> String? in
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.isEmpty { return nil }
                                
                                // Skip comment lines (any line starting with #)
                                if trimmed.hasPrefix("#") {
                                    // All lines starting with # are comments
                                    return nil
                                }
                                
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
                        
                        // Execute commands sequentially - send them as a compound command with &&
                        // This ensures each command only runs if the previous one succeeded
                        if !commands.isEmpty {
                            let compoundCommand = commands.joined(separator: " && ")
                            ptyModel.sendInput?(compoundCommand + "\n")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.08))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            let hardBreaks = text.replacingOccurrences(of: "\n", with: "  \n")
            let processed: AttributedString = {
                var attr = (try? AttributedString(markdown: hardBreaks, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)
                for run in attr.runs {
                    if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                        attr[run.range].font = .system(.body, design: .monospaced)
                    }
                }
                return attr
            }()
            Text(processed)
        } else {
            Text(text)
        }
    }
}

private struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ForEach(headers.indices, id: \.self) { i in
                    MarkdownText(text: headers[i])
                        .fontWeight(.semibold)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.gray.opacity(0.1))
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        MarkdownText(text: rows[r][c])
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(r % 2 == 0 ? Color.clear : Color.gray.opacity(0.05))
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Removed NSView-based renderer to keep SwiftUI layout stable


