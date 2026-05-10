import Foundation
import CryptoKit

/// Computes KOReader's `Document:fastDigest()` partial MD5 over a file.
///
/// Reads up to 1024 bytes at offsets `1024 << (2*i)` for `i in -1...10`,
/// concatenated through MD5, and returns the 32-char lowercase hex digest.
/// Stops early on EOF or read error. Must produce byte-identical results to
/// KOReader so that sync progress records match on the server.
public enum DocumentHasher {

    public static func partialMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var md5 = Insecure.MD5()
        for i in -1...10 {
            let offset: UInt64 = (i == -1) ? 256 : UInt64(1024) << (2 * i)
            do { try handle.seek(toOffset: offset) } catch { break }
            let chunk = try handle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
