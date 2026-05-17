import SwiftUI
import SwiftData

/// Library tab header. Doubles as the navigation title — tapping the
/// chevron opens a Menu listing all configured sources. Bound to the
/// `library.selectedSourceID` AppStorage so the selection persists
/// across launches.
struct SourcePickerHeader: View {
    @Query(sort: [SortDescriptor(\Source.sortOrder)]) private var sources: [Source]
    @AppStorage("library.selectedSourceID") private var selectedSourceIDString: String?

    var body: some View {
        Menu {
            ForEach(serverSources) { source in
                Button {
                    selectedSourceIDString = source.id.uuidString
                } label: {
                    Label(source.displayName, systemImage: icon(source.kind))
                }
            }
            if !serverSources.isEmpty, let local = localSource {
                Divider()
                Button {
                    selectedSourceIDString = local.id.uuidString
                } label: {
                    Label(local.displayName, systemImage: "folder")
                }
            } else if let local = localSource {
                // Local-only case (no server sources yet): still let user tap
                // through, even though it's already selected by fallback.
                Button {
                    selectedSourceIDString = local.id.uuidString
                } label: {
                    Label(local.displayName, systemImage: "folder")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentSource?.displayName ?? "Library")
                    .font(EditorialTheme.serif(size: 34, weight: .bold))
                    .tracking(-0.75)
                    .foregroundStyle(EditorialTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EditorialTheme.ink)
            }
        }
    }

    // MARK: helpers

    private var serverSources: [Source] {
        sources.filter { $0.kind != .local }
    }
    private var localSource: Source? {
        sources.first(where: { $0.kind == .local })
    }
    private var currentSource: Source? {
        if let id = selectedSourceIDString.flatMap(UUID.init(uuidString:)),
           let match = sources.first(where: { $0.id == id }) {
            return match
        }
        // Fallback: first server source, else Local.
        return serverSources.first ?? localSource
    }

    private func icon(_ kind: SourceKind) -> String {
        switch kind {
        case .local: return "folder"
        case .opdsReadOnly: return "globe"
        case .kosync: return "books.vertical"
        case .kobo: return "book.closed"
        }
    }
}
