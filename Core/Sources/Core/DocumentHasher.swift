import Foundation
import CryptoKit

/// Computes KOReader's `Document:fastDigest()` partial MD5 over a file.
///
/// Reads up to 1024 bytes at offsets `1024 << (2*i)` for `i in -1...10`
/// (i = -1 yields offset 256), feeds each chunk through MD5, returns the
/// 32-char lowercase hex digest. Stops on EOF (empty read).
///
/// See `docs/research.md` §2.2 (`partial_md5_checksum`) and KOReader
/// discussion #14448 for the upstream reference. The offset sequence and
/// 1024-byte window size are byte-identical requirements, not
/// implementation choices — do not "simplify."
public enum DocumentHasher {

    public static func partialMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var md5 = Insecure.MD5()
        for i in -1...10 {
            let offset: UInt64 = (i == -1) ? 256 : UInt64(1024) << (2 * i)
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
