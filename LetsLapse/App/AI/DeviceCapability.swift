import Foundation

#if os(iOS)
import os
#endif

/// What this device can actually be asked to do with a multi-gigabyte model.
///
/// Every number here exists because Phase 0 measured a failure that had no error attached to it: on
/// an 8 GB iPhone the weights load fine (2.8 GB, ~2 s) and iOS kills the process the instant
/// inference starts, with no exception to catch and nothing on screen. A feature that can be
/// SIGKILLed has to be asked about *before* it runs, not caught after (docs/ai/phase0-findings.md).
enum DeviceCapability {
    // MARK: - Memory

    static var physicalMemoryBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// Memory visible to userspace, in gigabytes, unrounded.
    ///
    /// Deliberately not the marketing figure and deliberately not an `Int`: an "8 GB" iPhone 16 Pro
    /// reports about 7.1 GB here because iOS keeps roughly a gigabyte for itself, so a whole-number
    /// version of this number reads as 7 and a catalog floor of 8 locks the model out of a device
    /// that runs it. Model floors are set against what this returns, not against the spec sheet.
    static var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824
    }

    /// This process's memory budget, which on iOS is what decides whether the app lives.
    ///
    /// The distinction that matters: `available` is the *per-process* jetsam allowance, not a share
    /// of what the whole device has spare. Other apps quitting does not raise it — only this app
    /// releasing memory does, and only up to `limit`. Advice built on the other assumption would
    /// send people to the app switcher to fix something the app switcher cannot fix.
    struct MemoryBudget: Equatable {
        /// How much more this process may allocate before being terminated.
        let availableBytes: Int64
        /// What this process is holding now.
        let footprintBytes: Int64

        /// The ceiling this process will ever have. Below the increased-memory-limit entitlement
        /// this sits around 3.0–3.4 GB on an 8 GB iPhone; with it, near physical memory.
        var limitBytes: Int64 { availableBytes + footprintBytes }
    }

    /// The budget, or nil where the question doesn't apply.
    ///
    /// macOS has no comparable per-process ceiling — it swaps rather than terminating — so the Mac
    /// answer is deliberately nil rather than a number that would gate a Mac out of a feature it
    /// runs perfectly well.
    static var memoryBudget: MemoryBudget? {
        #if os(iOS)
        return MemoryBudget(
            availableBytes: Int64(os_proc_available_memory()),
            footprintBytes: physicalFootprintBytes())
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// `phys_footprint` — the same figure jetsam bills the process for, so it is the right
    /// complement to `os_proc_available_memory()` and not merely resident size.
    private static func physicalFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
    #endif

    // MARK: - Disk

    /// Free space for a download, using the "important usage" figure — the one that accounts for
    /// purgeable caches iOS will evict for a file the user actually asked for.
    static func availableDiskBytes(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
