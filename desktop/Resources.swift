import Darwin
import SwiftUI

struct ProcessUsage {
    let footprint: UInt64
    let peakFootprint: UInt64
    let bytesRead: UInt64
    let bytesWritten: UInt64
    private let started: UInt64
    private let cpuTime: UInt64
    private let sampledAt: UInt64

    init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0, usage.ri_proc_exit_abstime == 0 else { return nil }
        sampledAt = mach_absolute_time()
        started = usage.ri_proc_start_abstime
        cpuTime = usage.ri_user_time + usage.ri_system_time
        footprint = usage.ri_phys_footprint
        peakFootprint = usage.ri_lifetime_max_phys_footprint
        bytesRead = usage.ri_diskio_bytesread
        bytesWritten = usage.ri_diskio_byteswritten
    }

    func cpuShare(since previous: Self?) -> Double? {
        guard let previous, started == previous.started, sampledAt > previous.sampledAt,
              cpuTime >= previous.cpuTime else { return nil }
        // Both counters use Mach absolute time. A full core is a share of 1.
        return Double(cpuTime - previous.cpuTime) / Double(sampledAt - previous.sampledAt)
    }
}

struct SystemUsage {
    let memory = ProcessInfo.processInfo.physicalMemory
    let swapUsed: UInt64?
    let pressure: Int32?

    init() {
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : nil
        var level: Int32 = 0
        var levelSize = MemoryLayout.size(ofValue: level)
        pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 ? level : nil
    }
}

struct ResourcesView: View {
    let pid: String?
    @ObservedObject var history: UsageHistory
    @State private var process: ProcessUsage?
    @State private var cpu: Double?
    @State private var system = SystemUsage()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HistoryView(history: history)
                    .padding(16)
                    .background(card, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("okay-mlx process").font(.headline)
                    if let process {
                        metric("Memory footprint", bytes(process.footprint))
                        metric("Peak memory footprint", bytes(process.peakFootprint == 0 ? nil : process.peakFootprint))
                        metric("CPU usage", cpu?.formatted(.percent.precision(.fractionLength(1))) ?? "—")
                        metric("Disk read since launch", bytes(process.bytesRead))
                        metric("Disk written since launch", bytes(process.bytesWritten))
                        Text("100% CPU means one fully used core.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let message: LocalizedStringKey = pid == nil
                            ? "Start the service to see process usage."
                            : "Process usage is unavailable."
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(card, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text("This Mac").font(.headline)
                    metric("Total unified memory", bytes(system.memory))
                    metric("Memory pressure", pressureLabel)
                    metric("Swap used", bytes(system.swapUsed))
                }
                .padding(16)
                .background(card, in: RoundedRectangle(cornerRadius: 12))

                Text("Refreshes every 2 seconds while this tab is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: pid) {
            process = nil
            cpu = nil
            while !Task.isCancelled {
                let current = pid.flatMap { pid_t($0) }.flatMap { ProcessUsage(pid: $0) }
                cpu = current?.cpuShare(since: process)
                process = current
                system = SystemUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var card: Color { Color(nsColor: .controlBackgroundColor) }

    private var pressureLabel: String {
        switch system.pressure {
        case 1: String(localized: "Normal")
        case 2: String(localized: "Elevated")
        case 4: String(localized: "Critical")
        default: "—"
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func bytes(_ count: UInt64?) -> String {
        guard let count else { return "—" }
        return Int64(clamping: count).formatted(.byteCount(style: .memory))
    }
}
