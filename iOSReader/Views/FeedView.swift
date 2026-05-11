import SwiftUI
import SwiftData
import Core

struct FeedView: View {
    let feedURL: URL

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openBook) private var openBook

    @State private var loader: FeedLoader?
    @State private var pendingDialog: AcquisitionEntry?

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
        .confirmationDialog(
            pendingDialog?.title ?? "",
            isPresented: Binding(
                get: { pendingDialog != nil },
                set: { if !$0 { pendingDialog = nil } }
            ),
            presenting: pendingDialog
        ) { entry in
            ForEach(entry.acquisitions) { acq in
                Button(buttonLabel(entry: entry, acq: acq)) {
                    act(entry: entry, format: acq.format)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text(entry.authors.joined(separator: ", "))
        }
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
            Button {
                handleTap(entry: acq)
            } label: {
                AcquisitionRow(entry: acq,
                               downloadedFormats: downloadedFormats(for: acq))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Tap handling

    private func handleTap(entry: AcquisitionEntry) {
        if entry.acquisitions.count > 1 {
            pendingDialog = entry
        } else if let only = entry.acquisitions.first {
            act(entry: entry, format: only.format)
        }
    }

    private func act(entry: AcquisitionEntry, format: BookFormat) {
        if let existing = BookActions.findBook(serverID: entry.serverID,
                                               format: format, context: modelContext),
           existing.fileURL != nil {
            openBook(existing)
            return
        }
        guard let chosen = entry.acquisitions.first(where: { $0.format == format })
        else { return }
        let book = BookActions.upsertBook(entry: entry, chosen: chosen,
                                          context: modelContext)
        // Kick off the download in the background and push the reader
        // immediately. ReaderView shows a downloading-state UI until the
        // file lands, then transitions to the actual EPUB navigator.
        Task { _ = try? await env.downloads?.download(book: book) }
        openBook(book)
    }

    private func buttonLabel(entry: AcquisitionEntry, acq: Acquisition) -> String {
        let downloaded = BookActions.findBook(
            serverID: entry.serverID, format: acq.format, context: modelContext
        )?.fileURL != nil
        let verb = downloaded ? "Open" : "Download"
        return "\(verb) \(acq.format.rawValue.uppercased())"
    }

    private func downloadedFormats(for entry: AcquisitionEntry) -> Set<BookFormat> {
        let books = BookActions.findAllBooks(serverID: entry.serverID, context: modelContext)
        return Set(books.compactMap { $0.fileURL != nil ? $0.format : nil })
    }
}

private struct AcquisitionRow: View {
    let entry: AcquisitionEntry
    let downloadedFormats: Set<BookFormat>

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.headline).lineLimit(2)
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !entry.acquisitions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(entry.acquisitions) { acq in
                            FormatChip(format: acq.format,
                                       downloaded: downloadedFormats.contains(acq.format))
                        }
                    }
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

private struct FormatChip: View {
    let format: BookFormat
    let downloaded: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(format.rawValue.uppercased())
            if downloaded {
                Image(systemName: "checkmark")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(downloaded
                      ? Color.accentColor.opacity(0.15)
                      : Color.secondary.opacity(0.15))
        )
        .foregroundStyle(downloaded ? Color.accentColor : Color.secondary)
    }
}
