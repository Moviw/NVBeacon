import AppKit
import SwiftUI
import Charts

struct GPUHistoryPoint: Identifiable, Equatable {
    let timestamp: Date
    let user: String
    let value: Double
    let segment: Int
    var series: String { "\(user):\(segment)" }
    var id: String { "\(series):\(timestamp.timeIntervalSince1970)" }
}

struct GPUHistoryAreaPoint: Identifiable, Equatable {
    let point: GPUHistoryPoint
    let lower: Double
    let upper: Double
    var id: String { point.id }
}

enum GPUHistoryPlot {
    static let totalLabel = "GPU total"

    static func areas(from points: [GPUHistoryPoint]) -> [GPUHistoryAreaPoint] {
        let byTime = Dictionary(grouping: points.filter { $0.user != totalLabel }, by: \.timestamp)
        return byTime.keys.sorted().flatMap { time in
            var baseline = 0.0
            return (byTime[time] ?? []).sorted { $0.user < $1.user }.map { point in
                let area = GPUHistoryAreaPoint(point: point, lower: baseline, upper: baseline + point.value)
                baseline = area.upper
                return area
            }
        }
    }

    static func points(samples: [GPUHistorySample], hours: Int, now: Date, pollInterval: Int) -> [GPUHistoryPoint] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let visible = samples.filter { $0.timestamp >= start && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        let users = Set(visible.flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
        var result: [GPUHistoryPoint] = []
        for user in [totalLabel] + users {
            var previous: Date?
            var segment = 0
            for sample in visible {
                let value: Double?
                if user == totalLabel {
                    value = sample.totalUtilization
                } else if sample.unavailableUsers.contains(user) || sample.attributedSampleCount == 0 {
                    value = nil
                } else {
                    value = sample.users[user]?.average ?? 0
                }
                guard let value else { previous = nil; segment += 1; continue }
                if let previous, sample.timestamp.timeIntervalSince(previous) >= Double(max(120, pollInterval * 2)) {
                    segment += 1
                }
                result.append(GPUHistoryPoint(timestamp: sample.timestamp, user: user, value: value, segment: segment))
                previous = sample.timestamp
            }
        }
        // Keep at most ~360 points per continuous series for a responsive menu bar chart.
        let step = max(60, ceil(Double(hours * 3600) / 360 / 60) * 60)
        let buckets = Dictionary(grouping: result) { floor($0.timestamp.timeIntervalSince1970 / step) }
        return buckets.values.flatMap { bucket -> [GPUHistoryPoint] in
            let byUser = Dictionary(grouping: bucket, by: \.user)
            let times = Set(bucket.map(\.timestamp))
            // Keep partial/gapped buckets at minute resolution. Stable buckets share
            // one timestamp across users so area layers stack the same time sample.
            if byUser.values.contains(where: { points in
                points.count != times.count || Set(points.map(\.segment)).count > 1
            }) { return bucket }
            guard let timestamp = times.min() else { return [] }
            return byUser.values.compactMap { points in
                guard let first = points.first else { return nil }
                return GPUHistoryPoint(timestamp: timestamp, user: first.user,
                                       value: points.map(\.value).reduce(0, +) / Double(points.count), segment: first.segment)
            }
        }.sorted { $0.timestamp < $1.timestamp }

    }
}

struct GPUHistoryView: View {
    @ObservedObject var store: NVBeaconStore
    let state: ServerRuntimeState
    @State private var isExpanded = false
    @State private var hours = 1
    @State private var gpuIndex = 0
    @State private var selectedDate: Date?

    private var language: AppInterfaceLanguage { store.settings.resolvedLanguage }
    private func t(_ english: String, _ korean: String) -> String { language.text(english, korean) }
    private var history: [GPUHistorySample] { store.gpuHistory[state.id] ?? [] }
    private var indices: [Int] {
        let current = state.snapshot?.gpus.map(\.index) ?? []
        return current.isEmpty ? Set(history.map(\.gpuIndex)).sorted() : current.sorted()
    }
    private var selectedGPU: Int { indices.contains(gpuIndex) ? gpuIndex : (indices.first ?? 0) }
    private var samples: [GPUHistorySample] {
        let uuid = state.snapshot?.gpus.first { $0.index == selectedGPU }?.uuid
        return history.filter { $0.gpuIndex == selectedGPU && (uuid == nil || $0.gpuUUID == uuid) }
    }
    private var visibleSamples: [GPUHistorySample] {
        samples.filter { $0.timestamp >= Date().addingTimeInterval(-Double(hours * 3600)) }
    }
    private var points: [GPUHistoryPoint] {
        GPUHistoryPlot.points(samples: samples, hours: hours, now: Date(), pollInterval: store.settings.pollIntervalSeconds)
    }
    private var areas: [GPUHistoryAreaPoint] { GPUHistoryPlot.areas(from: points) }
    private var users: [String] {
        Set(visibleSamples.flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
    }
    private var palette: [Color] { [.blue, .orange, .green, .purple, .pink, .cyan, .indigo, .mint, .teal, .brown] }
    private var userColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: users.enumerated().map { index, user in
            let color = index < palette.count
                ? palette[index]
                : Color(hue: Double(index - palette.count) / Double(max(users.count - palette.count, 1)), saturation: 0.68, brightness: 0.82)
            return (user, color)
        })
    }
    private func color(for user: String) -> Color {
        if user == GPUHistoryPlot.totalLabel { return .secondary }
        return userColors[user] ?? .blue
    }
    private var cursorSample: GPUHistorySample? {
        guard let selectedDate else { return visibleSamples.last }
        return visibleSamples.min { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.settings.recordsGPUHistory {
                        Label(t("Recording paused", "기록 일시 중지"), systemImage: "pause.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Picker(t("GPU", "GPU"), selection: $gpuIndex) {
                            ForEach(indices, id: \.self) { index in Text("GPU \(index)").tag(index) }
                        }
                        .frame(maxWidth: 150)
                        Picker(t("Time range", "시간 범위"), selection: $hours) {
                            ForEach([1, 5, 12, 24], id: \.self) { value in Text("\(value)h").tag(value) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if points.isEmpty {
                        Text(store.settings.recordsGPUHistory
                             ? t("Waiting for the first history sample.", "첫 GPU 기록을 기다리는 중입니다.")
                             : t("Enable Record GPU history in General settings.", "일반 설정에서 GPU 기록 저장을 켜세요."))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 230, alignment: .center)
                    } else {
                        if let sample = cursorSample {
                            Text(sample.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                metricRow(user: GPUHistoryPlot.totalLabel, value: sample.totalUtilization)
                                ForEach(users, id: \.self) { user in
                                    metricRow(user: user, value: sample.unavailableUsers.contains(user) || sample.attributedSampleCount == 0
                                              ? nil : sample.users[user]?.average ?? 0)
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        historyChart
                        if users.isEmpty || visibleSamples.last?.attributedSampleCount == 0 {
                            Text(t("Per-user SM sampling unavailable or GPU idle. The gray line is measured GPU utilization.", "사용자별 SM 측정 불가 또는 GPU 유휴 상태입니다. 회색 선은 GPU 사용률입니다."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                if let error = store.gpuHistoryErrors[state.id] {
                    Text(t("History could not be saved: \(error)", "기록 저장 실패: \(error)"))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.top, 7)
        } label: {
            Label(t("GPU history by user", "사용자별 GPU 기록"), systemImage: "chart.xyaxis.line")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityIdentifier("gpu-history-\(state.id)")
        .onChange(of: hours) { _, _ in selectedDate = nil }
        .onChange(of: gpuIndex) { _, _ in selectedDate = nil }
    }

    private var historyChart: some View {
        Chart {
            ForEach(areas) { area in
                AreaMark(x: .value("Time", area.point.timestamp),
                         yStart: .value("SM %", area.lower), yEnd: .value("SM %", area.upper),
                         series: .value("Segment", area.point.series))
                    .foregroundStyle(color(for: area.point.user).opacity(0.45))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Time", area.point.timestamp), y: .value("SM %", area.upper),
                         series: .value("Segment", area.point.series))
                    .foregroundStyle(color(for: area.point.user))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)
            }
            ForEach(points.filter { $0.user == GPUHistoryPlot.totalLabel }) { point in
                LineMark(x: .value("Time", point.timestamp), y: .value("SM %", point.value),
                         series: .value("Segment", point.series))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let selectedDate {
                RuleMark(x: .value("Selected time", selectedDate)).foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: Date().addingTimeInterval(-Double(hours * 3600))...Date(),
                     range: .plotDimension(startPadding: 20, endPadding: 24))
        .chartYScale(domain: 0...max(100, max(areas.map(\.upper).max() ?? 0, points.map(\.value).max() ?? 0).rounded(.up)))
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number))%").font(.system(size: 12)) } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 12))
        } }
        .chartXSelection(value: $selectedDate)
        .frame(height: 230)
        .accessibilityLabel(t("GPU utilization history by user", "사용자별 GPU 사용률 기록"))
    }

    private func metricRow(user: String, value: Double?) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color(for: user)).frame(width: 18, height: 12)
            Text(user == GPUHistoryPlot.totalLabel ? t("GPU total", "GPU 전체") : user)
                .font(.system(size: 14, weight: .medium)).lineLimit(2)
            Spacer()
            Text(value.map { String(format: "%.1f%%", $0) } ?? t("Unavailable", "측정 불가"))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
        }
        .padding(.vertical, 2)
    }
}
