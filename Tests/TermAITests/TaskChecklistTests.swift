import XCTest
@testable import TermAIModels

final class TaskStatusTests: XCTestCase {
    
    func testRawValues() {
        XCTAssertEqual(TaskStatus.pending.rawValue, "pending")
        XCTAssertEqual(TaskStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TaskStatus.completed.rawValue, "completed")
        XCTAssertEqual(TaskStatus.failed.rawValue, "failed")
        XCTAssertEqual(TaskStatus.skipped.rawValue, "skipped")
    }
    
    func testEmojis() {
        XCTAssertEqual(TaskStatus.pending.emoji, "○")
        XCTAssertEqual(TaskStatus.inProgress.emoji, "→")
        XCTAssertEqual(TaskStatus.completed.emoji, "✓")
        XCTAssertEqual(TaskStatus.failed.emoji, "✗")
        XCTAssertEqual(TaskStatus.skipped.emoji, "⊘")
    }
    
    func testCodable_RoundTrip() throws {
        let statuses: [TaskStatus] = [.pending, .inProgress, .completed, .failed, .skipped]
        for status in statuses {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(TaskStatus.self, from: encoded)
            XCTAssertEqual(status, decoded)
        }
    }
}

final class TaskChecklistItemTests: XCTestCase {
    
    func testDisplayString_WithoutNote() {
        let item = TaskChecklistItem(id: 1, description: "Setup project", status: .pending, verificationNote: nil)
        XCTAssertEqual(item.displayString, "○ 1. Setup project")
    }
    
    func testDisplayString_WithNote() {
        let item = TaskChecklistItem(id: 2, description: "Build feature", status: .completed, verificationNote: "Tests passing")
        XCTAssertEqual(item.displayString, "✓ 2. Build feature [Tests passing]")
    }
    
    func testDisplayString_InProgress() {
        let item = TaskChecklistItem(id: 3, description: "Running tests", status: .inProgress, verificationNote: nil)
        XCTAssertEqual(item.displayString, "→ 3. Running tests")
    }
    
    func testCodable_RoundTrip() throws {
        let item = TaskChecklistItem(id: 5, description: "Test task", status: .inProgress, verificationNote: "In progress...")
        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TaskChecklistItem.self, from: encoded)
        XCTAssertEqual(item, decoded)
    }
}

final class TaskChecklistTests: XCTestCase {
    
    // MARK: - Initialization
    
    func testInit_CreatesItemsFromPlan() {
        let plan = ["Step 1", "Step 2", "Step 3"]
        let checklist = TaskChecklist(from: plan, goal: "Complete the task")
        
        XCTAssertEqual(checklist.goalDescription, "Complete the task")
        XCTAssertEqual(checklist.items.count, 3)
        
        XCTAssertEqual(checklist.items[0].id, 1)
        XCTAssertEqual(checklist.items[0].description, "Step 1")
        XCTAssertEqual(checklist.items[0].status, .pending)
        
        XCTAssertEqual(checklist.items[1].id, 2)
        XCTAssertEqual(checklist.items[2].id, 3)
    }
    
    func testInit_EmptyPlan() {
        let checklist = TaskChecklist(from: [], goal: "Empty goal")
        XCTAssertEqual(checklist.items.count, 0)
        XCTAssertEqual(checklist.goalDescription, "Empty goal")
    }
    
    // MARK: - Status Updates
    
    func testMarkInProgress() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.markInProgress(1)
        
        XCTAssertEqual(checklist.items[0].status, .inProgress)
        XCTAssertEqual(checklist.items[1].status, .pending)
    }
    
    func testMarkCompleted() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.markCompleted(1, note: "Done!")
        
        XCTAssertEqual(checklist.items[0].status, .completed)
        XCTAssertEqual(checklist.items[0].verificationNote, "Done!")
    }
    
    func testMarkFailed() {
        var checklist = TaskChecklist(from: ["Task 1"], goal: "Goal")
        checklist.markFailed(1, note: "Error occurred")
        
        XCTAssertEqual(checklist.items[0].status, .failed)
        XCTAssertEqual(checklist.items[0].verificationNote, "Error occurred")
    }
    
    func testUpdateStatus_NonExistentId() {
        var checklist = TaskChecklist(from: ["Task 1"], goal: "Goal")
        checklist.updateStatus(for: 999, status: .completed)  // Non-existent ID
        
        // Should not crash, item should remain unchanged
        XCTAssertEqual(checklist.items[0].status, .pending)
    }
    
    // MARK: - Progress Tracking
    
    func testCompletedCount() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2", "Task 3"], goal: "Goal")
        XCTAssertEqual(checklist.completedCount, 0)
        
        checklist.markCompleted(1)
        XCTAssertEqual(checklist.completedCount, 1)
        
        checklist.markCompleted(2)
        XCTAssertEqual(checklist.completedCount, 2)
    }
    
    func testProgressPercent() {
        var checklist = TaskChecklist(from: ["T1", "T2", "T3", "T4"], goal: "Goal")
        XCTAssertEqual(checklist.progressPercent, 0)
        
        checklist.markCompleted(1)
        XCTAssertEqual(checklist.progressPercent, 25)
        
        checklist.markCompleted(2)
        XCTAssertEqual(checklist.progressPercent, 50)
        
        checklist.markCompleted(3)
        checklist.markCompleted(4)
        XCTAssertEqual(checklist.progressPercent, 100)
    }
    
    func testProgressPercent_EmptyChecklist() {
        let checklist = TaskChecklist(from: [], goal: "Goal")
        XCTAssertEqual(checklist.progressPercent, 0)
    }
    
    // MARK: - Current Item
    
    func testCurrentItem_ReturnsInProgress() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2", "Task 3"], goal: "Goal")
        checklist.markInProgress(2)
        
        XCTAssertEqual(checklist.currentItem?.id, 2)
    }
    
    func testCurrentItem_ReturnsFirstPendingIfNoInProgress() {
        let checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        XCTAssertEqual(checklist.currentItem?.id, 1)
    }
    
    func testCurrentItem_NilWhenAllDone() {
        var checklist = TaskChecklist(from: ["Task 1"], goal: "Goal")
        checklist.markCompleted(1)
        
        XCTAssertNil(checklist.currentItem)
    }
    
    // MARK: - Completion Status
    
    func testIsComplete_AllCompleted() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.markCompleted(1)
        checklist.markCompleted(2)
        
        XCTAssertTrue(checklist.isComplete)
    }
    
    func testIsComplete_AllSkipped() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.updateStatus(for: 1, status: .skipped)
        checklist.updateStatus(for: 2, status: .skipped)
        
        XCTAssertTrue(checklist.isComplete)
    }
    
    func testIsComplete_Mixed() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.markCompleted(1)
        checklist.updateStatus(for: 2, status: .skipped)
        
        XCTAssertTrue(checklist.isComplete)
    }
    
    func testIsComplete_NotComplete() {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Goal")
        checklist.markCompleted(1)
        
        XCTAssertFalse(checklist.isComplete)
    }
    
    func testIsComplete_EmptyChecklist() {
        let checklist = TaskChecklist(from: [], goal: "Goal")
        XCTAssertTrue(checklist.isComplete)
    }
    
    // MARK: - Remaining Items
    
    func testRemainingItems() {
        var checklist = TaskChecklist(from: ["T1", "T2", "T3", "T4"], goal: "Goal")
        checklist.markCompleted(1)
        checklist.markInProgress(2)
        checklist.markFailed(3)
        // T4 remains pending
        
        let remaining = checklist.remainingItems
        XCTAssertEqual(remaining.count, 3)
        XCTAssertTrue(remaining.contains { $0.id == 2 })  // in_progress
        XCTAssertTrue(remaining.contains { $0.id == 3 })  // failed
        XCTAssertTrue(remaining.contains { $0.id == 4 })  // pending
        XCTAssertFalse(remaining.contains { $0.id == 1 }) // completed - not remaining
    }
    
    // MARK: - Display String
    
    func testDisplayString() {
        var checklist = TaskChecklist(from: ["Setup", "Build", "Test"], goal: "Goal")
        checklist.markCompleted(1)
        checklist.markInProgress(2)
        
        let display = checklist.displayString
        XCTAssertTrue(display.contains("CHECKLIST (1/3 completed - 33%)"))
        XCTAssertTrue(display.contains("✓ 1. Setup"))
        XCTAssertTrue(display.contains("→ 2. Build"))
        XCTAssertTrue(display.contains("○ 3. Test"))
    }
    
    // MARK: - Codable
    
    func testCodable_RoundTrip() throws {
        var checklist = TaskChecklist(from: ["Task 1", "Task 2"], goal: "Test Goal")
        checklist.markCompleted(1, note: "Done")
        checklist.markInProgress(2)
        
        let encoded = try JSONEncoder().encode(checklist)
        let decoded = try JSONDecoder().decode(TaskChecklist.self, from: encoded)
        
        XCTAssertEqual(checklist, decoded)
    }
}
