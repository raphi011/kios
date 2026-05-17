import Foundation
import SwiftData
@testable import Kios

/// Test helper that constructs and inserts a `Source` row into the given
/// `ModelContext`, returning it for use as the `source:` argument to `Book.init`
/// or service calls. Defaults to a local source so the common
/// "give me a Source for a book" case stays one line.
@MainActor
func testSource(
    kind: SourceKind = .local,
    displayName: String = "Test",
    serverURL: URL? = nil,
    sortOrder: Int = 0,
    into ctx: ModelContext
) -> Source {
    let s = Source(
        displayName: displayName,
        kind: kind,
        serverURL: serverURL,
        sortOrder: sortOrder
    )
    ctx.insert(s)
    return s
}
