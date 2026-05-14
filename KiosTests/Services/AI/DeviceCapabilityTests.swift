import Testing
@testable import Kios

@Suite("DeviceCapability")
struct DeviceCapabilityTests {
    @Test("8 GB RAM device supports Gemma")
    func eightGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 8 * 1_073_741_824)
        #expect(cap.supportsGemma3_4b)
    }

    @Test("7.5 GB RAM device supports Gemma (iOS rounds down)")
    func sevenAndAHalfGB() {
        let cap = DeviceCapability(physicalMemoryBytes: UInt64(7.5 * 1_073_741_824))
        #expect(cap.supportsGemma3_4b)
    }

    @Test("6 GB RAM device does not support Gemma")
    func sixGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 6 * 1_073_741_824)
        #expect(!cap.supportsGemma3_4b)
    }

    @Test("4 GB RAM device does not support Gemma")
    func fourGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 4 * 1_073_741_824)
        #expect(!cap.supportsGemma3_4b)
    }
}
