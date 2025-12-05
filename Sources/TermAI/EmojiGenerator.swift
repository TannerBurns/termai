import Foundation
import os.log

private let emojiLogger = Logger(subsystem: "com.termai.app", category: "EmojiGenerator")

/// Represents an existing favorite command with its emoji
struct ExistingFavorite {
    let command: String
    let emoji: String
}

/// Service for generating contextually appropriate emoji for terminal commands using AI
actor EmojiGenerator {
    static let shared = EmojiGenerator()
    
    private init() {}
    
    /// Default emoji to use when AI generation fails or is not configured
    static let defaultEmoji = "⚡"
    
    /// Fallback emojis to use when AI is not configured
    private static let fallbackEmojis = [
        "⚡", "🔥", "💫", "✨", "🌟", "⭐", "💡", "🎯", "🎨", "🎮",
        "🔧", "⚙️", "🛠️", "🔩", "🔑", "🏷️", "📌", "📎", "✏️", "🖊️",
        "💎", "🔮", "🎪", "🎭", "🎬", "🎵", "🎹", "🎸", "🎺", "🎻",
        "🌈", "☀️", "🌙", "⛅", "❄️", "🌊", "🌸", "🌺", "🌻", "🍀",
        "🍎", "🍊", "🍋", "🍇", "🍓", "🥝", "🥑", "🌶️", "🍕", "🍔",
        "🐳", "🐍", "🦀", "🐹", "🐦", "🦕", "🌿", "📦", "🧶", "🧪",
        "🏗️", "🚀", "🔨", "💻", "🔐", "🌐", "📂", "📋", "🔍", "🗑️"
    ]
    
    /// Generate an emoji for a command using AI, ensuring uniqueness
    /// Provides full context of existing commands and their emojis to AI
    /// Falls back to random selection if AI is not configured or fails
    /// - Parameters:
    ///   - command: The terminal command to generate an emoji for
    ///   - existingFavorites: List of existing favorite commands with their emojis (for context)
    func generateEmoji(for command: String, existingFavorites: [ExistingFavorite] = []) async -> String {
        let existingEmojis = Set(existingFavorites.map { $0.emoji })
        
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
                existingFavorites: existingFavorites
            )
            
            // If AI returned a duplicate, try once more with explicit instruction
            if existingEmojis.contains(emoji) {
                emojiLogger.debug("AI returned duplicate emoji '\(emoji)', retrying...")
                let retryEmoji = try await generateEmojiWithAI(
                    command: command,
                    provider: provider,
                    modelId: modelId,
                    existingFavorites: existingFavorites,
                    retryAttempt: true
                )
                
                if existingEmojis.contains(retryEmoji) {
                    emojiLogger.debug("AI retry still returned duplicate, using fallback")
                    return findUnusedFallbackEmoji(avoiding: existingEmojis)
                }
                
                emojiLogger.info("AI retry generated unique emoji '\(retryEmoji)' for command: \(command)")
                return retryEmoji
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
        // Shuffle fallback emojis for variety
        let shuffled = Self.fallbackEmojis.shuffled()
        
        for emoji in shuffled {
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
    
    /// Generate emoji using AI with full context of existing commands
    private func generateEmojiWithAI(
        command: String,
        provider: ProviderType,
        modelId: String,
        existingFavorites: [ExistingFavorite],
        retryAttempt: Bool = false
    ) async throws -> String {
        let systemPrompt = """
        You are an emoji selector. Your task is to pick ONE emoji that best represents a terminal command.
        Choose an emoji that visually represents what the command does or the tool it uses.
        Reply with ONLY the emoji character, nothing else. No text, no explanation, just the emoji.
        """
        
        // Build user prompt with context
        var userPrompt: String
        
        if existingFavorites.isEmpty {
            userPrompt = """
            Pick one emoji that best represents this terminal command:
            \(command)
            """
        } else {
            // Show existing commands and their emojis for context
            let existingList = existingFavorites
                .map { "\($0.emoji) → \($0.command)" }
                .joined(separator: "\n")
            
            let takenEmojis = existingFavorites.map { $0.emoji }.joined(separator: " ")
            
            userPrompt = """
            Here are the existing favorite commands and their emojis:
            \(existingList)
            
            Pick one UNIQUE emoji (not \(takenEmojis)) that best represents this NEW command:
            \(command)
            """
            
            if retryAttempt {
                userPrompt += "\n\nIMPORTANT: You must choose a DIFFERENT emoji that is NOT already used above!"
            }
        }
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            provider: provider,
            modelId: modelId,
            temperature: retryAttempt ? 1.0 : 0.8, // Higher temperature on retry for more variety
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
        
        // Iterate through characters (grapheme clusters) to find the first emoji
        for char in trimmed {
            // Check if this character contains an emoji with presentation
            for scalar in char.unicodeScalars {
                if scalar.properties.isEmoji && scalar.properties.isEmojiPresentation {
                    return String(char)
                }
            }
        }
        
        // Fallback: check for any emoji character (some emojis don't have isEmojiPresentation)
        for char in trimmed {
            if char.unicodeScalars.first?.properties.isEmoji == true {
                return String(char)
            }
        }
        
        return nil
    }
}

