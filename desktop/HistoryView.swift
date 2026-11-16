import Charts
import SwiftUI

/// THE HISTORY, charted: memory (the gateway's process, its model, swap), the gateway's CPU, the decode speed — over
/// the last 15 minutes to 24 hours; where the model changed (loaded, unloaded, its hot experts), a rule; where the Mac's
/// memory was under pressure, a band behind (orange elevated, red critical).
struct HistoryView: View {
    @ObservedObject var history: UsageHistory
    @State private var range: Span = .hour

    enum Span: String, CaseIterable {
        case quarter = "15 min", hour = "1 h", six = "6 h", day = "24 h"
        var seconds: TimeInterval {
            switch self {
            case .quarter: 15 * 60
            case .hour: 3600
            case .six: 6 * 3600
            case .day: 24 * 3600
            }
        }
    }

    private struct Event: Identifiable {
        let id: Date
        let label: String
    }

    var body: some View {
        let start = Date().addingTimeInterval(-range.seconds)
        let series = history.series(since: start)
        let events = history.events(since: start).map { Event(id: $0.time, label: $0.label) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Picker("Period", selection: $range) {
                    ForEach(Span.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if series.count < 2 {
                Text("Collecting: a sample every 5 seconds while the app runs, kept for a day.")
                    .foregroundStyle(.secondary)
            } else {
                chart("Memory, GB", series, events, labels: true) { s in
                    marks(s, "Gateway process", s.footprint.map { Double($0) / 1e9 })
                    marks(s, "Model (MLX)", s.modelBytes.map { Double($0) / 1e9 })
                    marks(s, "Swap used", s.swap.map { Double($0) / 1e9 })
                }
                chart("Gateway CPU, %", series, events) { s in
                    marks(s, "CPU", s.cpu.map { $0 * 100 })
                }
                chart("Decode speed, tokens/s", series, events) { s in
                    if let v = s.tokensPerSecond {
                        PointMark(x: .value("Time", s.time), y: .value("Value", v))
                            .foregroundStyle(by: .value("Series", String(localized: "Generation")))
                            .symbolSize(18)
                    }
                }
                Text("A sample every 5 seconds while the app runs. The gateway process: its own memory; the model's (MLX, "
                     + "on the GPU) apart. Bands: memory pressure (orange elevated, red critical). Lines: the model changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ChartContentBuilder
    private func marks(_ s: UsageSample, _ name: String, _ value: Double?) -> some ChartContent {
        if let value {
            LineMark(x: .value("Time", s.time), y: .value("Value", value),
                     series: .value("Series", String(localized: String.LocalizationValue(name))))
                .foregroundStyle(by: .value("Series", String(localized: String.LocalizationValue(name))))
                .interpolationMethod(.monotone)
        }
    }

    private func chart<C: ChartContent>(_ title: LocalizedStringKey, _ series: [UsageSample], _ events: [Event],
                                        labels: Bool = false,
                                        @ChartContentBuilder content: @escaping (UsageSample) -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(zip(series, series.dropFirst())), id: \.0.time) { pair in
                    if let p = pair.0.pressure, p >= 2 {
                        RectangleMark(xStart: .value("Time", pair.0.time), xEnd: .value("Time", pair.1.time))
                            .foregroundStyle((p >= 4 ? Color.red : Color.orange).opacity(0.12))
                    }
                }
                ForEach(series, id: \.time) { content($0) }
                ForEach(events) { e in
                    RuleMark(x: .value("Time", e.id))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            if labels { Text(e.label).font(.caption2).foregroundStyle(.secondary) }
                        }
                }
            }
            .chartXScale(domain: (series.first?.time ?? Date())...(series.last?.time ?? Date()))
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 150)
            .padding(.top, labels ? 14 : 0)
        }
    }
}
