import Darwin
import Foundation

enum Memory {
    /// The process's physical footprint right now, in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1e6
    }

    /// Peak resident size of the process so far, in MB.
    static func peakMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1e6
    }
}

enum Thermal {
    static var state: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

func fmt(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1e6) }
