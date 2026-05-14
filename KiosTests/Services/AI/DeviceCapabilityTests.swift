import Testing
@testable import Kios

@Suite("DeviceCapability")
struct DeviceCapabilityTests {
    @Test("8 GB marketed device supports Gemma")
    func eightGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 8 * 1_073_741_824)
        #expect(cap.supportsGemma4_e4b)
    }

    @Test("7.4 GiB reported (8 GB marketed, ~7% kernel reserve) supports Gemma")
    func underreported8GB() {
        let cap = DeviceCapability(physicalMemoryBytes: UInt64(7.4 * 1_073_741_824))
        #expect(cap.supportsGemma4_e4b)
    }

    @Test("6.5 GiB reported sits exactly on the threshold")
    func atThreshold() {
        let cap = DeviceCapability(physicalMemoryBytes: UInt64(6.5 * 1_073_741_824))
        #expect(cap.supportsGemma4_e4b)
    }

    @Test("6 GiB reported (max plausible underreport from a 6 GB device) is rejected")
    func sixGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 6 * 1_073_741_824)
        #expect(!cap.supportsGemma4_e4b)
    }

    @Test("4 GiB reported is rejected")
    func fourGB() {
        let cap = DeviceCapability(physicalMemoryBytes: 4 * 1_073_741_824)
        #expect(!cap.supportsGemma4_e4b)
    }

    @Test("ramDisplay formats to two decimal places")
    func ramDisplayFormat() {
        let cap = DeviceCapability(physicalMemoryBytes: UInt64(7.42 * 1_073_741_824))
        #expect(cap.ramDisplay == "7.42 GB")
    }
}
