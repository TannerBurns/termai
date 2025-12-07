import SwiftUI

/// Compact performance monitoring view showing CPU and memory usage graphs
struct PerformanceGraphsView: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // CPU Graph
            MiniMetricView(
                label: "CPU",
                value: formatPercent(monitor.cpuUsage),
                history: monitor.cpuHistory,
                color: cpuColor,
                maxValue: 100
            )
            
            // Memory Graph
            MiniMetricView(
                label: "MEM",
                value: formatPercent(monitor.memoryUsagePercent),
                history: monitor.memoryHistory,
                color: memoryColor,
                maxValue: 100
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0.03))
        )
        .onHover { isHovered = $0 }
        .help("CPU: \(String(format: "%.1f", monitor.cpuUsage))% | Memory: \(String(format: "%.1f", monitor.memoryUsagePercent))% (\(String(format: "%.0f", monitor.memoryUsageMB)) MB)")
    }
    
    // MARK: - Formatting
    
    private func formatPercent(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.0f%%", value)
    }
    
    // MARK: - Dynamic Colors
    
    private var cpuColor: Color {
        let usage = monitor.cpuUsage
        if usage > 80 {
            return .red
        } else if usage > 50 {
            return .orange
        }
        return .green
    }
    
    private var memoryColor: Color {
        let usage = monitor.memoryUsagePercent
        if usage > 80 {
            return .red
        } else if usage > 50 {
            return .orange
        }
        return .cyan
    }
}

/// Individual mini metric display with sparkline graph
struct MiniMetricView: View {
    let label: String
    let value: String
    let history: [Double]
    let color: Color
    let maxValue: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Label and value
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(value)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
            }
            
            // Sparkline graph
            SparklineGraph(data: history, color: color, maxValue: maxValue)
                .frame(height: 14)
        }
        .frame(width: 52)
    }
}

/// Minimal sparkline graph for showing metric history
struct SparklineGraph: View {
    let data: [Double]
    let color: Color
    let maxValue: Double
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            
            if data.count > 1 {
                // Draw filled area under the line
                Path { path in
                    let points = normalizedPoints(width: width, height: height)
                    guard let first = points.first else { return }
                    
                    path.move(to: CGPoint(x: first.x, y: height))
                    path.addLine(to: first)
                    
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    
                    if let last = points.last {
                        path.addLine(to: CGPoint(x: last.x, y: height))
                    }
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.3), color.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                // Draw the line
                Path { path in
                    let points = normalizedPoints(width: width, height: height)
                    guard let first = points.first else { return }
                    
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            } else if let single = data.first {
                // Single point - draw a dot
                let y = height - (CGFloat(single / maxValue) * height)
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .position(x: width / 2, y: max(1.5, min(y, height - 1.5)))
            }
        }
    }
    
    private func normalizedPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard data.count > 0 else { return [] }
        
        let stepX = width / CGFloat(max(1, data.count - 1))
        
        return data.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            let normalizedValue = min(value / maxValue, 1.0)
            let y = height - (CGFloat(normalizedValue) * height)
            return CGPoint(x: x, y: max(1, min(y, height - 1)))
        }
    }
}

// MARK: - Compact Performance View (for Tab Bar)

/// Ultra-compact performance display for embedding in tab bars
struct CompactPerformanceView: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // CPU with label
            CompactMetricItem(
                label: "CPU",
                value: formatPercent(monitor.cpuUsage),
                color: cpuColor,
                history: monitor.cpuHistory,
                maxValue: 100
            )
            
            // Memory with label
            CompactMetricItem(
                label: "MEM",
                value: formatPercent(monitor.memoryUsagePercent),
                color: memoryColor,
                history: monitor.memoryHistory,
                maxValue: 100
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
        )
        .onHover { isHovered = $0 }
        .help("CPU: \(String(format: "%.1f", monitor.cpuUsage))% | Memory: \(String(format: "%.1f", monitor.memoryUsagePercent))% (\(String(format: "%.0f", monitor.memoryUsageMB)) MB)")
    }
    
    private func formatPercent(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.0f%%", value)
    }
    
    private var cpuColor: Color {
        let usage = monitor.cpuUsage
        if usage > 80 { return .red }
        else if usage > 50 { return .orange }
        return .green
    }
    
    private var memoryColor: Color {
        let usage = monitor.memoryUsagePercent
        if usage > 80 { return .red }
        else if usage > 50 { return .orange }
        return .cyan
    }
}

/// Single metric item with label and tiny sparkline
private struct CompactMetricItem: View {
    let label: String
    let value: String
    let color: Color
    let history: [Double]
    let maxValue: Double
    
    var body: some View {
        HStack(spacing: 4) {
            // Label
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
            
            // Tiny sparkline
            TinySparkline(data: history, color: color, maxValue: maxValue)
                .frame(width: 20, height: 10)
            
            // Percentage value
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

/// Minimal sparkline for very compact spaces
private struct TinySparkline: View {
    let data: [Double]
    let color: Color
    let maxValue: Double
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            
            if data.count > 1 {
                Path { path in
                    let points = normalizedPoints(width: width, height: height)
                    guard let first = points.first else { return }
                    
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
    }
    
    private func normalizedPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard data.count > 0 else { return [] }
        
        let stepX = width / CGFloat(max(1, data.count - 1))
        
        return data.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            let normalizedValue = min(value / maxValue, 1.0)
            let y = height - (CGFloat(normalizedValue) * height)
            return CGPoint(x: x, y: max(1, min(y, height - 1)))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PerformanceGraphsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Original larger view
            PerformanceGraphsView(monitor: PerformanceMonitor.shared)
            
            // Compact view for tab bar
            CompactPerformanceView(monitor: PerformanceMonitor.shared)
        }
        .padding()
        .frame(width: 300, height: 150)
        .background(Color.gray.opacity(0.2))
    }
}
#endif

