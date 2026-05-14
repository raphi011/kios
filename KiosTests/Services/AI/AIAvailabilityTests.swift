// KiosTests/Services/AI/AIAvailabilityTests.swift
import Testing
@testable import Kios
import Foundation

@Suite("AIAvailability")
struct AIAvailabilityTests {
    private struct StubStore: ModelAssetStoreReading {
        let status: InstallationStatus
        func installationStatus(for asset: ModelAsset) -> InstallationStatus { status }
    }
    private struct StubDownloads: ModelDownloadServiceReading {
        let download: DownloadProgress?
        func currentDownload() -> DownloadProgress? { download }
    }

    private func resolve(
        userEnabled: Bool = true,
        preferred: AIEngine = .gemma3_4b,
        ramGB: Double = 8.0,
        fm: EngineAvailability = .available,
        status: InstallationStatus = .installed(at: URL(fileURLWithPath: "/tmp/x")),
        download: DownloadProgress? = nil
    ) -> AIAvailability {
        AIAvailability.resolve(
            userEnabled: userEnabled,
            preferredEngine: preferred,
            capability: DeviceCapability(physicalMemoryBytes: UInt64(ramGB * 1_073_741_824)),
            assetStore: StubStore(status: status),
            downloads: StubDownloads(download: download),
            fmProbe: StaticFMProbe(value: fm)
        )
    }

    @Test("user disabled → both engines userDisabled, resolved nil")
    func userDisabled() {
        let a = resolve(userEnabled: false)
        #expect(a.fm == .userDisabled)
        #expect(a.gemma == .userDisabled)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: false) == nil)
    }

    @Test("everything fine: prefers Gemma when set")
    func preferGemmaAvailable() {
        let a = resolve(preferred: .gemma3_4b)
        #expect(a.gemma == .available)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: true) == .gemma3_4b)
    }

    @Test("prefer Gemma not downloaded, FM available → falls back to FM")
    func gemmaNotDownloadedFmAvail() {
        let a = resolve(status: .notInstalled)
        #expect(a.gemma == .modelNotDownloaded)
        #expect(a.fm == .available)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: true) == .foundationModels)
    }

    @Test("prefer Gemma not downloaded, FM unsupportedOS → nil")
    func gemmaNotDownloadedFmUnavail() {
        let a = resolve(fm: .unsupportedOS, status: .notInstalled)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: true) == nil)
    }

    @Test("<8GB device → Gemma unsupportedDevice, falls back to FM")
    func lowRamFallback() {
        let a = resolve(ramGB: 6.0)
        #expect(a.gemma == .unsupportedDevice)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: true) == .foundationModels)
    }

    @Test("Gemma installed but corrupt → modelCorrupt; FM if avail")
    func corrupt() {
        let a = resolve(status: .corrupt(reason: "x"))
        #expect(a.gemma == .modelCorrupt)
        #expect(a.resolved(preferred: .gemma3_4b, userEnabled: true) == .foundationModels)
    }

    @Test("download in progress → modelDownloading with fraction")
    func downloading() {
        let progress = DownloadProgress(assetID: ModelCatalog.gemma3_4b.id, bytesDownloaded: 50, bytesTotal: 100, bytesPerSecond: 1)
        let a = resolve(status: .partial(installedBytes: 50), download: progress)
        if case .modelDownloading(let f) = a.gemma {
            #expect(f == 0.5)
        } else {
            Issue.record("expected modelDownloading; got \(a.gemma)")
        }
    }
}
