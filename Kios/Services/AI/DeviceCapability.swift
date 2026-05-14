import Foundation

struct DeviceCapability: Sendable {
    let physicalMemoryBytes: UInt64

    var ramGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }

    /// Display string for the reported RAM, e.g. `"7.42 GB"`. Used by the
    /// Settings AI section so users can see what the kernel is actually
    /// reporting (which is typically less than the marketed RAM — iOS reserves
    /// a slice for the system).
    var ramDisplay: String { String(format: "%.2f GB", ramGB) }

    /// Gemma 4 E4B q4 (multimodal, 5.2 GB on disk) + 4-bit-quantized KV cache
    /// + the rest of the reader needs roughly 4.5-5.5 GB resident at peak.
    /// We gate at 6.5 GiB reported, not the marketed 8 GB, because
    /// `ProcessInfo.physicalMemory` underreports the marketed total by 3-8%
    /// (iOS reserves RAM for the kernel; the exact amount varies by SKU and
    /// iOS version). 6.5 cleanly separates 8 GB devices — which can dip as
    /// low as ~7.4 GiB reported — from 6 GB devices, which max out around
    /// ~5.8 GiB. The `increased-memory-limit` entitlement is what actually
    /// lifts the per-process cap high enough for the model to run on 8 GB
    /// devices; without it, 8 GB phones would still get jetsammed during load.
    var supportsGemma4_e4b: Bool { ramGB >= 6.5 }

    static let current = DeviceCapability(
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )
}
