import Foundation

/// Terminal bell behavior mode
enum TerminalBellMode: String, Codable, CaseIterable {
    case sound = "Sound"
    case visual = "Visual"
    case off = "Off"
    
    /// SF Symbol icon for the mode
    var icon: String {
        switch self {
        case .sound: return "bell.fill"
        case .visual: return "light.max"
        case .off: return "bell.slash"
        }
    }
    
    /// Description for the mode
    var description: String {
        switch self {
        case .sound: return "Play system alert sound"
        case .visual: return "Flash the terminal window"
        case .off: return "Disable terminal bell"
        }
    }
}
