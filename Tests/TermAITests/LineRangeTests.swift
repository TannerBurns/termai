import XCTest
@testable import TermAIModels

final class LineRangeTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testInit_NormalRange() {
        let range = LineRange(start: 10, end: 50)
        XCTAssertEqual(range.start, 10)
        XCTAssertEqual(range.end, 50)
    }
    
    func testInit_ReversedRange_Normalizes() {
        // When start > end, should swap them
        let range = LineRange(start: 50, end: 10)
        XCTAssertEqual(range.start, 10)
        XCTAssertEqual(range.end, 50)
    }
    
    func testInit_SingleLine() {
        let range = LineRange(line: 42)
        XCTAssertEqual(range.start, 42)
        XCTAssertEqual(range.end, 42)
    }
    
    func testInit_SameStartEnd() {
        let range = LineRange(start: 100, end: 100)
        XCTAssertEqual(range.start, 100)
        XCTAssertEqual(range.end, 100)
    }
    
    // MARK: - parse Tests
    
    func testParse_RangeFormat() {
        let range = LineRange.parse("10-50")
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, 10)
        XCTAssertEqual(range?.end, 50)
    }
    
    func testParse_RangeWithSpaces() {
        let range = LineRange.parse("  10-50  ")
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, 10)
        XCTAssertEqual(range?.end, 50)
    }
    
    func testParse_SingleNumber() {
        let range = LineRange.parse("100")
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, 100)
        XCTAssertEqual(range?.end, 100)
    }
    
    func testParse_Invalid_TooManyParts() {
        let range = LineRange.parse("10-20-30")
        XCTAssertNil(range)
    }
    
    func testParse_Invalid_NotNumbers() {
        XCTAssertNil(LineRange.parse("abc-def"))
        XCTAssertNil(LineRange.parse("abc"))
    }
    
    func testParse_Invalid_Empty() {
        XCTAssertNil(LineRange.parse(""))
    }
    
    func testParse_Invalid_OnlyDash() {
        XCTAssertNil(LineRange.parse("-"))
    }
    
    // MARK: - parseMultiple Tests
    
    func testParseMultiple_SingleRange() {
        let ranges = LineRange.parseMultiple("10-50")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 10)
        XCTAssertEqual(ranges[0].end, 50)
    }
    
    func testParseMultiple_MultipleRanges() {
        let ranges = LineRange.parseMultiple("10-50,80-100,200")
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], LineRange(start: 10, end: 50))
        XCTAssertEqual(ranges[1], LineRange(start: 80, end: 100))
        XCTAssertEqual(ranges[2], LineRange(line: 200))
    }
    
    func testParseMultiple_WithInvalidParts() {
        // Invalid parts should be skipped
        let ranges = LineRange.parseMultiple("10-50,invalid,100")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], LineRange(start: 10, end: 50))
        XCTAssertEqual(ranges[1], LineRange(line: 100))
    }
    
    func testParseMultiple_Empty() {
        let ranges = LineRange.parseMultiple("")
        XCTAssertEqual(ranges.count, 0)
    }
    
    // MARK: - description Tests
    
    func testDescription_Range() {
        let range = LineRange(start: 10, end: 50)
        XCTAssertEqual(range.description, "L10-50")
    }
    
    func testDescription_SingleLine() {
        let range = LineRange(line: 42)
        XCTAssertEqual(range.description, "L42")
    }
    
    // MARK: - contains Tests
    
    func testContains_InRange() {
        let range = LineRange(start: 10, end: 50)
        XCTAssertTrue(range.contains(10))  // Start
        XCTAssertTrue(range.contains(30))  // Middle
        XCTAssertTrue(range.contains(50))  // End
    }
    
    func testContains_OutOfRange() {
        let range = LineRange(start: 10, end: 50)
        XCTAssertFalse(range.contains(9))   // Just before
        XCTAssertFalse(range.contains(51))  // Just after
        XCTAssertFalse(range.contains(0))   // Way before
        XCTAssertFalse(range.contains(100)) // Way after
    }
    
    func testContains_SingleLine() {
        let range = LineRange(line: 42)
        XCTAssertTrue(range.contains(42))
        XCTAssertFalse(range.contains(41))
        XCTAssertFalse(range.contains(43))
    }
    
    // MARK: - Codable Tests
    
    func testCodable_RoundTrip() throws {
        let original = LineRange(start: 10, end: 50)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LineRange.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }
    
    func testCodable_SingleLine_RoundTrip() throws {
        let original = LineRange(line: 100)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LineRange.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }
    
    // MARK: - Hashable Tests
    
    func testHashable_SameRangesHaveSameHash() {
        let range1 = LineRange(start: 10, end: 50)
        let range2 = LineRange(start: 10, end: 50)
        XCTAssertEqual(range1.hashValue, range2.hashValue)
    }
    
    func testHashable_CanBeUsedInSet() {
        var set = Set<LineRange>()
        set.insert(LineRange(start: 10, end: 50))
        set.insert(LineRange(start: 10, end: 50))  // Duplicate
        set.insert(LineRange(start: 80, end: 100))
        XCTAssertEqual(set.count, 2)
    }
}
