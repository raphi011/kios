// Kios/App/AICrashDiagnosticsLogger.swift
import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Persists MetricKit payloads (crashes, hangs, disk-write exceptions, and the
/// per-app exit-metric counters that include jetsam OOM kills) to disk so a
/// developer can pull them off the device via
/// `Xcode → Window → Devices and Simulators → <app> → Download Container`
/// without needing TestFlight.
///
/// Why this is necessary: iOS jetsam terminations are `SIGKILL` — they write
/// no `.ips` crash report and never appear in Xcode Organizer's Crashes tab.
/// The only programmatic signal is
/// `MXAppExitMetric.applicationExitMetrics.foregroundExitData
/// .cumulativeMemoryResourceLimitExitCount`. The first time the user reopens
/// the app after a jetsam, MetricKit delivers a `MXMetricPayload` we persist
/// here. Real crashes flow as `MXDiagnosticPayload.crashDiagnostics` with full
/// stack traces.
///
/// Files land at `Application Support/kios/diagnostics/<ISO timestamp>-<kind>.json`,
/// excluded from iCloud backup. The folder is auto-created on first use.
final class AICrashDiagnosticsLogger: NSObject, @unchecked Sendable {
    static let shared = AICrashDiagnosticsLogger()

    let outputDirectory: URL
    private let fileManager: FileManager

    private override init() {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        self.outputDirectory = appSupport
            .appendingPathComponent("kios", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        self.fileManager = .default
        super.init()
        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = self.outputDirectory
        try? url.setResourceValues(values)
    }

    /// Subscribe to MetricKit. Call once during app init from the main actor.
    /// MetricKit delivers payloads on the next launch following the event
    /// (typically within seconds), so registering on every launch is required
    /// — payloads are not buffered indefinitely.
    func install() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }
}

#if canImport(MetricKit)
extension AICrashDiagnosticsLogger: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(data: payload.jsonRepresentation(), kind: "metric")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(data: payload.jsonRepresentation(), kind: "diag")
        }
    }

    private func persist(data: Data, kind: String) {
        // Colons aren't legal in macOS-visible filenames once the container is
        // dragged onto a Mac; normalize them out so a developer can double-click.
        let timestamp = Date.now.ISO8601Format()
            .replacingOccurrences(of: ":", with: "-")
        let url = outputDirectory.appendingPathComponent("\(timestamp)-\(kind).json")
        try? data.write(to: url, options: .atomic)
    }
}
#endif
