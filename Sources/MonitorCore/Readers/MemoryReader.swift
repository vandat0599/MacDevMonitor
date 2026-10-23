import Darwin
import Foundation

public enum MemoryReader {
    /// Reads memory state straight from the kernel; cheap enough to call every few seconds.
    public static func read() -> MemoryStatus {
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        return MemoryStatus(
            physical: Int64(ProcessInfo.processInfo.physicalMemory),
            freePercent: Int(sysctlInt32("kern.memorystatus_level") ?? 0),
            pressure: PressureLevel(rawValue: Int(sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)) ?? .normal,
            swapTotal: Int64(swap.xsu_total),
            swapUsed: Int64(swap.xsu_used),
            compressed: compressorBytes(),
            bootTime: bootTime())
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func compressorBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(stats.compressor_page_count) * Int64(getpagesize())
    }

    private static func bootTime() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}

public enum DiskReader {
    public static func read(path: String = "/System/Volumes/Data") -> DiskStatus? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskStatus(total: Int64(total), available: available)
    }
}
