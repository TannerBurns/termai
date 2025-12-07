import Foundation

/// A favorite command that can be quickly executed from the terminal toolbar
struct FavoriteCommand: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var command: String
    var emoji: String  // AI-generated or user-customized
    var name: String?  // Optional user-friendly name
    
    init(id: UUID = UUID(), command: String, emoji: String = "⚡", name: String? = nil) {
        self.id = id
        self.command = command
        self.emoji = emoji
        self.name = name
    }
    
    /// Display text for tooltips and lists
    var displayText: String {
        if let name = name, !name.isEmpty {
            return "\(name): \(command)"
        }
        return command
    }
    
    /// Short display for settings list
    var shortDisplay: String {
        if let name = name, !name.isEmpty {
            return name
        }
        // Truncate long commands
        if command.count > 40 {
            return String(command.prefix(37)) + "..."
        }
        return command
    }
}

