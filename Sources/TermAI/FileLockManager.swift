import Foundation

// MARK: - File Operation Types

/// Represents a file operation that can be coordinated
enum FileOperation: Sendable {
    case write(path: String, content: String, mode: WriteMode)
    case edit(path: String, oldText: String, newText: String, replaceAll: Bool)
    case insertLines(path: String, lineNumber: Int, content: String)
    case deleteLines(path: String, startLine: Int, endLine: Int)
    
    enum WriteMode: String, Sendable {
        case overwrite
        case append
    }
    
    var path: String {
        switch self {
        case .write(let path, _, _),
             .edit(let path, _, _, _),
             .insertLines(let path, _, _),
             .deleteLines(let path, _, _):
            return path
        }
    }
    
    /// Whether this operation requires exclusive access (cannot be merged)
    var requiresExclusiveLock: Bool {
        switch self {
        case .write(_, _, .overwrite):
            return true
        default:
            return false
        }
    }
    
    var operationName: String {
        switch self {
        case .write: return "write_file"
        case .edit: return "edit_file"
        case .insertLines: return "insert_lines"
        case .deleteLines: return "delete_lines"
        }
    }
}

// MARK: - Lock Result Types

enum LockAcquisitionResult {
    case acquired
    case merged(result: FileOperationResult)
    case queued(position: Int)
    case timeout
}

enum FileOperationResult: Sendable {
    case success(output: String)
    case failure(error: String)
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    
    var output: String {
        switch self {
        case .success(let output): return output
        case .failure(let error): return error
        }
    }
}

// MARK: - Merge Analysis

struct MergeAnalysis {
    let canMerge: Bool
    let reason: String
    let adjustedOperation: FileOperation?
}

struct EditRange: Equatable {
    let start: Int
    let end: Int
    
    func overlaps(with other: EditRange) -> Bool {
        return !(end < other.start || start > other.end)
    }
}

// MARK: - Pending Edit

struct PendingEdit: Sendable {
    let id: UUID
    let sessionId: UUID
    let operation: FileOperation
    let queuedAt: Date
}

// MARK: - File Lock

struct FileLock {
    let sessionId: UUID
    let path: String
    let acquiredAt: Date
    let operation: FileOperation
    var pendingEdits: [PendingEdit]
    
    /// Time the lock has been held
    var lockDuration: TimeInterval {
        Date().timeIntervalSince(acquiredAt)
    }
}

// MARK: - File Lock Manager

/// Coordinates file access across multiple agent sessions to prevent conflicts
@MainActor
final class FileLockManager: ObservableObject {
    static let shared = FileLockManager()
    
    // MARK: - Published State
    
    /// Currently active locks by normalized file path
    @Published private(set) var activeLocks: [String: FileLock] = [:]
    
    /// Sessions currently waiting for file access
    @Published private(set) var waitingSessions: [UUID: String] = [:] // sessionId -> file path
    
    // MARK: - Private State
    
    private var lockQueue = DispatchQueue(label: "com.termai.filelock", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - Lock Acquisition
    
    /// Acquire a lock for a file operation, potentially merging or queuing
    /// Returns the result of the operation if it was merged, or nil if the caller should proceed
    func acquireLock(
        for operation: FileOperation,
        sessionId: UUID,
        timeout: TimeInterval = AgentSettings.shared.fileLockTimeout
    ) async -> LockAcquisitionResult {
        let normalizedPath = normalizePath(operation.path)
        
        // Check if there's an existing lock
        if let existingLock = activeLocks[normalizedPath] {
            // Same session already has the lock - allow through
            if existingLock.sessionId == sessionId {
                return .acquired
            }
            
            // Different session - try to merge or queue
            let mergeAnalysis = analyzeMerge(existing: existingLock.operation, incoming: operation, filePath: normalizedPath)
            
            if mergeAnalysis.canMerge, let adjustedOp = mergeAnalysis.adjustedOperation {
                // Can merge - execute the adjusted operation immediately
                let result = await executeOperation(adjustedOp)
                return .merged(result: result)
            }
            
            // Cannot merge - queue and wait
            return await queueAndWait(
                operation: operation,
                sessionId: sessionId,
                path: normalizedPath,
                timeout: timeout
            )
        }
        
        // No existing lock - acquire it
        activeLocks[normalizedPath] = FileLock(
            sessionId: sessionId,
            path: normalizedPath,
            acquiredAt: Date(),
            operation: operation,
            pendingEdits: []
        )
        
        return .acquired
    }
    
    /// Release a lock and process any pending edits
    func releaseLock(for path: String, sessionId: UUID) {
        let normalizedPath = normalizePath(path)
        
        guard let lock = activeLocks[normalizedPath], lock.sessionId == sessionId else {
            return
        }
        
        // Process pending edits - transfer lock to next waiting session
        if !lock.pendingEdits.isEmpty {
            let nextEdit = lock.pendingEdits[0]
            let remainingEdits = Array(lock.pendingEdits.dropFirst())
            
            // Transfer lock to next session (they will detect this in their polling loop)
            activeLocks[normalizedPath] = FileLock(
                sessionId: nextEdit.sessionId,
                path: normalizedPath,
                acquiredAt: Date(),
                operation: nextEdit.operation,
                pendingEdits: remainingEdits
            )
            
            // Note: waitingSessions will be cleaned up by the polling loop when it detects acquisition
        } else {
            // No pending edits - remove lock
            activeLocks.removeValue(forKey: normalizedPath)
        }
    }
    
    /// Force release all locks held by a session (e.g., when session is cancelled)
    func releaseAllLocks(for sessionId: UUID) {
        let pathsToRelease = activeLocks.filter { $0.value.sessionId == sessionId }.map { $0.key }
        for path in pathsToRelease {
            releaseLock(for: path, sessionId: sessionId)
        }
        
        // Also remove from waiting sessions
        waitingSessions.removeValue(forKey: sessionId)
    }
    
    // MARK: - Queue Management
    
    private func queueAndWait(
        operation: FileOperation,
        sessionId: UUID,
        path: String,
        timeout: TimeInterval
    ) async -> LockAcquisitionResult {
        // Add to waiting sessions for UI feedback
        waitingSessions[sessionId] = path
        
        // Create pending edit
        let pendingEdit = PendingEdit(
            id: UUID(),
            sessionId: sessionId,
            operation: operation,
            queuedAt: Date()
        )
        
        // Add to queue
        if var lock = activeLocks[path] {
            lock.pendingEdits.append(pendingEdit)
            activeLocks[path] = lock
        } else {
            // Lock was released between check and queue - acquire directly
            waitingSessions.removeValue(forKey: sessionId)
            activeLocks[path] = FileLock(
                sessionId: sessionId,
                path: path,
                acquiredAt: Date(),
                operation: operation,
                pendingEdits: []
            )
            return .acquired
        }
        
        // Poll for our turn with timeout
        let startTime = Date()
        let pollInterval: UInt64 = 100_000_000 // 100ms
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if we now hold the lock
            if let lock = activeLocks[path], lock.sessionId == sessionId {
                waitingSessions.removeValue(forKey: sessionId)
                return .acquired
            }
            
            // Check if the lock was released entirely
            if activeLocks[path] == nil {
                // Try to acquire it
                activeLocks[path] = FileLock(
                    sessionId: sessionId,
                    path: path,
                    acquiredAt: Date(),
                    operation: operation,
                    pendingEdits: []
                )
                waitingSessions.removeValue(forKey: sessionId)
                return .acquired
            }
            
            // Still waiting, sleep briefly
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        
        // Timeout - remove from queue
        if var lock = activeLocks[path] {
            lock.pendingEdits.removeAll { $0.id == pendingEdit.id }
            activeLocks[path] = lock
        }
        waitingSessions.removeValue(forKey: sessionId)
        
        return .timeout
    }
    
    // MARK: - Merge Analysis
    
    private func analyzeMerge(existing: FileOperation, incoming: FileOperation, filePath: String) -> MergeAnalysis {
        // Exclusive operations cannot be merged
        if existing.requiresExclusiveLock || incoming.requiresExclusiveLock {
            return MergeAnalysis(
                canMerge: false,
                reason: "Operation requires exclusive access",
                adjustedOperation: nil
            )
        }
        
        // Read current file state for analysis
        guard let currentContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return MergeAnalysis(
                canMerge: false,
                reason: "Cannot read file for merge analysis",
                adjustedOperation: nil
            )
        }
        
        switch (existing, incoming) {
        case (.edit(_, let existingOld, _, _), .edit(_, let incomingOld, _, _)):
            // Check if edit ranges overlap
            let existingRange = findTextRange(existingOld, in: currentContent)
            let incomingRange = findTextRange(incomingOld, in: currentContent)
            
            if let eRange = existingRange, let iRange = incomingRange {
                if !eRange.overlaps(with: iRange) {
                    // Non-overlapping edits - can merge
                    // The incoming edit can proceed as-is since it will find its old_text
                    return MergeAnalysis(
                        canMerge: true,
                        reason: "Non-overlapping text edits",
                        adjustedOperation: incoming
                    )
                }
            }
            
            return MergeAnalysis(
                canMerge: false,
                reason: "Overlapping edit ranges",
                adjustedOperation: nil
            )
            
        case (.insertLines(_, let existingLine, _), .insertLines(_, let incomingLine, let content)):
            // Check if insert positions conflict
            if abs(existingLine - incomingLine) > 1 {
                // Non-adjacent inserts - can merge with adjusted line number
                // If existing insert is before incoming, incoming needs to shift
                let adjustment = existingLine < incomingLine ? 1 : 0
                return MergeAnalysis(
                    canMerge: true,
                    reason: "Non-adjacent line insertions",
                    adjustedOperation: .insertLines(path: filePath, lineNumber: incomingLine + adjustment, content: content)
                )
            }
            
            return MergeAnalysis(
                canMerge: false,
                reason: "Adjacent or overlapping line insertions",
                adjustedOperation: nil
            )
            
        case (.deleteLines(_, let existingStart, let existingEnd), .deleteLines(_, let incomingStart, let incomingEnd)):
            let existingRange = EditRange(start: existingStart, end: existingEnd)
            let incomingRange = EditRange(start: incomingStart, end: incomingEnd)
            
            if !existingRange.overlaps(with: incomingRange) {
                // Non-overlapping deletes - adjust line numbers
                let shift = existingEnd - existingStart + 1
                let adjustedStart = incomingStart > existingEnd ? incomingStart - shift : incomingStart
                let adjustedEnd = incomingEnd > existingEnd ? incomingEnd - shift : incomingEnd
                
                return MergeAnalysis(
                    canMerge: true,
                    reason: "Non-overlapping line deletions",
                    adjustedOperation: .deleteLines(path: filePath, startLine: adjustedStart, endLine: adjustedEnd)
                )
            }
            
            return MergeAnalysis(
                canMerge: false,
                reason: "Overlapping delete ranges",
                adjustedOperation: nil
            )
            
        case (.edit, .insertLines), (.insertLines, .edit),
             (.edit, .deleteLines), (.deleteLines, .edit),
             (.insertLines, .deleteLines), (.deleteLines, .insertLines):
            // Mixed operation types - be conservative, don't merge
            return MergeAnalysis(
                canMerge: false,
                reason: "Mixed operation types require sequential execution",
                adjustedOperation: nil
            )
            
        default:
            return MergeAnalysis(
                canMerge: false,
                reason: "Unsupported operation combination",
                adjustedOperation: nil
            )
        }
    }
    
    private func findTextRange(_ text: String, in content: String) -> EditRange? {
        guard let range = content.range(of: text) else {
            return nil
        }
        let start = content.distance(from: content.startIndex, to: range.lowerBound)
        let end = content.distance(from: content.startIndex, to: range.upperBound)
        return EditRange(start: start, end: end)
    }
    
    // MARK: - Operation Execution
    
    private func executeOperation(_ operation: FileOperation) async -> FileOperationResult {
        let path = operation.path
        
        switch operation {
        case .write(_, let content, let mode):
            return await executeWrite(path: path, content: content, mode: mode)
            
        case .edit(_, let oldText, let newText, let replaceAll):
            return await executeEdit(path: path, oldText: oldText, newText: newText, replaceAll: replaceAll)
            
        case .insertLines(_, let lineNumber, let content):
            return await executeInsertLines(path: path, lineNumber: lineNumber, content: content)
            
        case .deleteLines(_, let startLine, let endLine):
            return await executeDeleteLines(path: path, startLine: startLine, endLine: endLine)
        }
    }
    
    private func executeWrite(path: String, content: String, mode: FileOperation.WriteMode) async -> FileOperationResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            if mode == .append && FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                try handle.close()
                notifyFileModified(path: path)
                return .success(output: "Appended \(content.count) chars to \(path)")
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
                notifyFileModified(path: path)
                return .success(output: "Wrote \(content.count) chars to \(path)")
            }
        } catch {
            return .failure(error: "Error writing file: \(error.localizedDescription)")
        }
    }
    
    private func executeEdit(path: String, oldText: String, newText: String, replaceAll: Bool) async -> FileOperationResult {
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(error: "File not found: \(path)")
        }
        
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            
            guard content.contains(oldText) else {
                let lines = content.components(separatedBy: .newlines)
                let preview = lines.prefix(10).joined(separator: "\n")
                return .failure(error: "Text not found in file. The old_text must match exactly.\n\nFile has \(lines.count) lines. First 10 lines:\n\(preview)")
            }
            
            let occurrences = content.components(separatedBy: oldText).count - 1
            
            if replaceAll {
                content = content.replacingOccurrences(of: oldText, with: newText)
            } else {
                if let range = content.range(of: oldText) {
                    content = content.replacingCharacters(in: range, with: newText)
                }
            }
            
            try content.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let resultLines = content.components(separatedBy: "\n")
            let previewLines = resultLines.prefix(20).enumerated().map { "\($0.offset + 1)| \($0.element)" }.joined(separator: "\n")
            let suffix = resultLines.count > 20 ? "\n... (\(resultLines.count - 20) more lines)" : ""
            
            if replaceAll {
                return .success(output: "Replaced \(occurrences) occurrence(s) in \(path).\n\nFile preview:\n\(previewLines)\(suffix)")
            } else {
                return .success(output: "Replaced 1 occurrence in \(path).\n\nFile preview:\n\(previewLines)\(suffix)")
            }
        } catch {
            return .failure(error: "Error editing file: \(error.localizedDescription)")
        }
    }
    
    private func executeInsertLines(path: String, lineNumber: Int, content: String) async -> FileOperationResult {
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(error: "File not found: \(path)")
        }
        
        do {
            let fileContent = try String(contentsOf: url, encoding: .utf8)
            
            let normalizedInsert = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if fileContent.contains(normalizedInsert) {
                return .success(output: "ALREADY EXISTS: The content you're trying to insert already exists in the file. No changes made.")
            }
            
            var lines = fileContent.components(separatedBy: "\n")
            let insertIndex = min(lineNumber - 1, lines.count)
            let newLines = content.components(separatedBy: "\n")
            lines.insert(contentsOf: newLines, at: insertIndex)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let previewStart = max(0, insertIndex - 2)
            let previewEnd = min(lines.count, insertIndex + newLines.count + 2)
            let preview = lines[previewStart..<previewEnd].enumerated().map {
                "\(previewStart + $0.offset + 1)| \($0.element)"
            }.joined(separator: "\n")
            
            return .success(output: "Inserted \(newLines.count) line(s) at line \(lineNumber).\n\nPreview around insertion:\n\(preview)")
        } catch {
            return .failure(error: "Error inserting lines: \(error.localizedDescription)")
        }
    }
    
    private func executeDeleteLines(path: String, startLine: Int, endLine: Int) async -> FileOperationResult {
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(error: "File not found: \(path)")
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            
            let start = max(0, startLine - 1)
            let end = min(lines.count, endLine)
            
            if start >= lines.count {
                return .failure(error: "start_line \(startLine) exceeds file length (\(lines.count) lines)")
            }
            
            let deletedCount = end - start
            lines.removeSubrange(start..<end)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            return .success(output: "Deleted \(deletedCount) line(s) from \(path)")
        } catch {
            return .failure(error: "Error deleting lines: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func normalizePath(_ path: String) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }
    
    /// Notify observers that a file was modified on disk
    private func notifyFileModified(path: String) {
        NotificationCenter.default.post(
            name: .TermAIFileModifiedOnDisk,
            object: nil,
            userInfo: ["path": path]
        )
    }
    
    // MARK: - Status Queries
    
    /// Check if a session is waiting for any file
    func isSessionWaiting(_ sessionId: UUID) -> Bool {
        return waitingSessions[sessionId] != nil
    }
    
    /// Get the file a session is waiting for
    func waitingFile(for sessionId: UUID) -> String? {
        return waitingSessions[sessionId]
    }
    
    /// Get the session that holds a lock on a file
    func lockHolder(for path: String) -> UUID? {
        let normalizedPath = normalizePath(path)
        return activeLocks[normalizedPath]?.sessionId
    }
    
    /// Get queue position for a session waiting on a file
    func queuePosition(for sessionId: UUID, path: String) -> Int? {
        let normalizedPath = normalizePath(path)
        guard let lock = activeLocks[normalizedPath] else { return nil }
        guard let index = lock.pendingEdits.firstIndex(where: { $0.sessionId == sessionId }) else { return nil }
        return index + 1
    }
    
    /// Get active lock info for UI display
    func lockInfo(for path: String) -> (holder: UUID, duration: TimeInterval, queueLength: Int)? {
        let normalizedPath = normalizePath(path)
        guard let lock = activeLocks[normalizedPath] else { return nil }
        return (lock.sessionId, lock.lockDuration, lock.pendingEdits.count)
    }
}


