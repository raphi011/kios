import Foundation
import Core

/// `CatalogBackend` for the Local pseudo-source. Library refresh is a
/// no-op — local books appear via `LocalImportService` writes, not catalog
/// pulls. Lets the Library tab render Local through the same code path as
/// remote sources without view-level special-casing.
public struct LocalImportCatalog: CatalogBackend {
    public init() {}

    public func listLibrary() async throws -> [CatalogEntry] {
        []
    }

    public func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        // Local books are never "downloaded" — their file is the import.
        // Hitting this is a logic error in the calling code.
        fatalError("LocalImportCatalog.resolveDownload should never be called")
    }

    public func probe() async throws {
        // Always reachable.
    }
}
