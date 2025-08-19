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
}

struct AppSettings: Codable, Equatable {
    var apiBaseURLString: String
    var apiKey: String?
    var model: String
    var providerName: String?
    var systemPrompt: String?
}


