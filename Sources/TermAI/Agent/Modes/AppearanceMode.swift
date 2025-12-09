import Foundation
import SwiftUI

/// App appearance mode for light/dark theme control
enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    /// Convert to SwiftUI ColorScheme for preferredColorScheme modifier
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    /// Icon for the mode
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    /// Description for the mode
    var description: String {
        switch self {
        case .system: return "Follow system appearance"
        case .light: return "Always use light mode"
        case .dark: return "Always use dark mode"
        }
    }
}
