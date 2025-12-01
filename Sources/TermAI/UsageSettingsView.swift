import SwiftUI
import Charts

// MARK: - Usage Settings View

struct UsageSettingsView: View {
    @ObservedObject private var tracker = TokenUsageTracker.shared
    @Environment(\.colorScheme) var colorScheme
    
    @State private var selectedRange: UsageTimeRange = .week
    @State private var selectedFilter: UsageFilter = .all
    @State private var showClearConfirmation = false
    
    enum UsageFilter: String, CaseIterable {
        case all = "All"
        case byProvider = "By Provider"
        case byModel = "By Model"
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Time Range Selector
                timeRangeSection
                
                // Summary Stats
                summarySection
                
                // Usage Over Time Chart
                usageOverTimeSection
                
                // Breakdown Charts
                breakdownSection
                
                // Request Types
                requestTypesSection
                
                // Clear Data
                clearDataSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
    }
    
    // MARK: - Time Range Section
    
    private var timeRangeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Time Range", subtitle: "Select the time period to view usage data")
            
            HStack(spacing: 8) {
                ForEach(UsageTimeRange.allCases, id: \.self) { range in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedRange = range
                        }
                    }) {
                        Text(range.rawValue)
                            .font(.system(size: 12, weight: selectedRange == range ? .semibold : .regular))
                            .foregroundColor(selectedRange == range ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedRange == range ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - Summary Section
    
    private var summarySection: some View {
        let usage = tracker.getTotalUsage(for: selectedRange)
        
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Summary", subtitle: "Token usage statistics for \(selectedRange.rawValue.lowercased())")
            
            // Token stats row
            HStack(spacing: 12) {
                StatCard(
                    title: "Total Tokens",
                    value: formatNumber(usage.total),
                    icon: "sum",
                    color: .blue
                )
                
                StatCard(
                    title: "Prompt Tokens",
                    value: formatNumber(usage.prompt),
                    icon: "arrow.up.doc",
                    color: .orange
                )
                
                StatCard(
                    title: "Completion Tokens",
                    value: formatNumber(usage.completion),
                    icon: "arrow.down.doc",
                    color: .green
                )
            }
            
            // Request stats row
            HStack(spacing: 12) {
                StatCard(
                    title: "API Requests",
                    value: formatNumber(usage.requests),
                    icon: "network",
                    color: .purple
                )
                
                StatCard(
                    title: "Tool Calls",
                    value: formatNumber(usage.toolCalls),
                    icon: "hammer.fill",
                    color: .indigo
                )
                
                StatCard(
                    title: "Avg Tokens/Request",
                    value: usage.requests > 0 ? formatNumber(usage.total / usage.requests) : "—",
                    icon: "divide",
                    color: .teal
                )
            }
        }
    }
    
    // MARK: - Usage Over Time Section
    
    private var usageOverTimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Usage Over Time", subtitle: "Token consumption trend")
            
            let data = selectedRange == .today
                ? tracker.getHourlyUsage(for: selectedRange)
                : tracker.getDailyUsage(for: selectedRange)
            
            if data.isEmpty {
                EmptyChartPlaceholder(message: "No usage data for this time period")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Line Chart
                    Chart(data) { item in
                        LineMark(
                            x: .value("Time", item.date),
                            y: .value("Tokens", item.totalTokens)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .interpolationMethod(.catmullRom)
                        
                        AreaMark(
                            x: .value("Time", item.date),
                            y: .value("Tokens", item.totalTokens)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { value in
                            AxisGridLine()
                            AxisValueLabel(format: selectedRange == .today ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let intValue = value.as(Int.self) {
                                    Text(formatCompactNumber(intValue))
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                    
                    // Bar Chart for Prompt vs Completion
                    HStack {
                        Text("Prompt vs Completion")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    Chart {
                        ForEach(data) { item in
                            BarMark(
                                x: .value("Time", item.date),
                                y: .value("Tokens", item.promptTokens)
                            )
                            .foregroundStyle(by: .value("Type", "Prompt"))
                            .position(by: .value("Type", "Prompt"))
                            
                            BarMark(
                                x: .value("Time", item.date),
                                y: .value("Tokens", item.completionTokens)
                            )
                            .foregroundStyle(by: .value("Type", "Completion"))
                            .position(by: .value("Type", "Completion"))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { value in
                            AxisGridLine()
                            AxisValueLabel(format: selectedRange == .today ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let intValue = value.as(Int.self) {
                                    Text(formatCompactNumber(intValue))
                                }
                            }
                        }
                    }
                    .chartForegroundStyleScale([
                        "Prompt": Color.orange,
                        "Completion": Color.green
                    ])
                    .chartLegend(position: .bottom, spacing: 16)
                    .frame(height: 150)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }
    
    // MARK: - Breakdown Section
    
    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SettingsSectionHeader("Breakdown", subtitle: "Usage by provider and model")
                
                Spacer()
                
                Picker("", selection: $selectedFilter) {
                    ForEach(UsageFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            
            let providerData = tracker.getUsageByProvider(for: selectedRange)
            let modelData = tracker.getUsageByModel(for: selectedRange)
            
            if providerData.isEmpty && modelData.isEmpty {
                EmptyChartPlaceholder(message: "No usage data to break down")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // Provider breakdown
                    if selectedFilter == .all || selectedFilter == .byProvider {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By Provider")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            if providerData.isEmpty {
                                Text("No data")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .frame(height: 150)
                            } else {
                                Chart(providerData) { item in
                                    BarMark(
                                        x: .value("Tokens", item.totalTokens),
                                        y: .value("Provider", item.provider ?? "Unknown")
                                    )
                                    .foregroundStyle(by: .value("Provider", item.provider ?? "Unknown"))
                                    .cornerRadius(4)
                                }
                                .chartLegend(.hidden)
                                .frame(height: 100)
                                
                                // Provider details list
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(providerData.prefix(5)) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.provider ?? "Unknown")
                                                .font(.system(size: 11, weight: .medium))
                                            HStack(spacing: 12) {
                                                Label(formatCompactNumber(item.totalTokens), systemImage: "sum")
                                                Label("\(item.requestCount)", systemImage: "network")
                                                Label("\(item.toolCallCount)", systemImage: "hammer.fill")
                                            }
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                    
                    // Model breakdown
                    if selectedFilter == .all || selectedFilter == .byModel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By Model")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            if modelData.isEmpty {
                                Text("No data")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .frame(height: 150)
                            } else {
                                Chart(modelData.prefix(6)) { item in
                                    BarMark(
                                        x: .value("Tokens", item.totalTokens),
                                        y: .value("Model", item.model ?? "Unknown")
                                    )
                                    .foregroundStyle(Color.accentColor.gradient)
                                    .cornerRadius(4)
                                }
                                .chartXAxis {
                                    AxisMarks(position: .bottom) { value in
                                        AxisValueLabel {
                                            if let intValue = value.as(Int.self) {
                                                Text(formatCompactNumber(intValue))
                                            }
                                        }
                                    }
                                }
                                .frame(height: 100)
                                
                                // Model details list
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(modelData.prefix(6)) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.model ?? "Unknown")
                                                .font(.system(size: 11, weight: .medium))
                                                .lineLimit(1)
                                            HStack(spacing: 12) {
                                                Label(formatCompactNumber(item.totalTokens), systemImage: "sum")
                                                Label("\(item.requestCount)", systemImage: "network")
                                                Label("\(item.toolCallCount)", systemImage: "hammer.fill")
                                            }
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }
    
    // MARK: - Request Types Section
    
    private var requestTypesSection: some View {
        let requestTypeData = tracker.getUsageByRequestType(for: selectedRange)
        
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Request Types", subtitle: "Breakdown by type of API call")
            
            if requestTypeData.isEmpty {
                EmptyChartPlaceholder(message: "No request type data available")
            } else {
                HStack(spacing: 16) {
                    // Request type chart
                    Chart(requestTypeData) { item in
                        BarMark(
                            x: .value("Count", item.count),
                            y: .value("Type", item.requestType.rawValue)
                        )
                        .foregroundStyle(colorForRequestType(item.requestType).gradient)
                        .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(position: .bottom) { value in
                            AxisValueLabel()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(requestTypeData.count * 32 + 20))
                    
                    // Request type details
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(requestTypeData) { item in
                            HStack {
                                Circle()
                                    .fill(colorForRequestType(item.requestType))
                                    .frame(width: 8, height: 8)
                                Text(item.requestType.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(item.count) calls")
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(formatCompactNumber(item.totalTokens) + " tokens")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(width: 180)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }
    
    private func colorForRequestType(_ type: UsageRequestType) -> Color {
        switch type {
        case .chat: return .blue
        case .toolCall: return .indigo
        case .titleGeneration: return .purple
        case .summarization: return .orange
        case .planning: return .green
        case .reflection: return .teal
        }
    }
    
    // MARK: - Clear Data Section
    
    private var clearDataSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage Data")
                    .font(.system(size: 13, weight: .medium))
                Text("Clear all stored token usage data. This action cannot be undone.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { showClearConfirmation = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Clear Data")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
        .alert("Clear Usage Data", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                tracker.clearAllData()
            }
        } message: {
            Text("Are you sure you want to clear all token usage data? This action cannot be undone.")
        }
    }
    
    // MARK: - Helpers
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
    
    private func formatCompactNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return "\(number)"
    }
}

// MARK: - Supporting Views

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Spacer()
            }
            
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundColor(.secondary)
        }
    }
}

private struct EmptyChartPlaceholder: View {
    let message: String
    
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}


