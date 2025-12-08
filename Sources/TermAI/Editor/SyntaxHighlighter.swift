import SwiftUI

// MARK: - Syntax Theme

/// Color theme for syntax highlighting
struct SyntaxTheme {
    let keyword: Color
    let string: Color
    let comment: Color
    let number: Color
    let function: Color
    let type: Color
    let variable: Color
    let property: Color
    let `operator`: Color
    let punctuation: Color
    let plain: Color
    let background: Color
    
    /// Dark theme - Atom One Dark colors
    static let dark = SyntaxTheme(
        keyword: Color(red: 0.78, green: 0.47, blue: 0.87),      // #c678dd - Magenta
        string: Color(red: 0.60, green: 0.76, blue: 0.47),       // #98c379 - Green
        comment: Color(red: 0.36, green: 0.39, blue: 0.44),      // #5c6370 - Gray
        number: Color(red: 0.82, green: 0.60, blue: 0.40),       // #d19a66 - Orange
        function: Color(red: 0.38, green: 0.69, blue: 0.94),     // #61afef - Blue
        type: Color(red: 0.90, green: 0.75, blue: 0.48),         // #e5c07b - Yellow
        variable: Color(red: 0.88, green: 0.42, blue: 0.46),     // #e06c75 - Red
        property: Color(red: 0.88, green: 0.42, blue: 0.46),     // #e06c75 - Red
        operator: Color(red: 0.34, green: 0.71, blue: 0.76),     // #56b6c2 - Cyan
        punctuation: Color(red: 0.67, green: 0.70, blue: 0.75),  // #abb2bf - Foreground
        plain: Color(red: 0.67, green: 0.70, blue: 0.75),        // #abb2bf - Foreground
        background: Color(red: 0.16, green: 0.17, blue: 0.20)    // #282c34 - Background
    )
    
    /// Light theme - Atom One Light colors
    static let light = SyntaxTheme(
        keyword: Color(red: 0.65, green: 0.15, blue: 0.64),      // #a626a4 - Magenta
        string: Color(red: 0.31, green: 0.63, blue: 0.31),       // #50a14f - Green
        comment: Color(red: 0.63, green: 0.63, blue: 0.65),      // #a0a1a7 - Gray
        number: Color(red: 0.60, green: 0.41, blue: 0.00),       // #986801 - Orange
        function: Color(red: 0.25, green: 0.47, blue: 0.95),     // #4078f2 - Blue
        type: Color(red: 0.76, green: 0.52, blue: 0.00),         // #c18401 - Yellow
        variable: Color(red: 0.89, green: 0.34, blue: 0.29),     // #e45649 - Red
        property: Color(red: 0.89, green: 0.34, blue: 0.29),     // #e45649 - Red
        operator: Color(red: 0.00, green: 0.52, blue: 0.74),     // #0184bc - Cyan
        punctuation: Color(red: 0.22, green: 0.23, blue: 0.26),  // #383a42 - Foreground
        plain: Color(red: 0.22, green: 0.23, blue: 0.26),        // #383a42 - Foreground
        background: Color(red: 0.98, green: 0.98, blue: 0.98)    // #fafafa - Background
    )
}

// MARK: - Token Types

/// Types of tokens for syntax highlighting
enum TokenType {
    case keyword
    case string
    case comment
    case number
    case function
    case type
    case variable
    case property
    case `operator`
    case punctuation
    case plain
    
    func color(in theme: SyntaxTheme) -> Color {
        switch self {
        case .keyword: return theme.keyword
        case .string: return theme.string
        case .comment: return theme.comment
        case .number: return theme.number
        case .function: return theme.function
        case .type: return theme.type
        case .variable: return theme.variable
        case .property: return theme.property
        case .operator: return theme.operator
        case .punctuation: return theme.punctuation
        case .plain: return theme.plain
        }
    }
}

/// A token with its type and range
struct Token {
    let type: TokenType
    let range: Range<String.Index>
}

// MARK: - Multi-Language Highlighter

/// Main highlighter that dispatches to language-specific highlighters
struct MultiLanguageHighlighter {
    let theme: SyntaxTheme
    
    init(colorScheme: ColorScheme) {
        self.theme = colorScheme == .dark ? .dark : .light
    }
    
    /// Highlight code and return a SwiftUI Text view
    func highlight(_ code: String, language: String?) -> Text {
        guard let lang = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !lang.isEmpty else {
            return Text(code).foregroundColor(theme.plain)
        }
        
        let tokens = tokenize(code, language: lang)
        return buildText(from: code, tokens: tokens)
    }
    
    private func tokenize(_ code: String, language: String) -> [Token] {
        switch language {
        case "swift":
            return SwiftHighlighter.shared.tokenize(code)
        case "bash", "sh", "shell", "zsh", "fish", "ksh", "csh", "tcsh", "console", "terminal", "command":
            return ShellHighlighter.shared.tokenize(code)
        case "python", "py":
            return PythonHighlighter.shared.tokenize(code)
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return JavaScriptHighlighter.shared.tokenize(code)
        case "json":
            return JSONHighlighter.shared.tokenize(code)
        case "yaml", "yml":
            return YAMLHighlighter.shared.tokenize(code)
        case "html", "xml":
            return HTMLHighlighter.shared.tokenize(code)
        case "css", "scss", "sass":
            return CSSHighlighter.shared.tokenize(code)
        case "rust", "rs":
            return RustHighlighter.shared.tokenize(code)
        case "go", "golang":
            return GoHighlighter.shared.tokenize(code)
        case "c", "cpp", "c++", "h", "hpp":
            return CHighlighter.shared.tokenize(code)
        default:
            // Return empty tokens for unknown languages - will render as plain text
            return []
        }
    }
    
    private func buildText(from code: String, tokens: [Token]) -> Text {
        guard !tokens.isEmpty else {
            return Text(code).foregroundColor(theme.plain)
        }
        
        // Sort tokens by start position
        let sortedTokens = tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
        
        var result = Text("")
        var currentIndex = code.startIndex
        
        for token in sortedTokens {
            // Skip if token starts before current position (overlapping)
            if token.range.lowerBound < currentIndex {
                continue
            }
            
            // Add plain text before this token
            if currentIndex < token.range.lowerBound {
                let plainText = String(code[currentIndex..<token.range.lowerBound])
                result = result + Text(plainText).foregroundColor(theme.plain)
            }
            
            // Add the highlighted token
            let tokenText = String(code[token.range])
            result = result + Text(tokenText).foregroundColor(token.type.color(in: theme))
            
            currentIndex = token.range.upperBound
        }
        
        // Add any remaining plain text
        if currentIndex < code.endIndex {
            let remainingText = String(code[currentIndex...])
            result = result + Text(remainingText).foregroundColor(theme.plain)
        }
        
        return result
    }
}

// MARK: - Swift Highlighter (regex-based)

struct SwiftHighlighter {
    static let shared = SwiftHighlighter()
    
    private let keywords = Set([
        "actor", "any", "as", "associatedtype", "async", "await", "break",
        "case", "catch", "class", "continue", "default", "defer", "deinit",
        "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "guard", "if", "import", "in", "indirect",
        "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let",
        "mutating", "nil", "nonisolated", "nonmutating", "open", "operator",
        "optional", "override", "postfix", "precedencegroup", "prefix", "private",
        "protocol", "public", "repeat", "required", "rethrows", "return", "self",
        "Self", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "weak", "where",
        "while"
    ])
    
    private let types = Set([
        "Any", "AnyObject", "Array", "Bool", "Character", "Dictionary", "Double",
        "Float", "Int", "Int8", "Int16", "Int32", "Int64", "Never", "Optional",
        "Result", "Set", "String", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Void", "Error", "Codable", "Decodable", "Encodable", "Equatable",
        "Hashable", "Identifiable", "Comparable", "CustomStringConvertible",
        "View", "Text", "Button", "Image", "VStack", "HStack", "ZStack",
        "List", "ForEach", "NavigationView", "NavigationStack", "ScrollView",
        "Color", "Font", "Binding", "State", "ObservedObject", "Published",
        "EnvironmentObject", "Environment", "StateObject", "ObservableObject"
    ])
    
    private let attributes = Set([
        "@available", "@discardableResult", "@dynamicCallable", "@dynamicMemberLookup",
        "@escaping", "@frozen", "@inlinable", "@main", "@objc", "@objcMembers",
        "@propertyWrapper", "@resultBuilder", "@testable", "@usableFromInline",
        "@Published", "@State", "@Binding", "@ObservedObject", "@EnvironmentObject",
        "@Environment", "@StateObject", "@ViewBuilder", "@MainActor", "@Sendable"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Single-line comments
        let singleCommentPattern = #"//.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: singleCommentPattern, type: .comment, options: .anchorsMatchLines))
        
        // Multi-line comments
        let multiCommentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: multiCommentPattern, type: .comment))
        
        // Multi-line strings
        let multiStringPattern = #"\"\"\"[\s\S]*?\"\"\""#
        tokens.append(contentsOf: findMatches(code, pattern: multiStringPattern, type: .string))
        
        // Regular strings
        let stringPattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Attributes
        let attrPattern = #"@[a-zA-Z_][a-zA-Z0-9_]*"#
        if let regex = try? NSRegularExpression(pattern: attrPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let attr = String(code[range])
                    if attributes.contains(attr) {
                        tokens.append(Token(type: .keyword, range: range))
                    }
                }
            }
        }
        
        // Numbers (including hex, binary, octal)
        let numberPattern = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?[\d_]+)?)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Function declarations
        let funcDeclPattern = #"(?<=\bfunc\s)[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: funcDeclPattern, type: .function))
        
        // Type declarations
        let typeDefPatterns = [
            #"(?<=\bclass\s)[a-zA-Z_][a-zA-Z0-9_]*"#,
            #"(?<=\bstruct\s)[a-zA-Z_][a-zA-Z0-9_]*"#,
            #"(?<=\benum\s)[a-zA-Z_][a-zA-Z0-9_]*"#,
            #"(?<=\bprotocol\s)[a-zA-Z_][a-zA-Z0-9_]*"#,
            #"(?<=\bactor\s)[a-zA-Z_][a-zA-Z0-9_]*"#
        ]
        for pattern in typeDefPatterns {
            tokens.append(contentsOf: findMatches(code, pattern: pattern, type: .type))
        }
        
        // Keywords, types, and identifiers
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if types.contains(word) {
                        tokens.append(Token(type: .type, range: range))
                    }
                }
            }
        }
        
        // Property access (after .)
        let propertyPattern = #"(?<=\.)[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: propertyPattern, type: .property))
        
        return tokens
    }
}

// MARK: - Shell Highlighter

struct ShellHighlighter {
    static let shared = ShellHighlighter()
    
    private let keywords = Set([
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "in", "function", "select", "until", "return",
        "break", "continue", "local", "export", "readonly", "declare",
        "typeset", "unset", "shift", "source", "alias", "unalias",
        "set", "shopt", "trap", "exit", "exec", "eval", "true", "false"
    ])
    
    private let builtins = Set([
        "echo", "printf", "read", "cd", "pwd", "pushd", "popd", "dirs",
        "let", "test", "expr", "basename", "dirname", "cat", "grep",
        "sed", "awk", "cut", "sort", "uniq", "wc", "head", "tail",
        "find", "xargs", "chmod", "chown", "mkdir", "rmdir", "rm",
        "cp", "mv", "ln", "ls", "touch", "date", "sleep", "wait",
        "kill", "ps", "bg", "fg", "jobs", "nohup", "nice", "time"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments: # to end of line (but not inside strings)
        let commentPattern = #"(?<!\\)#.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: commentPattern, type: .comment, options: .anchorsMatchLines))
        
        // Strings: double-quoted
        let doubleQuotePattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: doubleQuotePattern, type: .string))
        
        // Strings: single-quoted
        let singleQuotePattern = #"'[^']*'"#
        tokens.append(contentsOf: findMatches(code, pattern: singleQuotePattern, type: .string))
        
        // Variables: $VAR, ${VAR}, $1, $@, etc.
        let variablePattern = #"\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?|\$[0-9@#?!$*-]"#
        tokens.append(contentsOf: findMatches(code, pattern: variablePattern, type: .variable))
        
        // Numbers
        let numberPattern = #"\b\d+(?:\.\d+)?\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Keywords and builtins
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if builtins.contains(word) {
                        tokens.append(Token(type: .function, range: range))
                    }
                }
            }
        }
        
        // Operators and special characters
        let operatorPattern = #"[|&;><]|\|\||&&|>>|<<|2>&1|>&"#
        tokens.append(contentsOf: findMatches(code, pattern: operatorPattern, type: .operator))
        
        return tokens
    }
}

// MARK: - Python Highlighter

struct PythonHighlighter {
    static let shared = PythonHighlighter()
    
    private let keywords = Set([
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
        "try", "while", "with", "yield", "match", "case", "type"
    ])
    
    private let builtins = Set([
        "print", "len", "range", "str", "int", "float", "list", "dict",
        "set", "tuple", "bool", "type", "isinstance", "issubclass", "callable",
        "hasattr", "getattr", "setattr", "delattr", "open", "input", "super",
        "staticmethod", "classmethod", "property", "enumerate", "zip", "map",
        "filter", "sorted", "reversed", "sum", "min", "max", "abs", "round",
        "all", "any", "next", "iter", "repr", "format", "ord", "chr", "hex",
        "bin", "oct", "id", "hash", "dir", "vars", "locals", "globals"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let commentPattern = #"#.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: commentPattern, type: .comment, options: .anchorsMatchLines))
        
        // Triple-quoted strings (multi-line)
        let tripleDoublePattern = #"\"\"\"[\s\S]*?\"\"\""#
        tokens.append(contentsOf: findMatches(code, pattern: tripleDoublePattern, type: .string))
        
        let tripleSinglePattern = #"'''[\s\S]*?'''"#
        tokens.append(contentsOf: findMatches(code, pattern: tripleSinglePattern, type: .string))
        
        // Regular strings
        let doubleQuotePattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: doubleQuotePattern, type: .string))
        
        let singleQuotePattern = #"'(?:[^'\\]|\\.)*'"#
        tokens.append(contentsOf: findMatches(code, pattern: singleQuotePattern, type: .string))
        
        // F-strings prefix
        let fstringPattern = #"[fFrRbBuU]+(?=[\"'])"#
        tokens.append(contentsOf: findMatches(code, pattern: fstringPattern, type: .keyword))
        
        // Decorators
        let decoratorPattern = #"@[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: decoratorPattern, type: .function))
        
        // Numbers
        let numberPattern = #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?[jJ]?\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Function definitions
        let funcDefPattern = #"(?<=\bdef\s)[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: funcDefPattern, type: .function))
        
        // Class definitions
        let classDefPattern = #"(?<=\bclass\s)[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: classDefPattern, type: .type))
        
        // Keywords and builtins
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if builtins.contains(word) {
                        tokens.append(Token(type: .function, range: range))
                    }
                }
            }
        }
        
        return tokens
    }
}

// MARK: - JavaScript/TypeScript Highlighter

struct JavaScriptHighlighter {
    static let shared = JavaScriptHighlighter()
    
    private let keywords = Set([
        "async", "await", "break", "case", "catch", "class", "const",
        "continue", "debugger", "default", "delete", "do", "else", "export",
        "extends", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "return", "static", "super", "switch",
        "this", "throw", "try", "typeof", "var", "void", "while", "with",
        "yield", "enum", "implements", "interface", "package", "private",
        "protected", "public", "abstract", "as", "from", "get", "set",
        "type", "declare", "namespace", "module", "readonly", "keyof",
        "infer", "never", "unknown", "any", "boolean", "number", "string",
        "symbol", "bigint", "object"
    ])
    
    private let constants = Set([
        "true", "false", "null", "undefined", "NaN", "Infinity"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Single-line comments
        let singleCommentPattern = #"//.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: singleCommentPattern, type: .comment, options: .anchorsMatchLines))
        
        // Multi-line comments
        let multiCommentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: multiCommentPattern, type: .comment))
        
        // Template literals
        let templatePattern = #"`(?:[^`\\]|\\.)*`"#
        tokens.append(contentsOf: findMatches(code, pattern: templatePattern, type: .string))
        
        // Regular strings
        let doubleQuotePattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: doubleQuotePattern, type: .string))
        
        let singleQuotePattern = #"'(?:[^'\\]|\\.)*'"#
        tokens.append(contentsOf: findMatches(code, pattern: singleQuotePattern, type: .string))
        
        // Numbers
        let numberPattern = #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Function declarations
        let funcDeclPattern = #"(?<=\bfunction\s)[a-zA-Z_$][a-zA-Z0-9_$]*"#
        tokens.append(contentsOf: findMatches(code, pattern: funcDeclPattern, type: .function))
        
        // Arrow functions and method definitions
        let arrowFuncPattern = #"[a-zA-Z_$][a-zA-Z0-9_$]*(?=\s*(?:=>|\())"#
        tokens.append(contentsOf: findMatches(code, pattern: arrowFuncPattern, type: .function))
        
        // Keywords and constants
        let wordPattern = #"\b[a-zA-Z_$][a-zA-Z0-9_$]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if constants.contains(word) {
                        tokens.append(Token(type: .number, range: range))
                    }
                }
            }
        }
        
        // Operators
        let operatorPattern = #"===|!==|==|!=|<=|>=|&&|\|\||=>|\+\+|--|\+=|-=|\*=|/="#
        tokens.append(contentsOf: findMatches(code, pattern: operatorPattern, type: .operator))
        
        return tokens
    }
}

// MARK: - JSON Highlighter

struct JSONHighlighter {
    static let shared = JSONHighlighter()
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Property keys (before colon)
        let keyPattern = #""[^"]*"(?=\s*:)"#
        tokens.append(contentsOf: findMatches(code, pattern: keyPattern, type: .property))
        
        // String values
        let stringPattern = #"(?<=:\s*)"[^"]*""#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Numbers
        let numberPattern = #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Booleans and null
        let boolPattern = #"\b(?:true|false|null)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: boolPattern, type: .keyword))
        
        // Punctuation
        let punctPattern = #"[\{\}\[\]:,]"#
        tokens.append(contentsOf: findMatches(code, pattern: punctPattern, type: .punctuation))
        
        return tokens
    }
}

// MARK: - YAML Highlighter

struct YAMLHighlighter {
    static let shared = YAMLHighlighter()
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let commentPattern = #"#.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: commentPattern, type: .comment, options: .anchorsMatchLines))
        
        // Keys (before colon)
        let keyPattern = #"^[\s]*[a-zA-Z_][a-zA-Z0-9_-]*(?=\s*:)"#
        tokens.append(contentsOf: findMatches(code, pattern: keyPattern, type: .property, options: .anchorsMatchLines))
        
        // Quoted strings
        let doubleQuotePattern = #""[^"]*""#
        tokens.append(contentsOf: findMatches(code, pattern: doubleQuotePattern, type: .string))
        
        let singleQuotePattern = #"'[^']*'"#
        tokens.append(contentsOf: findMatches(code, pattern: singleQuotePattern, type: .string))
        
        // Numbers
        let numberPattern = #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Booleans and null
        let boolPattern = #"\b(?:true|false|yes|no|on|off|null|~)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: boolPattern, type: .keyword))
        
        // Anchors and aliases
        let anchorPattern = #"[&*][a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: anchorPattern, type: .variable))
        
        return tokens
    }
}

// MARK: - HTML/XML Highlighter

struct HTMLHighlighter {
    static let shared = HTMLHighlighter()
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let commentPattern = #"<!--[\s\S]*?-->"#
        tokens.append(contentsOf: findMatches(code, pattern: commentPattern, type: .comment))
        
        // Tag names
        let tagPattern = #"(?<=</?)[a-zA-Z][a-zA-Z0-9-]*"#
        tokens.append(contentsOf: findMatches(code, pattern: tagPattern, type: .keyword))
        
        // Attribute names
        let attrPattern = #"\s[a-zA-Z][a-zA-Z0-9-]*(?=\s*=)"#
        tokens.append(contentsOf: findMatches(code, pattern: attrPattern, type: .property))
        
        // Attribute values
        let attrValuePattern = #""[^"]*"|'[^']*'"#
        tokens.append(contentsOf: findMatches(code, pattern: attrValuePattern, type: .string))
        
        // Brackets
        let bracketPattern = #"</|/>|<|>"#
        tokens.append(contentsOf: findMatches(code, pattern: bracketPattern, type: .punctuation))
        
        return tokens
    }
}

// MARK: - CSS Highlighter

struct CSSHighlighter {
    static let shared = CSSHighlighter()
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let commentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: commentPattern, type: .comment))
        
        // Selectors (class, id, element)
        let selectorPattern = #"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#
        tokens.append(contentsOf: findMatches(code, pattern: selectorPattern, type: .function))
        
        // Property names
        let propPattern = #"[a-zA-Z-]+(?=\s*:)"#
        tokens.append(contentsOf: findMatches(code, pattern: propPattern, type: .property))
        
        // Strings
        let stringPattern = #""[^"]*"|'[^']*'"#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Numbers with units
        let numberPattern = #"-?\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Colors
        let colorPattern = #"#[0-9a-fA-F]{3,8}\b"#
        tokens.append(contentsOf: findMatches(code, pattern: colorPattern, type: .number))
        
        // Important and other keywords
        let keywordPattern = #"!important|@[a-zA-Z-]+"#
        tokens.append(contentsOf: findMatches(code, pattern: keywordPattern, type: .keyword))
        
        return tokens
    }
}

// MARK: - Rust Highlighter

struct RustHighlighter {
    static let shared = RustHighlighter()
    
    private let keywords = Set([
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while", "abstract", "become", "box", "do",
        "final", "macro", "override", "priv", "try", "typeof", "unsized",
        "virtual", "yield"
    ])
    
    private let types = Set([
        "i8", "i16", "i32", "i64", "i128", "isize",
        "u8", "u16", "u32", "u64", "u128", "usize",
        "f32", "f64", "bool", "char", "str", "String",
        "Vec", "Option", "Result", "Box", "Rc", "Arc",
        "HashMap", "HashSet", "BTreeMap", "BTreeSet"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let singleCommentPattern = #"//.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: singleCommentPattern, type: .comment, options: .anchorsMatchLines))
        
        let multiCommentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: multiCommentPattern, type: .comment))
        
        // Strings
        let stringPattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Raw strings (simplified pattern - matches r"..." and basic r#"..."#)
        let rawStringPattern = ##"r#*"[^"]*"#*"##
        tokens.append(contentsOf: findMatches(code, pattern: rawStringPattern, type: .string))
        
        // Characters
        let charPattern = #"'(?:[^'\\]|\\.)'"#
        tokens.append(contentsOf: findMatches(code, pattern: charPattern, type: .string))
        
        // Lifetimes
        let lifetimePattern = #"'[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: lifetimePattern, type: .variable))
        
        // Attributes
        let attrPattern = #"#\[[\s\S]*?\]"#
        tokens.append(contentsOf: findMatches(code, pattern: attrPattern, type: .function))
        
        // Numbers
        let numberPattern = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?[\d_]+)?(?:_?(?:i|u)(?:8|16|32|64|128|size)|_?f(?:32|64))?)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Macros
        let macroPattern = #"[a-zA-Z_][a-zA-Z0-9_]*!"#
        tokens.append(contentsOf: findMatches(code, pattern: macroPattern, type: .function))
        
        // Keywords and types
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if types.contains(word) {
                        tokens.append(Token(type: .type, range: range))
                    }
                }
            }
        }
        
        return tokens
    }
}

// MARK: - Go Highlighter

struct GoHighlighter {
    static let shared = GoHighlighter()
    
    private let keywords = Set([
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var"
    ])
    
    private let types = Set([
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
        "int", "int8", "int16", "int32", "int64", "rune", "string",
        "uint", "uint8", "uint16", "uint32", "uint64", "uintptr"
    ])
    
    private let constants = Set([
        "true", "false", "nil", "iota"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let singleCommentPattern = #"//.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: singleCommentPattern, type: .comment, options: .anchorsMatchLines))
        
        let multiCommentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: multiCommentPattern, type: .comment))
        
        // Strings
        let stringPattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Raw strings
        let rawStringPattern = #"`[^`]*`"#
        tokens.append(contentsOf: findMatches(code, pattern: rawStringPattern, type: .string))
        
        // Runes
        let runePattern = #"'(?:[^'\\]|\\.)+'"#
        tokens.append(contentsOf: findMatches(code, pattern: runePattern, type: .string))
        
        // Numbers
        let numberPattern = #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?i?)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Function declarations
        let funcPattern = #"(?<=\bfunc\s)[a-zA-Z_][a-zA-Z0-9_]*"#
        tokens.append(contentsOf: findMatches(code, pattern: funcPattern, type: .function))
        
        // Keywords, types, and constants
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    } else if types.contains(word) {
                        tokens.append(Token(type: .type, range: range))
                    } else if constants.contains(word) {
                        tokens.append(Token(type: .number, range: range))
                    }
                }
            }
        }
        
        return tokens
    }
}

// MARK: - C/C++ Highlighter

struct CHighlighter {
    static let shared = CHighlighter()
    
    private let keywords = Set([
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof",
        "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local",
        // C++ additions
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor",
        "bool", "catch", "class", "compl", "concept", "consteval", "constexpr",
        "constinit", "const_cast", "co_await", "co_return", "co_yield", "decltype",
        "delete", "dynamic_cast", "explicit", "export", "false", "friend",
        "mutable", "namespace", "new", "noexcept", "not", "not_eq", "nullptr",
        "operator", "or", "or_eq", "private", "protected", "public", "reinterpret_cast",
        "requires", "static_assert", "static_cast", "template", "this", "throw",
        "true", "try", "typeid", "typename", "using", "virtual", "wchar_t", "xor", "xor_eq"
    ])
    
    private init() {}
    
    func tokenize(_ code: String) -> [Token] {
        var tokens: [Token] = []
        
        // Comments
        let singleCommentPattern = #"//.*$"#
        tokens.append(contentsOf: findMatches(code, pattern: singleCommentPattern, type: .comment, options: .anchorsMatchLines))
        
        let multiCommentPattern = #"/\*[\s\S]*?\*/"#
        tokens.append(contentsOf: findMatches(code, pattern: multiCommentPattern, type: .comment))
        
        // Preprocessor directives
        let preprocessorPattern = #"^\s*#\s*\w+"#
        tokens.append(contentsOf: findMatches(code, pattern: preprocessorPattern, type: .keyword, options: .anchorsMatchLines))
        
        // Strings
        let stringPattern = #""(?:[^"\\]|\\.)*""#
        tokens.append(contentsOf: findMatches(code, pattern: stringPattern, type: .string))
        
        // Characters
        let charPattern = #"'(?:[^'\\]|\\.)+'"#
        tokens.append(contentsOf: findMatches(code, pattern: charPattern, type: .string))
        
        // Include headers
        let includePattern = #"<[^>]+>"#
        tokens.append(contentsOf: findMatches(code, pattern: includePattern, type: .string))
        
        // Numbers
        let numberPattern = #"\b(?:0[xX][0-9a-fA-F]+[uUlL]*|0[bB][01]+[uUlL]*|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?[fFlLuU]*)\b"#
        tokens.append(contentsOf: findMatches(code, pattern: numberPattern, type: .number))
        
        // Keywords
        let wordPattern = #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                if let range = Range(match.range, in: code) {
                    let word = String(code[range])
                    if keywords.contains(word) {
                        tokens.append(Token(type: .keyword, range: range))
                    }
                }
            }
        }
        
        return tokens
    }
}

// MARK: - Helper Functions

/// Find all matches for a pattern and return tokens
private func findMatches(_ code: String, pattern: String, type: TokenType, options: NSRegularExpression.Options = []) -> [Token] {
    var tokens: [Token] = []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return tokens
    }
    
    let nsRange = NSRange(code.startIndex..., in: code)
    for match in regex.matches(in: code, range: nsRange) {
        if let range = Range(match.range, in: code) {
            tokens.append(Token(type: type, range: range))
        }
    }
    
    return tokens
}

