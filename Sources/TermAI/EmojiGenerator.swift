import Foundation
import os.log

private let emojiLogger = Logger(subsystem: "com.termai.app", category: "EmojiGenerator")

/// Service for generating contextually appropriate emoji for terminal commands using AI
actor EmojiGenerator {
    static let shared = EmojiGenerator()
    
    private init() {}
    
    /// Default emoji to use when AI generation fails or is not configured
    static let defaultEmoji = "⚡"
    
    /// Fallback emojis to use when we need unique ones
    private static let fallbackEmojis = [
        "⚡", "🔥", "💫", "✨", "🌟", "⭐", "💡", "🎯", "🎨", "🎮",
        "🔧", "⚙️", "🛠️", "🔩", "🔑", "🏷️", "📌", "📎", "✏️", "🖊️",
        "💎", "🔮", "🎪", "🎭", "🎬", "🎵", "🎹", "🎸", "🎺", "🎻",
        "🌈", "☀️", "🌙", "⛅", "❄️", "🌊", "🌸", "🌺", "🌻", "🍀",
        "🍎", "🍊", "🍋", "🍇", "🍓", "🥝", "🥑", "🌶️", "🍕", "🍔"
    ]
    
    /// Common emoji fallbacks for known command patterns
    private static let commandEmojiMap: [String: String] = [
        "git": "🌿",
        "npm": "📦",
        "yarn": "🧶",
        "pnpm": "📦",
        "cargo": "📦",
        "swift": "🐦",
        "python": "🐍",
        "pip": "🐍",
        "docker": "🐳",
        "kubectl": "☸️",
        "cd": "📂",
        "ls": "📋",
        "cat": "🐱",
        "grep": "🔍",
        "find": "🔎",
        "rm": "🗑️",
        "cp": "📄",
        "mv": "📁",
        "mkdir": "📁",
        "touch": "✨",
        "echo": "💬",
        "curl": "🌐",
        "wget": "⬇️",
        "ssh": "🔐",
        "vim": "📝",
        "nano": "📝",
        "code": "💻",
        "make": "🔨",
        "cmake": "🔨",
        "go": "🐹",
        "rust": "🦀",
        "node": "💚",
        "deno": "🦕",
        "bun": "🥟",
        "brew": "🍺",
        "apt": "📦",
        "yum": "📦",
        "test": "🧪",
        "build": "🏗️",
        "run": "🚀",
        "start": "▶️",
        "stop": "⏹️",
        "restart": "🔄",
        "deploy": "🚀",
        "push": "⬆️",
        "pull": "⬇️",
        "commit": "💾",
        "merge": "🔀",
        "rebase": "🔀",
        "checkout": "🔄",
        "branch": "🌿",
        "log": "📜",
        "status": "📊",
        "diff": "📊",
        "clean": "🧹",
        "install": "📥",
        "uninstall": "📤",
        "update": "🔄",
        "upgrade": "⬆️",
    ]
    
    /// Generate an emoji for a command using AI, ensuring uniqueness
    /// Falls back to pattern matching and default emoji if AI is not configured or fails
    /// - Parameters:
    ///   - command: The terminal command to generate an emoji for
    ///   - existingEmojis: Set of emojis already in use (to ensure uniqueness)
    func generateEmoji(for command: String, avoiding existingEmojis: Set<String> = []) async -> String {
        // First, try pattern matching for common commands
        if let patternEmoji = matchCommandPattern(command), !existingEmojis.contains(patternEmoji) {
            emojiLogger.debug("Using pattern-matched emoji '\(patternEmoji)' for command: \(command)")
            return patternEmoji
        }
        
        // Try AI generation if configured
        let settings = AgentSettings.shared
        guard let provider = settings.terminalSuggestionsProvider,
              let modelId = settings.terminalSuggestionsModelId else {
            emojiLogger.debug("AI not configured, using fallback emoji for: \(command)")
            return findUnusedFallbackEmoji(avoiding: existingEmojis)
        }
        
        do {
            let emoji = try await generateEmojiWithAI(
                command: command,
                provider: provider,
                modelId: modelId,
                avoiding: existingEmojis
            )
            
            // If AI returned a duplicate, try to get a unique one
            if existingEmojis.contains(emoji) {
                emojiLogger.debug("AI returned duplicate emoji, finding unique fallback")
                return findUnusedFallbackEmoji(avoiding: existingEmojis)
            }
            
            emojiLogger.info("AI generated emoji '\(emoji)' for command: \(command)")
            return emoji
        } catch {
            emojiLogger.warning("AI emoji generation failed: \(error.localizedDescription)")
            return findUnusedFallbackEmoji(avoiding: existingEmojis)
        }
    }
    
    /// Find an unused emoji from the fallback list
    private func findUnusedFallbackEmoji(avoiding existingEmojis: Set<String>) -> String {
        // First try the fallback list
        for emoji in Self.fallbackEmojis {
            if !existingEmojis.contains(emoji) {
                return emoji
            }
        }
        
        // If all fallbacks are used, try emojis from the command map
        for emoji in Self.commandEmojiMap.values {
            if !existingEmojis.contains(emoji) {
                return emoji
            }
        }
        
        // Last resort: generate a number badge emoji
        for i in 1...50 {
            let numberEmoji = "\(i)️⃣"
            if !existingEmojis.contains(numberEmoji) {
                return numberEmoji
            }
        }
        
        return Self.defaultEmoji
    }
    
    /// Match command against known patterns to get a relevant emoji
    private func matchCommandPattern(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        
        // Check for exact first word match
        if let emoji = Self.commandEmojiMap[firstWord] {
            return emoji
        }
        
        // Check for subcommand patterns (e.g., "git push", "npm install")
        for (pattern, emoji) in Self.commandEmojiMap {
            if trimmed.hasPrefix(pattern) {
                return emoji
            }
        }
        
        // Check for keyword matches in the full command
        for (keyword, emoji) in Self.commandEmojiMap {
            if trimmed.contains(keyword) {
                return emoji
            }
        }
        
        return nil
    }
    
    /// Generate emoji using AI
    private func generateEmojiWithAI(
        command: String,
        provider: ProviderType,
        modelId: String,
        avoiding existingEmojis: Set<String> = []
    ) async throws -> String {
        var systemPrompt = """
        You are an emoji selector. Your task is to pick ONE emoji that best represents a terminal command.
        Reply with ONLY the emoji character, nothing else. No text, no explanation, just the emoji.
        """
        
        // Add avoidance instructions if there are existing emojis
        if !existingEmojis.isEmpty {
            let emojiList = existingEmojis.joined(separator: " ")
            systemPrompt += "\n\nIMPORTANT: Do NOT use any of these emojis (they are already taken): \(emojiList)"
        }
        
        let userPrompt = """
        Pick one emoji that best represents this terminal command:
        \(command)
        """
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            provider: provider,
            modelId: modelId,
            temperature: 0.8, // Slightly higher temperature for more variety
            maxTokens: 10,
            timeout: 10,
            requestType: .terminalSuggestion
        )
        
        // Extract the first emoji from the response
        let emoji = extractEmoji(from: response)
        return emoji ?? Self.defaultEmoji
    }
    
    /// Extract the first emoji from a string
    private func extractEmoji(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to get the first character if it's an emoji
        for scalar in trimmed.unicodeScalars {
            if scalar.properties.isEmoji && scalar.properties.isEmojiPresentation {
                // Found a proper emoji, extract the full grapheme cluster
                if let firstChar = trimmed.first {
                    return String(firstChar)
                }
            }
        }
        
        // Fallback: check for emoji in a different way
        for char in trimmed {
            if char.unicodeScalars.first?.properties.isEmoji == true {
                return String(char)
            }
        }
        
        return nil
    }
}

