import Foundation

struct TerminalContextMeta: Codable, Equatable {
    let startRow: Int
    let endRow: Int
    var cwd: String? = nil
}


