import Darwin
import Foundation

/// Samples how busy this Mac is: the share of processor time in use since the last sample, from the
/// kernel's tick counts, and the one-minute load average per active core. Each sample is cheap: two
/// system calls, no child process.
struct MirrorHostSampler {
    private var last: host_cpu_load_info?

    /// The share of processor time in use since the previous call, 0 to 1, and the load per core.
    /// The first call has no previous ticks and reports no processor use.
    mutating func sample() -> (cpu: Double, loadPerCore: Double) {
        var cpu = 0.0
        if let now = Self.ticks() {
            if let last {
                func delta(_ index: Int32) -> Double {
                    Double(Self.tick(now, index) &- Self.tick(last, index))
                }
                let busy = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
                let total = busy + delta(CPU_STATE_IDLE)
                if total > 0 { cpu = busy / total }
            }
            last = now
        }
        var averages = [Double](repeating: 0, count: 3)
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let load = getloadavg(&averages, 3) > 0 ? averages[0] / cores : 0
        return (cpu, load)
    }

    private static func ticks() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func tick(_ info: host_cpu_load_info, _ index: Int32) -> UInt32 {
        withUnsafeBytes(of: info.cpu_ticks) { $0.load(fromByteOffset: Int(index) * MemoryLayout<UInt32>.size, as: UInt32.self) }
    }
}
