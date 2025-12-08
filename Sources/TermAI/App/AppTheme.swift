import SwiftUI

// MARK: - App Theme (Atom One Pro)

/// Centralized theme providing Atom One Pro colors across the entire app.
/// Automatically switches between Dark and Light variants based on system appearance.
struct AppTheme {
    let colorScheme: ColorScheme
    
    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }
    
    // MARK: - Core Colors
    
    /// Main background color
    var background: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)  // #282c34
            : Color(red: 0.98, green: 0.98, blue: 0.98)  // #fafafa
    }
    
    /// Secondary/sidebar background
    var secondaryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.15, blue: 0.17)  // #21252b
            : Color(red: 0.94, green: 0.94, blue: 0.94)  // #f0f0f0
    }
    
    /// Elevated surface (panels, cards, popovers)
    var elevatedBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.19, blue: 0.23)  // #2c313a
            : Color(red: 0.96, green: 0.96, blue: 0.96)  // #f5f5f5
    }
    
    /// Input field background
    var inputBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451
            : Color(red: 0.90, green: 0.90, blue: 0.90)  // #e5e5e6
    }
    
    // MARK: - Text Colors
    
    /// Primary text color (foreground)
    var primaryText: Color {
        colorScheme == .dark
            ? Color(red: 0.67, green: 0.70, blue: 0.75)  // #abb2bf
            : Color(red: 0.22, green: 0.23, blue: 0.26)  // #383a42
    }
    
    /// Secondary/muted text color
    var secondaryText: Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.39, blue: 0.44)  // #5c6370
            : Color(red: 0.63, green: 0.63, blue: 0.65)  // #a0a1a7
    }
    
    // MARK: - Accent Colors
    
    /// Primary accent color (blue)
    var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.69, blue: 0.94)  // #61afef
            : Color(red: 0.25, green: 0.47, blue: 0.95)  // #4078f2
    }
    
    /// Success/positive color (green)
    var success: Color {
        colorScheme == .dark
            ? Color(red: 0.60, green: 0.76, blue: 0.47)  // #98c379
            : Color(red: 0.31, green: 0.63, blue: 0.31)  // #50a14f
    }
    
    /// Warning color (yellow/orange)
    var warning: Color {
        colorScheme == .dark
            ? Color(red: 0.90, green: 0.75, blue: 0.48)  // #e5c07b
            : Color(red: 0.76, green: 0.52, blue: 0.00)  // #c18401
    }
    
    /// Error/destructive color (red)
    var error: Color {
        colorScheme == .dark
            ? Color(red: 0.88, green: 0.42, blue: 0.46)  // #e06c75
            : Color(red: 0.89, green: 0.34, blue: 0.29)  // #e45649
    }
    
    /// Magenta/purple accent
    var purple: Color {
        colorScheme == .dark
            ? Color(red: 0.78, green: 0.47, blue: 0.87)  // #c678dd
            : Color(red: 0.65, green: 0.15, blue: 0.64)  // #a626a4
    }
    
    /// Cyan accent
    var cyan: Color {
        colorScheme == .dark
            ? Color(red: 0.34, green: 0.71, blue: 0.76)  // #56b6c2
            : Color(red: 0.00, green: 0.52, blue: 0.74)  // #0184bc
    }
    
    // MARK: - UI Element Colors
    
    /// Divider/border color
    var divider: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451
            : Color(red: 0.82, green: 0.82, blue: 0.82)  // #d0d0d0
    }
    
    /// Selection background
    var selection: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451
            : Color(red: 0.90, green: 0.90, blue: 0.90)  // #e5e5e6
    }
    
    /// Hover state background
    var hover: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }
    
    /// Active/pressed state background
    var active: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.06)
    }
    
    /// Border/stroke for cards and inputs
    var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }
    
    // MARK: - Gutter/Line Numbers
    
    /// Line number color
    var lineNumber: Color {
        colorScheme == .dark
            ? Color(red: 0.39, green: 0.43, blue: 0.51)  // #636d83
            : Color(red: 0.62, green: 0.62, blue: 0.62)  // #9d9d9f
    }
    
    /// Gutter background
    var gutterBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.15, blue: 0.17)  // #21252b
            : Color(red: 0.94, green: 0.94, blue: 0.94)  // #f0f0f0
    }
}

// MARK: - Environment Key

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(colorScheme: .dark)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// Applies the AppTheme based on current color scheme
    func withAppTheme() -> some View {
        modifier(AppThemeModifier())
    }
}

private struct AppThemeModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .environment(\.appTheme, AppTheme(colorScheme: colorScheme))
    }
}
