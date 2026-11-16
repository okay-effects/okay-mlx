import Foundation

/// One moment of the gateway and its model: the server process (its memory footprint — the model's unified memory
/// counted in it — and its CPU), the model in memory (MLX's active memory, its name, its hot experts), the Mac
/// (memory pressure, swap) and the decode speed of what was generating.
struct UsageSample: Sendable {
    let time: Date
    let footprint: UInt64?
    let cpu: Double?
    let modelBytes: Int64?
    let model: String?
    let slots: Int?
    let pressure: Int?
    let swap: UInt64?
    let tokensPerSecond: Double?

    /// A line of the history file: tab-separated, empty for none.
    var line: String {
        func s<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "" }
        return [String(Int64(time.timeIntervalSince1970)), s(footprint), cpu.map { String(format: "%.4f", $0) } ?? "",
                s(modelBytes), (model ?? "").replacingOccurrences(of: "\t", with: " "), s(slots), s(pressure),
                s(swap), tokensPerSecond.map { String(format: "%.2f", $0) } ?? ""].joined(separator: "\t")
    }

    init(time: Date, footprint: UInt64?, cpu: Double?, modelBytes: Int64?, model: String?, slots: Int?,
         pressure: Int?, swap: UInt64?, tokensPerSecond: Double?) {
        self.time = time; self.footprint = footprint; self.cpu = cpu; self.modelBytes = modelBytes
        self.model = model; self.slots = slots; self.pressure = pressure; self.swap = swap
        self.tokensPerSecond = tokensPerSecond
    }

    init?(line: String) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 9, let t = Double(f[0]) else { return nil }
        time = Date(timeIntervalSince1970: t)
        footprint = UInt64(f[1]); cpu = Double(f[2]); modelBytes = Int64(f[3])
        model = f[4].isEmpty ? nil : f[4]; slots = Int(f[5]); pressure = Int(f[6]); swap = UInt64(f[7])
        tokensPerSecond = Double(f[8])
    }
}

/// THE HISTORY of the gateway's and its model's use of the Mac: a sample every 5 seconds, taken while the app runs
/// (the hub's loop, window open or not), kept for a day in ~/Library/Application Support/okay-mlx/usage.tsv —
/// so a chart shows what happened while nobody was looking, across the app's restarts.
@MainActor
final class UsageHistory: ObservableObject {
    static let interval: TimeInterval = 5
    static let kept: TimeInterval = 24 * 3600

    @Published private(set) var samples: [UsageSample] = []
    private var previous: ProcessUsage?
    private var lastTaken = Date.distantPast
    private var appended = 0
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("okay-mlx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("usage.tsv")
        let since = Date().addingTimeInterval(-Self.kept)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            samples = text.split(separator: "\n").compactMap { UsageSample(line: String($0)) }.filter { $0.time >= since }
        }
        rewrite()
    }

    /// a sample, if one is due: the server's process by its pid, the model by the gateway's status
    func take(pid: String?, admin: Admin.Status?) {
        let now = Date()
        guard now.timeIntervalSince(lastTaken) >= Self.interval - 0.5 else { return }
        lastTaken = now
        let process = pid.flatMap { pid_t($0) }.flatMap { ProcessUsage(pid: $0) }
        let cpu = process?.cpuShare(since: previous)
        previous = process
        let system = SystemUsage()
        let going = admin?.generations?.map(\.per_second).filter { $0 > 0 }
        let speed: Double? = if let going, !going.isEmpty { going.reduce(0, +) } else {
            admin?.last_generation.flatMap { g in
                now.timeIntervalSince1970 * 1000 - Double(g.at) < Self.interval * 1000 ? g.decode_per_second : nil
            }
        }
        let sample = UsageSample(
            time: now, footprint: process?.footprint, cpu: cpu,
            modelBytes: admin.flatMap { $0.mlx_active_bytes >= 0 && $0.loaded != nil ? $0.mlx_active_bytes : nil },
            // the model: its name; "-" none loaded; nil the gateway did not answer (unknown, no event)
            model: admin.map { $0.loaded?.model ?? "-" }, slots: admin?.loaded?.expert_slots,
            pressure: system.pressure.map(Int.init), swap: system.swapUsed, tokensPerSecond: speed)
        samples.append(sample)
        let since = now.addingTimeInterval(-Self.kept)
        if let first = samples.first, first.time < since { samples.removeAll { $0.time < since } }
        append(sample)
    }

    private func append(_ sample: UsageSample) {
        guard let data = (sample.line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
        appended += 1
        // the file kept to the day it shows: rewritten from memory every hour of samples
        if appended >= Int(3600 / Self.interval) { rewrite() }
    }

    private func rewrite() {
        appended = 0
        let text = samples.map(\.line).joined(separator: "\n") + (samples.isEmpty ? "" : "\n")
        try? text.data(using: .utf8)?.write(to: file, options: .atomic)
    }

    /// the samples since `start`, at most `points` of them: averaged in buckets of equal time (a day of samples is
    /// 17 280; a chart needs a few hundred)
    func series(since start: Date, points: Int = 360) -> [UsageSample] {
        let shown = samples.filter { $0.time >= start }
        guard shown.count > points, let first = shown.first?.time, let last = shown.last?.time else { return shown }
        let width = max(1, last.timeIntervalSince(first) / Double(points))
        var buckets: [Int: [UsageSample]] = [:]
        for s in shown { buckets[Int(s.time.timeIntervalSince(first) / width), default: []].append(s) }
        return buckets.keys.sorted().compactMap { k in
            guard let b = buckets[k], let mid = b.last else { return nil }
            func avg<T: BinaryInteger>(_ f: (UsageSample) -> T?) -> T? {
                let v = b.compactMap(f); return v.isEmpty ? nil : T(v.reduce(0) { $0 + Double($1) } / Double(v.count))
            }
            func avgD(_ f: (UsageSample) -> Double?) -> Double? {
                let v = b.compactMap(f); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
            }
            func peak(_ f: (UsageSample) -> Double?) -> Double? { b.compactMap(f).max() }
            return UsageSample(time: mid.time, footprint: avg(\.footprint), cpu: avgD(\.cpu),
                               modelBytes: avg(\.modelBytes), model: mid.model, slots: mid.slots,
                               pressure: b.compactMap(\.pressure).max(), swap: avg(\.swap),
                               tokensPerSecond: peak(\.tokensPerSecond))
        }
    }

    /// where the model changed: loaded, unloaded, another, or its hot experts changed (in place or by a reload)
    func events(since start: Date) -> [(time: Date, label: String)] {
        var out: [(Date, String)] = []
        var last: (String?, Int?)? = nil
        for s in samples where s.model != nil {
            let now = (s.model, s.slots)
            if let l = last, l.0 != now.0 || l.1 != now.1, s.time >= start {
                out.append((s.time, Self.label(model: s.model, slots: s.slots)))
            }
            last = now
        }
        return out
    }

    static func label(model: String?, slots: Int?) -> String {
        guard let model, model != "-" else { return String(localized: "unloaded") }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        guard let slots else { return name }
        return slots > 0 ? String(localized: "\(name) · \(slots) hot experts") : name
    }
}
