import Foundation
import AppKit
#if canImport(SwiftTerm)
import SwiftTerm

// Helper to build SwiftTerm.Color from 8-bit RGB
private func color8(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
    let rr = UInt16(max(0, min(255, r))) * 257
    let gg = UInt16(max(0, min(255, g))) * 257
    let bb = UInt16(max(0, min(255, b))) * 257
    return SwiftTerm.Color(red: rr, green: gg, blue: bb)
}

struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String

    let foreground: NSColor
    let background: NSColor
    let caret: NSColor?
    let selectionBackground: NSColor
    let useBrightColors: Bool

    // Must be 16 colors if present
    let ansi16Palette: [SwiftTerm.Color]?

    static func system() -> TerminalTheme {
        TerminalTheme(
            id: "system",
            name: "System",
            foreground: .textColor,
            background: .textBackgroundColor,
            caret: nil,
            selectionBackground: .selectedTextBackgroundColor,
            useBrightColors: true,
            ansi16Palette: nil
        )
    }

    // VGA 16-color palette (matches SwiftTerm's internal vgaColors)
    static func vgaDark() -> TerminalTheme {
        let palette: [SwiftTerm.Color] = [
            color8(0, 0, 0),
            color8(170, 0, 0),
            color8(0, 170, 0),
            color8(170, 85, 0),
            color8(0, 0, 170),
            color8(170, 0, 170),
            color8(0, 170, 170),
            color8(170, 170, 170),
            color8(85, 85, 85),
            color8(255, 85, 85),
            color8(85, 255, 85),
            color8(255, 255, 85),
            color8(85, 85, 255),
            color8(255, 85, 255),
            color8(85, 255, 255),
            color8(255, 255, 255)
        ]
        return TerminalTheme(
            id: "vga-dark",
            name: "VGA (Dark)",
            foreground: NSColor(calibratedWhite: 0.85, alpha: 1),
            background: .black,
            caret: nil,
            selectionBackground: NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.6, alpha: 1),
            useBrightColors: true,
            ansi16Palette: palette
        )
    }

    // Xterm 16-color palette (matches SwiftTerm's internal xtermColors)
    static func xterm() -> TerminalTheme {
        let palette: [SwiftTerm.Color] = [
            color8(0, 0, 0),
            color8(205, 0, 0),
            color8(0, 205, 0),
            color8(205, 205, 0),
            color8(0, 0, 238),
            color8(205, 0, 205),
            color8(0, 205, 205),
            color8(229, 229, 229),
            color8(127, 127, 127),
            color8(255, 0, 0),
            color8(0, 255, 0),
            color8(255, 255, 0),
            color8(92, 92, 255),
            color8(255, 0, 255),
            color8(0, 255, 255),
            color8(255, 255, 255)
        ]
        return TerminalTheme(
            id: "xterm",
            name: "Xterm",
            foreground: NSColor(calibratedWhite: 0.89, alpha: 1),
            background: .black,
            caret: nil,
            selectionBackground: NSColor(calibratedRed: 0.25, green: 0.35, blue: 0.55, alpha: 1),
            useBrightColors: true,
            ansi16Palette: palette
        )
    }

    // GNOME-ish pale palette (matches SwiftTerm's internal paleColors)
    static func pale() -> TerminalTheme {
        let palette: [SwiftTerm.Color] = [
            color8(0x2e, 0x34, 0x36),
            color8(0xcc, 0x00, 0x00),
            color8(0x4e, 0x9a, 0x06),
            color8(0xc4, 0xa0, 0x00),
            color8(0x34, 0x65, 0xa4),
            color8(0x75, 0x50, 0x7b),
            color8(0x06, 0x98, 0x9a),
            color8(0xd3, 0xd7, 0xcf),
            color8(0x55, 0x57, 0x53),
            color8(0xef, 0x29, 0x29),
            color8(0x8a, 0xe2, 0x34),
            color8(0xfc, 0xe9, 0x4f),
            color8(0x72, 0x9f, 0xcf),
            color8(0xad, 0x7f, 0xa8),
            color8(0x34, 0xe2, 0xe2),
            color8(0xee, 0xee, 0xec)
        ]
        return TerminalTheme(
            id: "pale",
            name: "Pale",
            foreground: NSColor(calibratedWhite: 0.85, alpha: 1),
            background: NSColor(calibratedWhite: 0.10, alpha: 1),
            caret: nil,
            selectionBackground: NSColor(calibratedRed: 0.28, green: 0.36, blue: 0.45, alpha: 1),
            useBrightColors: true,
            ansi16Palette: palette
        )
    }

    // Terminal.app-like palette (matches SwiftTerm's internal terminalAppColors)
    static func terminalApp() -> TerminalTheme {
        let palette: [SwiftTerm.Color] = [
            color8(0, 0, 0),
            color8(194, 54, 33),
            color8(37, 188, 36),
            color8(173, 173, 39),
            color8(73, 46, 225),
            color8(211, 56, 211),
            color8(51, 187, 200),
            color8(203, 204, 205),
            color8(129, 131, 131),
            color8(252, 57, 31),
            color8(49, 231, 34),
            color8(234, 236, 35),
            color8(88, 51, 255),
            color8(249, 53, 248),
            color8(20, 240, 240),
            color8(233, 235, 235)
        ]
        return TerminalTheme(
            id: "terminal-app",
            name: "Terminal.app",
            foreground: NSColor(calibratedWhite: 0.88, alpha: 1),
            background: .black,
            caret: nil,
            selectionBackground: NSColor(calibratedRed: 0.25, green: 0.35, blue: 0.55, alpha: 1),
            useBrightColors: true,
            ansi16Palette: palette
        )
    }

    static let presets: [TerminalTheme] = [
        .system(),
        .xterm(),
        .vgaDark(),
        .terminalApp(),
        .pale()
    ]
}

extension TerminalView {
    func apply(theme: TerminalTheme) {
        self.nativeForegroundColor = theme.foreground
        self.nativeBackgroundColor = theme.background
        if let caret = theme.caret {
            self.caretColor = caret
        }
        self.selectedTextBackgroundColor = theme.selectionBackground
        self.useBrightColors = theme.useBrightColors
        if let p = theme.ansi16Palette, p.count == 16 {
            self.installColors(p)
        }
    }
}
#endif


