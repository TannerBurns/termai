import Foundation
import Darwin

/// Monitors CPU and memory usage of the current process using Mach kernel APIs
@MainActor
final class PerformanceMonitor: ObservableObject {
    /// Current CPU usage as a percentage (0-100+)
    @Published private(set) var cpuUsage: Double = 0
    
    /// Current memory usage as a percentage (0-100)
    @Published private(set) var memoryUsagePercent: Double = 0
    
    /// Current memory usage in megabytes (for tooltip detail)
    @Published private(set) var memoryUsageMB: Double = 0
    
    /// Total system memory in MB
    let totalMemoryMB: Double
    
    /// Historical CPU usage samples for graphing (percentages)
    @Published private(set) var cpuHistory: [Double] = []
    
    /// Historical memory usage samples for graphing (percentages)
    @Published private(set) var memoryHistory: [Double] = []
    
    /// Maximum number of samples to keep in history
    private let maxHistorySize = 30
    
    /// Timer for periodic sampling
    private var timer: Timer?
    
    /// Previous CPU time for delta calculation
    private var previousCPUTime: UInt64 = 0
    private var previousSampleTime: Date = Date()
    
    /// Shared instance for app-wide monitoring
    static let shared = PerformanceMonitor()
    
    private init() {
        // Get total system memory
        totalMemoryMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        // Initialize with first sample
        sampleMetrics()
    }
    
    /// Start monitoring with the specified interval
    func startMonitoring(interval: TimeInterval = 1.0) {
        stopMonitoring()
        
        // Take initial sample to establish baseline
        sampleMetrics()
        
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleMetrics()
            }
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Sample current CPU and memory metrics
    private func sampleMetrics() {
        let cpu = sampleCPUUsage()
        let memoryMB = sampleMemoryUsage()
        let memoryPercent = totalMemoryMB > 0 ? (memoryMB / totalMemoryMB) * 100 : 0
        
        cpuUsage = cpu
        memoryUsageMB = memoryMB
        memoryUsagePercent = memoryPercent
        
        // Update history (both as percentages for consistent graphing)
        cpuHistory.append(cpu)
        memoryHistory.append(memoryPercent)
        
        // Trim history to max size
        if cpuHistory.count > maxHistorySize {
            cpuHistory.removeFirst(cpuHistory.count - maxHistorySize)
        }
        if memoryHistory.count > maxHistorySize {
            memoryHistory.removeFirst(memoryHistory.count - maxHistorySize)
        }
    }
    
    // MARK: - Mach API Sampling
    
    /// Get CPU usage percentage using Mach thread info
    private func sampleCPUUsage() -> Double {
        let task = mach_task_self_
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        
        let result = task_threads(task, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else {
            return 0
        }
        
        defer {
            // Deallocate thread list
            let threadListSize = vm_size_t(MemoryLayout<thread_t>.stride * Int(threadCount))
            vm_deallocate(task, vm_address_t(bitPattern: threads), threadListSize)
        }
        
        var totalCPUTime: UInt64 = 0
        
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
                }
            }
            
            if infoResult == KERN_SUCCESS {
                // Skip idle threads
                if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                    // Convert to microseconds
                    let userTime = UInt64(threadInfo.user_time.seconds) * 1_000_000 + UInt64(threadInfo.user_time.microseconds)
                    let systemTime = UInt64(threadInfo.system_time.seconds) * 1_000_000 + UInt64(threadInfo.system_time.microseconds)
                    totalCPUTime += userTime + systemTime
                }
            }
        }
        
        // Calculate CPU percentage based on time delta
        let currentTime = Date()
        let timeDelta = currentTime.timeIntervalSince(previousSampleTime)
        
        var cpuPercent: Double = 0
        if timeDelta > 0 && previousCPUTime > 0 && totalCPUTime >= previousCPUTime {
            // Safe subtraction - only compute if totalCPUTime >= previousCPUTime to avoid overflow
            let cpuTimeDelta = Double(totalCPUTime - previousCPUTime)
            // Convert microseconds to seconds and calculate percentage
            cpuPercent = (cpuTimeDelta / 1_000_000) / timeDelta * 100
            // Clamp to reasonable range (can exceed 100% on multi-core)
            cpuPercent = min(max(cpuPercent, 0), 800) // Allow up to 800% for 8 cores
        }
        
        previousCPUTime = totalCPUTime
        previousSampleTime = currentTime
        
        return cpuPercent
    }
    
    /// Get memory usage in MB using Mach task info
    private func sampleMemoryUsage() -> Double {
        let task = mach_task_self_
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(task, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0
        }
        
        // phys_footprint is the most accurate measure of actual memory usage
        let bytesUsed = info.phys_footprint
        let mbUsed = Double(bytesUsed) / (1024 * 1024)
        
        return mbUsed
    }
}

