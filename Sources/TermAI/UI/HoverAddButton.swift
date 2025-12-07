import SwiftUI

struct HoverAddButton: View {
    let isVisible: Bool
    let lastOutput: String
    let alignRow: Int?
    let totalRows: Int
    let onAdd: () -> Void
    @State private var hoverButton: Bool = false

    var body: some View {
        let hasChunk = !lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        GeometryReader { geo in
            Group {
                if (isVisible || hoverButton) && hasChunk {
                    Button(action: onAdd) {
                        Label("Add Last Output", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .position(x: geo.size.width - 100, y: yPosition(in: geo.size.height))
                    .onHover { hoverButton = $0 }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isVisible || hoverButton)
    }

    private func yPosition(in height: CGFloat) -> CGFloat {
        guard let alignRow else { return height - 24 }
        let clampedRow = max(0, min(totalRows - 1, alignRow))
        let rowHeight = height / CGFloat(max(totalRows, 1))
        return rowHeight * (CGFloat(clampedRow) + 0.5)
    }
}


