import Foundation

enum PersistenceService {
    static func appSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let url = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TermAI", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: - Synchronous Methods (for backwards compatibility)
    
    static func saveJSON<T: Encodable>(_ value: T, to filename: String) throws {
        let dir = try appSupportDirectory()
        let fileURL = dir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func loadJSON<T: Decodable>(_ type: T.Type, from filename: String) throws -> T {
        let dir = try appSupportDirectory()
        let fileURL = dir.appendingPathComponent(filename)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Async Methods (run file I/O on background thread)
    
    /// Save JSON to file asynchronously - runs file I/O on background thread
    static func saveJSONAsync<T: Encodable>(_ value: T, to filename: String) async throws {
        // Encode on calling thread (usually fast), then write on background
        let data = try JSONEncoder().encode(value)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let dir = try appSupportDirectory()
                    let fileURL = dir.appendingPathComponent(filename)
                    try data.write(to: fileURL, options: [.atomic])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Load JSON from file asynchronously - runs file I/O on background thread
    static func loadJSONAsync<T: Decodable>(_ type: T.Type, from filename: String) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let dir = try appSupportDirectory()
                    let fileURL = dir.appendingPathComponent(filename)
                    let data = try Data(contentsOf: fileURL)
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Fire-and-forget save - updates happen in background, errors are logged
    static func saveJSONInBackground<T: Encodable>(_ value: T, to filename: String) {
        // Encode on calling thread to capture the value
        guard let data = try? JSONEncoder().encode(value) else {
            print("[PersistenceService] Failed to encode data for \(filename)")
            return
        }
        
        DispatchQueue.global(qos: .utility).async {
            do {
                let dir = try appSupportDirectory()
                let fileURL = dir.appendingPathComponent(filename)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                print("[PersistenceService] Background save failed for \(filename): \(error)")
            }
        }
    }
    
    /// Delete all TermAI data by removing the entire app support directory
    /// and clearing UserDefaults entries
    /// This is a destructive operation - the app should quit after calling this
    static func clearAllData() throws {
        let fm = FileManager.default
        let url = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("TermAI", isDirectory: true)
        
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        
        // Also clear UserDefaults entries (model cache, etc.)
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            // Clear model cache entries
            if key.hasPrefix("modelCache_") {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.synchronize()
    }
}

struct AppSettings: Codable, Equatable {
    var apiBaseURLString: String
    var apiKey: String?
    var model: String
    var providerName: String?
    var systemPrompt: String?
}


