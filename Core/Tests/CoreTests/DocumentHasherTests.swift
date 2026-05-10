import Testing
import Foundation
import CryptoKit
@testable import Core

@Suite("DocumentHasher.partialMD5")
struct DocumentHasherTests {

    /// Empty file → MD5 of empty input.
    @Test func emptyFile() throws {
        let url = try writeTempFile(bytes: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let got = try DocumentHasher.partialMD5(of: url)
        #expect(got == "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// File shorter than the first offset (256 B) → first read returns 0 bytes
    /// (offset is past EOF) → algorithm stops → hash of empty input.
    @Test func fileShorterThanFirstOffset() throws {
        let url = try writeTempFile(bytes: Data(repeating: 0xAA, count: 200))
        defer { try? FileManager.default.removeItem(at: url) }

        let got = try DocumentHasher.partialMD5(of: url)
        #expect(got == "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// File exactly 1280 B of 0xAA. Offsets:
    ///   - i=-1 (256): reads bytes 256..1279 (1024 bytes of 0xAA)
    ///   - i= 0 (1024): reads bytes 1024..1279 (256 bytes of 0xAA, EOF)
    ///   - i= 1 (4096): past EOF — stop
    @Test func smallFileTwoWindows() throws {
        let payload = Data(repeating: 0xAA, count: 1280)
        let url = try writeTempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = md5Hex(Data(repeating: 0xAA, count: 1024) +
                              Data(repeating: 0xAA, count: 256))
        let got = try DocumentHasher.partialMD5(of: url)
        #expect(got == expected)
    }

    /// File large enough to hit several offsets. Byte at offset N has value
    /// (N & 0xFF), so the hash is sensitive to whether we read the right
    /// offsets.
    @Test func multipleWindows() throws {
        var bytes = Data(count: 20_000)
        for i in 0..<bytes.count { bytes[i] = UInt8(i & 0xFF) }
        let url = try writeTempFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        // Offsets reached: 256, 1024, 4096, 16384. Next is 65536 (past EOF) → stop.
        let chunks: [Data] = [
            bytes.subdata(in: 256..<(256 + 1024)),
            bytes.subdata(in: 1024..<(1024 + 1024)),
            bytes.subdata(in: 4096..<(4096 + 1024)),
            bytes.subdata(in: 16384..<min(16384 + 1024, bytes.count))
        ]
        let expected = md5Hex(chunks.reduce(Data(), +))
        let got = try DocumentHasher.partialMD5(of: url)
        #expect(got == expected)
    }

    @Test func nonexistentFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        #expect(throws: CocoaError.self) {
            _ = try DocumentHasher.partialMD5(of: url)
        }
    }

    private func writeTempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
