import Foundation
import Testing
@testable import NVBeacon

// Explicit opt-in only. Uses existing key-based connections, with no remote writes.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_LIVE_CHECK"] == "1"))
func liveHistorySamplingUsingExistingServers() async throws {
    let defaults = try #require(UserDefaults(suiteName: "com.leejaein.NVBeacon"))
    let data = try #require(defaults.data(forKey: "nvbeacon.settings"))
    let settings = try JSONDecoder().decode(AppSettings.self, from: data).normalized()
    let servers = settings.pollableServers.filter { $0.sshAuthenticationMode == .keyBased }
    #expect(!servers.isEmpty)
    for (index, server) in servers.enumerated() {
        let snapshot = try await SSHMetricsFetcher().fetchSummary(settings: server.connectionSettings(from: settings))
        #expect(!snapshot.gpus.isEmpty)
        let measured = snapshot.userUtilization.filter { $0.utilization != nil && $0.user != "(idle)" }
        let missing = snapshot.userUtilization.filter { $0.utilization == nil }
        let samples = GPUHistorySample.recording(snapshot, into: [], now: snapshot.takenAt)
        #expect(samples.count == snapshot.gpus.count)
        print("Live server \(index + 1): GPUs=\(snapshot.gpus.count), measured user/GPU pairs=\(measured.count), unavailable pairs=\(missing.count), idle=\(snapshot.userUtilization.filter { $0.user == "(idle)" }.count)")
        for hours in [1, 5, 12, 24] {
            let points = GPUHistoryPlot.points(samples: samples.filter { $0.gpuIndex == snapshot.gpus[0].index },
                                              hours: hours, now: snapshot.takenAt, pollInterval: settings.pollIntervalSeconds)
            #expect(!points.isEmpty)
        }
    }
}
