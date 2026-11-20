// ResourceUsage.swift — process CPU time, memory and thermal state for the measurement log (1.5.0)
import Darwin
import Foundation

public enum ResourceUsage {
    /// User + system CPU time of this process so far.
    public static func cpuTime() -> Duration {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let micros = (Int64(usage.ru_utime.tv_sec) + Int64(usage.ru_stime.tv_sec)) * 1_000_000
            + Int64(usage.ru_utime.tv_usec) + Int64(usage.ru_stime.tv_usec)
        return .microseconds(micros)
    }

    /// Physical footprint (what Activity Monitor shows as memory), in MB; nil if unknown.
    public static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : nil
    }

    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
