import XCTest
@testable import TermAIModels

final class TokenEstimatorTests: XCTestCase {
    
    // MARK: - charsPerToken Tests
    
    func testCharsPerToken_Claude() {
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "claude-3-opus"), 3.5)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "claude-sonnet-4"), 3.5)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "CLAUDE-3-5-SONNET"), 3.5)
    }
    
    func testCharsPerToken_GPT() {
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "gpt-4o"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "gpt-4-turbo"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "gpt-5"), 4.0)
    }
    
    func testCharsPerToken_OSeries() {
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "o1-preview"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "o3-mini"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "o4"), 4.0)
    }
    
    func testCharsPerToken_LocalModels() {
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "llama-3.2"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "mistral-7b"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "qwen2.5"), 4.0)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "gemma-2"), 4.0)
    }
    
    func testCharsPerToken_Default() {
        XCTAssertEqual(TokenEstimator.charsPerToken(for: "unknown-model"), 3.8)
        XCTAssertEqual(TokenEstimator.charsPerToken(for: ""), 3.8)
    }
    
    // MARK: - estimateTokens Tests
    
    func testEstimateTokens_EmptyString() {
        XCTAssertEqual(TokenEstimator.estimateTokens(""), 0)
    }
    
    func testEstimateTokens_ShortString() {
        // "Hello" = 5 chars, default ratio 3.8 -> ceil(5/3.8) = ceil(1.316) = 2
        XCTAssertEqual(TokenEstimator.estimateTokens("Hello"), 2)
    }
    
    func testEstimateTokens_WithModel() {
        // "Hello World" = 11 chars, Claude ratio 3.5 -> ceil(11/3.5) = ceil(3.14) = 4
        XCTAssertEqual(TokenEstimator.estimateTokens("Hello World", model: "claude-3"), 4)
        
        // Same string, GPT ratio 4.0 -> ceil(11/4.0) = ceil(2.75) = 3
        XCTAssertEqual(TokenEstimator.estimateTokens("Hello World", model: "gpt-4"), 3)
    }
    
    func testEstimateTokens_Array() {
        let texts = ["Hello", "World"]
        // "Hello" = 2 tokens, "World" = 2 tokens with default ratio
        XCTAssertEqual(TokenEstimator.estimateTokens(texts), 4)
    }
    
    func testEstimateTokens_EmptyArray() {
        XCTAssertEqual(TokenEstimator.estimateTokens([String]()), 0)
    }
    
    // MARK: - contextLimit Tests
    
    func testContextLimit_GPT5() {
        XCTAssertEqual(TokenEstimator.contextLimit(for: "gpt-5-turbo"), 128_000)
    }
    
    func testContextLimit_GPT4o() {
        XCTAssertEqual(TokenEstimator.contextLimit(for: "gpt-4o"), 128_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "gpt-4.1"), 128_000)
    }
    
    func testContextLimit_OSeries() {
        XCTAssertEqual(TokenEstimator.contextLimit(for: "o1-preview"), 200_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "o3-mini"), 200_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "o4"), 200_000)
    }
    
    func testContextLimit_Claude() {
        XCTAssertEqual(TokenEstimator.contextLimit(for: "claude-opus-4"), 200_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "claude-sonnet-4"), 200_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "claude-3-5-sonnet"), 200_000)
        XCTAssertEqual(TokenEstimator.contextLimit(for: "claude-3-7-opus"), 200_000)
    }
    
    func testContextLimit_Default() {
        XCTAssertEqual(TokenEstimator.contextLimit(for: "unknown-model"), 32_000)
    }
    
    // MARK: - maxContextUsage Tests
    
    func testMaxContextUsage_ReservesQuarter() {
        // GPT-4o has 128K limit, should reserve 25% for response
        XCTAssertEqual(TokenEstimator.maxContextUsage(for: "gpt-4o"), 96_000)
        
        // Claude 4 has 200K limit
        XCTAssertEqual(TokenEstimator.maxContextUsage(for: "claude-opus-4"), 150_000)
        
        // Default 32K
        XCTAssertEqual(TokenEstimator.maxContextUsage(for: "unknown"), 24_000)
    }
}
