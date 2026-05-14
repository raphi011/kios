import Foundation

struct DeviceCapability: Sendable {
    let physicalMemoryBytes: UInt64

    var ramGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }

    /// Strict 8 GB+ gate. The 7.5 floor accommodates iOS reporting slightly
    /// less than the marketing RAM size.
    var supportsGemma3_4b: Bool { ramGB >= 7.5 }

    static let current = DeviceCapability(
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )
}
