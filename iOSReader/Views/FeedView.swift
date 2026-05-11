import SwiftUI
import Core

struct FeedView: View {
    let feedURL: URL

    @Environment(AppEnvironment.self) private var env
    @State private var loader: FeedLoader?

    var body: some View {
        Group {
            if let loader {
                content(loader: loader)
            } else {
                ProgressView().task { setup() }
            }
        }
        .navigationTitle(loader?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setup() {
        guard let opds = env.opds, loader == nil else { return }
        let l = FeedLoader(opds: opds, initialURL: feedURL)
        loader = l
        Task { await l.loadFirstPage() }
    }

    @ViewBuilder
    private func content(loader: FeedLoader) -> some View {
        List {
            if case .failed(let msg) = loader.phase {
                Section { Text(msg).foregroundStyle(.orange) }
            }
            ForEach(loader.entries) { entry in
                row(for: entry)
            }
            if loader.nextURL != nil {
                Color.clear.frame(height: 1)
                    .listRowSeparator(.hidden)
                    .onAppear { Task { await loader.loadNextPage() } }
                if case .loadingMore = loader.phase {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await loader.refresh() }
    }

    @ViewBuilder
    private func row(for entry: OPDSFeed.Entry) -> some View {
        switch entry {
        case .navigation(let nav):
            NavigationLink {
                FeedView(feedURL: nav.href)
            } label: {
                VStack(alignment: .leading) {
                    Text(nav.title).font(.headline)
                    if let summary = nav.summary, !summary.isEmpty {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        case .acquisition(let acq):
            NavigationLink {
                BookDetailView(entry: acq)
            } label: {
                AcquisitionRow(entry: acq)
            }
        }
    }
}

private struct AcquisitionRow: View {
    let entry: AcquisitionEntry
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading) {
                Text(entry.title).font(.headline).lineLimit(2)
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let creds = try? env.authStore.load() {
            AuthenticatedAsyncImage(
                url: entry.thumbnailURL,
                http: Core.HTTPClient(credentials: creds.basic)
            ) {
                Image(systemName: "book.closed")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 56)
            }
            .scaledToFit()
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "book.closed")
                .frame(width: 40, height: 56)
        }
    }
}
