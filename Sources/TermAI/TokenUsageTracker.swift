import Foundation

// MARK: - Request Type

/// Type of API request being tracked
enum UsageRequestType: String, Codable, CaseIterable {
    case chat = "Chat"
    case toolCall = "Tool Call"
    case titleGeneration = "Title Generation"
    case summarization = "Summarization"
    case planning = "Planning"
    case reflection = "Reflection"
    case terminalSuggestion = "Terminal Suggestion"
    case suggestionResearch = "Suggestion Research"
    case testRunner = "Test Runner"
}

// MARK: - Token Usage Record

/// A single token usage record from an API call
struct TokenUsageRecord: Codable, Identifiable {
    var id: UUID = UUID()
    let timestamp: Date
    let provider: String
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let isEstimated: Bool  // true if tokens were estimated, false if from API
    let requestType: UsageRequestType
    let toolCallCount: Int  // Number of tool calls in this request (0 for non-tool requests)
    
    var totalTokens: Int { promptTokens + completionTokens }
    
    /// Hour-truncated timestamp for grouping
    var hourBucket: Date {
        Calendar.current.dateInterval(of: .hour, for: timestamp)?.start ?? timestamp
    }
    
    /// Day-truncated timestamp for daily aggregation
    var dayBucket: Date {
        Calendar.current.startOfDay(for: timestamp)
    }
    
    // Backward compatibility: provide default values for new fields
    init(
        id: UUID = UUID(),
        timestamp: Date,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        isEstimated: Bool,
        requestType: UsageRequestType = .chat,
        toolCallCount: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isEstimated = isEstimated
        self.requestType = requestType
        self.toolCallCount = toolCallCount
    }
    
    // Custom decoding for backward compatibility with existing data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        completionTokens = try container.decode(Int.self, forKey: .completionTokens)
        isEstimated = try container.decode(Bool.self, forKey: .isEstimated)
        requestType = try container.decodeIfPresent(UsageRequestType.self, forKey: .requestType) ?? .chat
        toolCallCount = try container.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, provider, model, promptTokens, completionTokens, isEstimated, requestType, toolCallCount
    }
}

// MARK: - Daily Usage Data

/// Container for all usage records in a single day
struct DailyUsageData: Codable {
    var records: [TokenUsageRecord]
    
    init(records: [TokenUsageRecord] = []) {
        self.records = records
    }
}

// MARK: - Aggregated Usage

/// Aggregated usage data for charts
struct AggregatedUsage: Identifiable {
    let id = UUID()
    let date: Date
    let provider: String?
    let model: String?
    let promptTokens: Int
    let completionTokens: Int
    let requestCount: Int
    let toolCallCount: Int
    
    var totalTokens: Int { promptTokens + completionTokens }
    
    init(
        date: Date,
        provider: String? = nil,
        model: String? = nil,
        promptTokens: Int,
        completionTokens: Int,
        requestCount: Int = 0,
        toolCallCount: Int = 0
    ) {
        self.date = date
        self.provider = provider
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.requestCount = requestCount
        self.toolCallCount = toolCallCount
    }
}

/// Aggregated request type data
struct RequestTypeUsage: Identifiable {
    let id = UUID()
    let requestType: UsageRequestType
    let count: Int
    let totalTokens: Int
}

// MARK: - Time Range

enum UsageTimeRange: String, CaseIterable {
    case today = "Today"
    case week = "Last 7 Days"
    case month = "Last 30 Days"
    
    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }
    
    var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }
}

// MARK: - Token Usage Tracker

/// Singleton for tracking and persisting token usage data
@MainActor
final class TokenUsageTracker: ObservableObject {
    static let shared = TokenUsageTracker()
    
    /// Retention period in days
    private let retentionDays: Int = 30
    
    /// In-memory cache of loaded data (keyed by date string)
    private var cache: [String: DailyUsageData] = [:]
    
    /// Published for UI updates
    @Published private(set) var lastUpdated: Date = Date()
    
    private init() {
        // Clean up old data on init
        Task {
            await cleanupOldData()
        }
    }
    
    // MARK: - Recording Usage
    
    /// Record a new token usage entry
    func recordUsage(
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        isEstimated: Bool = false,
        requestType: UsageRequestType = .chat,
        toolCallCount: Int = 0
    ) {
        let record = TokenUsageRecord(
            timestamp: Date(),
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            isEstimated: isEstimated,
            requestType: requestType,
            toolCallCount: toolCallCount
        )
        
        let dateKey = dateKeyForDate(record.timestamp)
        
        // Load or create daily data
        var dailyData = loadDailyData(for: dateKey) ?? DailyUsageData()
        dailyData.records.append(record)
        
        // Save and update cache
        saveDailyData(dailyData, for: dateKey)
        cache[dateKey] = dailyData
        lastUpdated = Date()
    }
    
    /// Record a tool call execution (for agent mode command tracking)
    func recordToolCall(
        provider: String,
        model: String,
        command: String
    ) {
        // Record as a tool call request with minimal token usage (just tracking the call)
        let record = TokenUsageRecord(
            timestamp: Date(),
            provider: provider,
            model: model,
            promptTokens: 0,
            completionTokens: 0,
            isEstimated: true,
            requestType: .toolCall,
            toolCallCount: 1
        )
        
        let dateKey = dateKeyForDate(record.timestamp)
        
        // Load or create daily data
        var dailyData = loadDailyData(for: dateKey) ?? DailyUsageData()
        dailyData.records.append(record)
        
        // Save and update cache
        saveDailyData(dailyData, for: dateKey)
        cache[dateKey] = dailyData
        lastUpdated = Date()
    }
    
    // MARK: - Querying Usage
    
    /// Get all records within a time range
    func getRecords(for range: UsageTimeRange) -> [TokenUsageRecord] {
        let startDate = range.startDate
        let endDate = Date()
        return getRecords(from: startDate, to: endDate)
    }
    
    /// Get all records between two dates
    func getRecords(from startDate: Date, to endDate: Date) -> [TokenUsageRecord] {
        var allRecords: [TokenUsageRecord] = []
        
        var currentDate = Calendar.current.startOfDay(for: startDate)
        let endDay = Calendar.current.startOfDay(for: endDate)
        
        while currentDate <= endDay {
            let dateKey = dateKeyForDate(currentDate)
            if let dailyData = loadDailyData(for: dateKey) {
                allRecords.append(contentsOf: dailyData.records.filter {
                    $0.timestamp >= startDate && $0.timestamp <= endDate
                })
            }
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? endDay.addingTimeInterval(1)
        }
        
        return allRecords.sorted { $0.timestamp < $1.timestamp }
    }
    
    /// Get usage aggregated by hour
    func getHourlyUsage(for range: UsageTimeRange) -> [AggregatedUsage] {
        let records = getRecords(for: range)
        return aggregateByHour(records)
    }
    
    /// Get usage aggregated by day
    func getDailyUsage(for range: UsageTimeRange) -> [AggregatedUsage] {
        let records = getRecords(for: range)
        return aggregateByDay(records)
    }
    
    /// Get usage aggregated by provider
    func getUsageByProvider(for range: UsageTimeRange) -> [AggregatedUsage] {
        let records = getRecords(for: range)
        return aggregateByProvider(records)
    }
    
    /// Get usage aggregated by model
    func getUsageByModel(for range: UsageTimeRange) -> [AggregatedUsage] {
        let records = getRecords(for: range)
        return aggregateByModel(records)
    }
    
    /// Get total usage summary for a time range
    func getTotalUsage(for range: UsageTimeRange) -> (prompt: Int, completion: Int, total: Int, requests: Int, toolCalls: Int) {
        let records = getRecords(for: range)
        let prompt = records.reduce(0) { $0 + $1.promptTokens }
        let completion = records.reduce(0) { $0 + $1.completionTokens }
        let requests = records.count
        let toolCalls = records.reduce(0) { $0 + $1.toolCallCount }
        return (prompt, completion, prompt + completion, requests, toolCalls)
    }
    
    /// Get unique providers in the data
    func getUniqueProviders(for range: UsageTimeRange) -> [String] {
        let records = getRecords(for: range)
        return Array(Set(records.map { $0.provider })).sorted()
    }
    
    /// Get unique models in the data
    func getUniqueModels(for range: UsageTimeRange) -> [String] {
        let records = getRecords(for: range)
        return Array(Set(records.map { $0.model })).sorted()
    }
    
    /// Get usage aggregated by request type
    func getUsageByRequestType(for range: UsageTimeRange) -> [RequestTypeUsage] {
        let records = getRecords(for: range)
        var grouped: [UsageRequestType: (count: Int, tokens: Int)] = [:]
        
        for record in records {
            let existing = grouped[record.requestType] ?? (0, 0)
            grouped[record.requestType] = (existing.count + 1, existing.tokens + record.totalTokens)
        }
        
        return grouped.map { type, data in
            RequestTypeUsage(requestType: type, count: data.count, totalTokens: data.tokens)
        }.sorted { $0.count > $1.count }
    }
    
    /// Get request counts by provider
    func getRequestsByProvider(for range: UsageTimeRange) -> [(provider: String, requests: Int, toolCalls: Int)] {
        let records = getRecords(for: range)
        var grouped: [String: (requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let existing = grouped[record.provider] ?? (0, 0)
            grouped[record.provider] = (existing.requests + 1, existing.toolCalls + record.toolCallCount)
        }
        
        return grouped.map { ($0.key, $0.value.requests, $0.value.toolCalls) }
            .sorted { $0.requests > $1.requests }
    }
    
    /// Get request counts by model
    func getRequestsByModel(for range: UsageTimeRange) -> [(model: String, requests: Int, toolCalls: Int)] {
        let records = getRecords(for: range)
        var grouped: [String: (requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let existing = grouped[record.model] ?? (0, 0)
            grouped[record.model] = (existing.requests + 1, existing.toolCalls + record.toolCallCount)
        }
        
        return grouped.map { ($0.key, $0.value.requests, $0.value.toolCalls) }
            .sorted { $0.requests > $1.requests }
    }
    
    // MARK: - Aggregation Helpers
    
    private func aggregateByHour(_ records: [TokenUsageRecord]) -> [AggregatedUsage] {
        var grouped: [Date: (prompt: Int, completion: Int, requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let hour = record.hourBucket
            let existing = grouped[hour] ?? (0, 0, 0, 0)
            grouped[hour] = (
                existing.prompt + record.promptTokens,
                existing.completion + record.completionTokens,
                existing.requests + 1,
                existing.toolCalls + record.toolCallCount
            )
        }
        
        return grouped.map { date, data in
            AggregatedUsage(
                date: date,
                promptTokens: data.prompt,
                completionTokens: data.completion,
                requestCount: data.requests,
                toolCallCount: data.toolCalls
            )
        }.sorted { $0.date < $1.date }
    }
    
    private func aggregateByDay(_ records: [TokenUsageRecord]) -> [AggregatedUsage] {
        var grouped: [Date: (prompt: Int, completion: Int, requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let day = record.dayBucket
            let existing = grouped[day] ?? (0, 0, 0, 0)
            grouped[day] = (
                existing.prompt + record.promptTokens,
                existing.completion + record.completionTokens,
                existing.requests + 1,
                existing.toolCalls + record.toolCallCount
            )
        }
        
        return grouped.map { date, data in
            AggregatedUsage(
                date: date,
                promptTokens: data.prompt,
                completionTokens: data.completion,
                requestCount: data.requests,
                toolCallCount: data.toolCalls
            )
        }.sorted { $0.date < $1.date }
    }
    
    private func aggregateByProvider(_ records: [TokenUsageRecord]) -> [AggregatedUsage] {
        var grouped: [String: (prompt: Int, completion: Int, requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let existing = grouped[record.provider] ?? (0, 0, 0, 0)
            grouped[record.provider] = (
                existing.prompt + record.promptTokens,
                existing.completion + record.completionTokens,
                existing.requests + 1,
                existing.toolCalls + record.toolCallCount
            )
        }
        
        return grouped.map { provider, data in
            AggregatedUsage(
                date: Date(),
                provider: provider,
                promptTokens: data.prompt,
                completionTokens: data.completion,
                requestCount: data.requests,
                toolCallCount: data.toolCalls
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
    
    private func aggregateByModel(_ records: [TokenUsageRecord]) -> [AggregatedUsage] {
        var grouped: [String: (prompt: Int, completion: Int, requests: Int, toolCalls: Int)] = [:]
        
        for record in records {
            let existing = grouped[record.model] ?? (0, 0, 0, 0)
            grouped[record.model] = (
                existing.prompt + record.promptTokens,
                existing.completion + record.completionTokens,
                existing.requests + 1,
                existing.toolCalls + record.toolCallCount
            )
        }
        
        return grouped.map { model, data in
            AggregatedUsage(
                date: Date(),
                model: model,
                promptTokens: data.prompt,
                completionTokens: data.completion,
                requestCount: data.requests,
                toolCallCount: data.toolCalls
            )
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
    
    // MARK: - Persistence
    
    private func usageDirectory() throws -> URL {
        let appSupport = try PersistenceService.appSupportDirectory()
        let usageDir = appSupport.appendingPathComponent("usage", isDirectory: true)
        if !FileManager.default.fileExists(atPath: usageDir.path) {
            try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        }
        return usageDir
    }
    
    private func dateKeyForDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func dateFromKey(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
    
    private func loadDailyData(for dateKey: String) -> DailyUsageData? {
        // Check cache first - avoids disk I/O if we have it
        if let cached = cache[dateKey] {
            return cached
        }
        
        // Synchronous load from disk - required for data integrity
        // The cache check above handles the common case (O(1)), so disk I/O only
        // happens on cache misses. Loading a small daily JSON file is fast, and
        // correctness is more important than avoiding brief main thread blocks.
        do {
            let dir = try usageDirectory()
            let fileURL = dir.appendingPathComponent("usage_\(dateKey).json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: fileURL)
            let dailyData = try JSONDecoder().decode(DailyUsageData.self, from: data)
            cache[dateKey] = dailyData
            return dailyData
        } catch {
            print("[TokenUsageTracker] Failed to load data for \(dateKey): \(error)")
            return nil
        }
    }
    
    /// Save to disk on background thread (fire-and-forget after cache update)
    private func saveDailyData(_ data: DailyUsageData, for dateKey: String) {
        // Update cache first for immediate availability
        cache[dateKey] = data
        
        // Write to disk on background thread
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let dir = try usageDirectory()
                let fileURL = dir.appendingPathComponent("usage_\(dateKey).json")
                let jsonData = try JSONEncoder().encode(data)
                try jsonData.write(to: fileURL, options: .atomic)
            } catch {
                print("[TokenUsageTracker] Failed to save data for \(dateKey): \(error)")
            }
        }
    }
    
    // MARK: - Cleanup
    
    /// Remove data older than retention period
    private func cleanupOldData() async {
        let cutoffKey = dateKeyForDate(Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date())
        
        // Run file operations on background thread
        let keysToRemove: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                var removedKeys: [String] = []
                do {
                    let dir = try usageDirectory()
                    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    for file in files {
                        let filename = file.deletingPathExtension().lastPathComponent
                        if filename.hasPrefix("usage_") {
                            let dateKey = String(filename.dropFirst(6)) // Remove "usage_" prefix
                            if dateKey < cutoffKey {
                                try FileManager.default.removeItem(at: file)
                                removedKeys.append(dateKey)
                            }
                        }
                    }
                } catch {
                    print("[TokenUsageTracker] Cleanup failed: \(error)")
                }
                continuation.resume(returning: removedKeys)
            }
        }
        
        // Update cache on main actor
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
    }
    
    /// Clear all usage data
    func clearAllData() {
        // Clear cache immediately for UI responsiveness
        cache.removeAll()
        lastUpdated = Date()
        
        // Delete files on background thread
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let dir = try usageDirectory()
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for file in files {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                print("[TokenUsageTracker] Failed to clear data: \(error)")
            }
        }
    }
}

