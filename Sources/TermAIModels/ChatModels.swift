import Foundation

// MARK: - Token Estimation

/// Utility for estimating token counts from text
public enum TokenEstimator {
    /// Default characters per token (conservative estimate for English text)
    private static let defaultCharsPerToken: Double = 3.8
    
    /// Get model-specific characters per token ratio for more accurate estimation
    public static func charsPerToken(for model: String) -> Double {
        let lowercased = model.lowercased()
        
        // Claude models use a more aggressive tokenizer (~3.5 chars/token)
        if lowercased.contains("claude") {
            return 3.5
        }
        
        // GPT-4, GPT-5, and o-series models average ~4 chars/token
        if lowercased.contains("gpt-4") || lowercased.contains("gpt-5") ||
           lowercased.hasPrefix("o1") || lowercased.hasPrefix("o3") || lowercased.hasPrefix("o4") {
            return 4.0
        }
        
        // LLaMA/Mistral/local models often have similar tokenization to GPT
        if lowercased.contains("llama") || lowercased.contains("mistral") ||
           lowercased.contains("qwen") || lowercased.contains("gemma") {
            return 4.0
        }
        
        // Default fallback
        return defaultCharsPerToken
    }
    
    /// Estimate token count from text using model-specific ratio
    public static func estimateTokens(_ text: String, model: String = "") -> Int {
        let ratio = model.isEmpty ? defaultCharsPerToken : charsPerToken(for: model)
        return Int(ceil(Double(text.count) / ratio))
    }
    
    /// Estimate tokens from a collection of strings using model-specific ratio
    public static func estimateTokens(_ texts: [String], model: String = "") -> Int {
        texts.reduce(0) { $0 + estimateTokens($1, model: model) }
    }
    
    /// Get the context window limit for a model (in tokens)
    public static func contextLimit(for modelId: String) -> Int {
        // GPT-5 series
        if modelId.contains("gpt-5") { return 128_000 }
        
        // GPT-4 series
        if modelId.contains("gpt-4o") || modelId.contains("gpt-4.1") { return 128_000 }
        if modelId.contains("gpt-4-turbo") { return 128_000 }
        
        // O-series reasoning models
        if modelId.hasPrefix("o4") || modelId.hasPrefix("o3") || modelId.hasPrefix("o1") { return 200_000 }
        
        // Claude 4.x series
        if modelId.contains("claude-opus-4") || modelId.contains("claude-sonnet-4") || modelId.contains("claude-haiku-4") {
            return 200_000
        }
        
        // Claude 3.7/3.5 series
        if modelId.contains("claude-3-7") || modelId.contains("claude-3-5") { return 200_000 }
        
        // Default for unknown models (conservative)
        return 32_000
    }
    
    /// Get recommended max context usage (leaving room for response)
    public static func maxContextUsage(for modelId: String) -> Int {
        let limit = contextLimit(for: modelId)
        // Reserve 25% for response generation
        return Int(Double(limit) * 0.75)
    }
}

// MARK: - Task Checklist

public enum TaskStatus: String, Codable, Equatable, Sendable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    
    public var emoji: String {
        switch self {
        case .pending: return "○"
        case .inProgress: return "→"
        case .completed: return "✓"
        case .failed: return "✗"
        case .skipped: return "⊘"
        }
    }
}

public struct TaskChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let description: String
    public var status: TaskStatus
    public var verificationNote: String?
    
    public init(id: Int, description: String, status: TaskStatus, verificationNote: String? = nil) {
        self.id = id
        self.description = description
        self.status = status
        self.verificationNote = verificationNote
    }
    
    public var displayString: String {
        var str = "\(status.emoji) \(id). \(description)"
        if let note = verificationNote {
            str += " [\(note)]"
        }
        return str
    }
}

public struct TaskChecklist: Codable, Equatable, Sendable {
    public var items: [TaskChecklistItem]
    public var goalDescription: String
    
    public init(from plan: [String], goal: String) {
        self.goalDescription = goal
        self.items = plan.enumerated().map { idx, step in
            TaskChecklistItem(id: idx + 1, description: step, status: .pending, verificationNote: nil)
        }
    }
    
    public mutating func updateStatus(for itemId: Int, status: TaskStatus, note: String? = nil) {
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx].status = status
            if let note = note {
                items[idx].verificationNote = note
            }
        }
    }
    
    public mutating func markInProgress(_ itemId: Int) {
        updateStatus(for: itemId, status: .inProgress)
    }
    
    public mutating func markCompleted(_ itemId: Int, note: String? = nil) {
        updateStatus(for: itemId, status: .completed, note: note)
    }
    
    public mutating func markFailed(_ itemId: Int, note: String? = nil) {
        updateStatus(for: itemId, status: .failed, note: note)
    }
    
    public var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }
    
    public var progressPercent: Int {
        guard !items.isEmpty else { return 0 }
        return Int((Double(completedCount) / Double(items.count)) * 100)
    }
    
    public var currentItem: TaskChecklistItem? {
        items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending }
    }
    
    public var isComplete: Bool {
        items.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }
    
    public var displayString: String {
        var str = "CHECKLIST (\(completedCount)/\(items.count) completed - \(progressPercent)%):\n"
        str += items.map { $0.displayString }.joined(separator: "\n")
        return str
    }
    
    /// Get remaining items that haven't been completed or skipped
    public var remainingItems: [TaskChecklistItem] {
        items.filter { $0.status == .pending || $0.status == .inProgress || $0.status == .failed }
    }
}

// MARK: - Line Range

/// Represents a line range (start and end are 1-indexed, inclusive)
public struct LineRange: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let end: Int
    
    public init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    
    /// Single line
    public init(line: Int) {
        self.start = line
        self.end = line
    }
    
    /// Parse a range string like "10-50" or "100"
    public static func parse(_ str: String) -> LineRange? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-")
            guard parts.count == 2,
                  let start = Int(parts[0]),
                  let end = Int(parts[1]) else { return nil }
            return LineRange(start: start, end: end)
        } else if let line = Int(trimmed) {
            return LineRange(line: line)
        }
        return nil
    }
    
    /// Parse multiple ranges from a comma-separated string like "10-50,80-100"
    public static func parseMultiple(_ str: String) -> [LineRange] {
        str.split(separator: ",").compactMap { parse(String($0)) }
    }
    
    public var description: String {
        start == end ? "L\(start)" : "L\(start)-\(end)"
    }
    
    /// Check if a line number is within this range
    public func contains(_ line: Int) -> Bool {
        line >= start && line <= end
    }
}

// MARK: - Pinned Context Type

/// Type of attached context
public enum PinnedContextType: String, Codable, Equatable, Sendable {
    case file       // File from the filesystem
    case terminal   // Terminal output
    case snippet    // User-provided code snippet
}
