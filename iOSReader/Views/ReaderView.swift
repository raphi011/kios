import SwiftUI
import SwiftData
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator
import Core

// MARK: - ReaderView

struct ReaderView: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query private var books: [Book]
    @Query private var downloads: [Download]

    @State private var publication: Publication?
    @State private var initialLocator: Locator?
    @State private var loadError: String?
    @State private var pendingPrompt: PromptInfo?

    init(bookID: UUID) {
        self.bookID = bookID
        let id = bookID
        _books = Query(filter: #Predicate<Book> { $0.id == id })
        _downloads = Query(filter: #Predicate<Download> { $0.bookID == id })
    }

    private var book: Book? { books.first }
    private var download: Download? { downloads.first }

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: ProgressDownload
    }

    var body: some View {
        Group {
            if let book {
                if book.fileURL != nil, let publication {
                    let id = book.id
                    ReaderHost(
                        publication: publication,
                        initialLocator: initialLocator,
                        onLocatorChange: { @Sendable locator in
                            Task { @MainActor in await pushLocator(bookID: id, locator: locator) }
                        }
                    )
                    .ignoresSafeArea()
                    .task { await onOpen(book: book) }
                    .alert(item: $pendingPrompt) { info in
                        Alert(
                            title: Text("Continue from another device?"),
                            message: Text(
                                "\(Int(info.server.percentage * 100))% on '\(info.server.device)'"
                            ),
                            primaryButton: .default(Text("Continue")) {
                                // v1: silently accept. A polished version would
                                // seek the navigator to info.server. For now we
                                // dismiss the alert; next locator change will
                                // overwrite the server state with whatever this
                                // device shows.
                            },
                            secondaryButton: .cancel(Text("Stay here"))
                        )
                    }
                } else if book.fileURL == nil {
                    DownloadingView(book: book, download: download)
                } else if let loadError {
                    Text(loadError).foregroundStyle(.orange)
                } else {
                    ProgressView("Opening…")
                }
            } else {
                Text("Book not found").foregroundStyle(.secondary)
            }
        }
        .task(id: book?.fileURL) { await loadPublicationIfReady() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await flush() }
            }
        }
        .onDisappear {
            Task { await flush() }
        }
    }

    // MARK: - Private

    private func loadPublicationIfReady() async {
        guard let book, let fileURL = book.fileURL else { return }
        let id = bookID
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            initialLocator = try? Locator(jsonString: progress.locatorJSON)
        }
        do {
            publication = try await openPublication(at: fileURL)
        } catch {
            let diagnostics = fileDiagnostics(at: fileURL)
            loadError = "Failed to open:\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n\(diagnostics)"
        }
    }

    /// Returns a multi-line string describing the on-disk state of `url` so
    /// we can tell from the error UI whether the URL points to a missing file,
    /// the wrong scheme, or bytes that aren't an EPUB.
    private func fileDiagnostics(at url: URL) -> String {
        var lines: [String] = []
        lines.append("URL: \(url.absoluteString)")
        lines.append("Scheme: \(url.scheme ?? "<none>")")
        lines.append("Path: \(url.path)")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        lines.append("Exists: \(exists)")
        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                lines.append("Size: \(size) bytes")
            }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let head = handle.readData(ofLength: 4)
                lines.append("Head: \(head.map { String(format: "%02x", $0) }.joined())")
            } else {
                lines.append("Head: <unreadable>")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Opens a Publication from a local file URL using Readium 3.8's streamer.
    /// Uses CompositePublicationParser with EPUBParser only (v1 supports EPUB).
    private func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw OpenError.invalidFileURL(url)
        }

        let asset = try await assetRetriever.retrieve(url: fileURL)
            .mapError { OpenError.asset($0) }
            .get()

        // v1: only EPUB is supported; EPUBParser has a public init.
        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        return try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { OpenError.publication($0) }
            .get()
    }

    private enum OpenError: LocalizedError {
        case invalidFileURL(URL)
        case asset(AssetRetrieveURLError)
        case publication(PublicationOpenError)

        var errorDescription: String? {
            switch self {
            case .invalidFileURL(let url):
                return "Readium rejected the file URL: \(url.absoluteString)"
            case .asset(let inner):
                return "Asset retrieval failed: \(Self.describe(inner))"
            case .publication(let inner):
                return "Publication open failed: \(inner.localizedDescription)"
            }
        }

        private static func describe(_ error: AssetRetrieveURLError) -> String {
            switch error {
            case .schemeNotSupported(let scheme):
                return "scheme '\(scheme.rawValue)' not supported"
            case .formatNotSupported:
                return "format not recognized (sniffer found no specifications — wrong extension / corrupted file / missing file)"
            case .reading(let inner):
                return "read error: \(inner.localizedDescription)"
            }
        }
    }

    private func onOpen(book: Book) async {
        guard let sync = env.sync else { return }
        do {
            switch try await sync.onOpen(book: book) {
            case .useLocal: break
            case .applyServer: break  // v1: rely on next locator change
            case .promptUser(let local, let server):
                pendingPrompt = PromptInfo(local: local, server: server)
            }
        } catch {
            // Best-effort onOpen; ignore failures.
        }
    }

    private func currentBook() -> Book? {
        let id = bookID
        return try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func flush() async {
        guard let sync = env.sync, let book = currentBook() else { return }
        await sync.flushPendingProgress(for: book)
    }

    private func pushLocator(bookID: UUID, locator: Locator) async {
        guard let book = currentBook() else { return }
        let intra = locator.locations.progression ?? 0
        let total = locator.locations.totalProgression ?? 0
        // Locator uses its own JSON coding (not Encodable); skip buffer if serialisation fails
        // rather than sending an empty/invalid JSON stub to the server.
        guard let json = locator.jsonString else { return }
        // Chapter index is 0 in v1 (best-effort); ProgressMapper handles this.
        env.sync?.bufferLocator(
            book: book, locatorJSON: json,
            chapter: 0, intraProgression: intra, percentage: total
        )
    }
}

// MARK: - DownloadingView

private struct DownloadingView: View {
    let book: Book
    let download: Download?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            if let download, download.state == .failed {
                VStack(spacing: 12) {
                    Text(download.error ?? "Download failed")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button("Retry") {
                        Task { _ = try? await env.downloads?.download(book: book) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 8) {
                    if let download, download.totalBytes > 0 {
                        ProgressView(value: Double(download.bytesReceived),
                                     total: Double(download.totalBytes))
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 32)

                        Text(progressLabel(download))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Diagnostic strip — temporary while we debug the "stuck on Preparing"
            // path. Shows the download row's actual state + the book row's fileURL
            // so we can tell whether the download genuinely hasn't started, has
            // finished but SwiftData isn't propagating fileURL, or never created
            // a Download row at all.
            VStack(alignment: .leading, spacing: 4) {
                Text("Debug").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text("download.state: \(download?.state.rawValue ?? "<no download row>")")
                Text("bytes: \(download?.bytesReceived ?? 0) / \(download?.totalBytes ?? 0)")
                Text("book.fileURL: \(book.fileURL?.absoluteString ?? "nil")")
                Text("book.id: \(book.id.uuidString.prefix(8))")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
            )
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private func progressLabel(_ download: Download) -> String {
        let received = ByteCountFormatter.string(fromByteCount: download.bytesReceived,
                                                  countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytes,
                                               countStyle: .file)
        return "\(received) of \(total)"
    }
}

// MARK: - ReaderHost

/// Wraps a Readium navigator in a UIViewControllerRepresentable.
/// Supports EPUB only in v1 (PDF/CBZ require an HTTPServer adapter not included
/// in the current dependency set).
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    var onLocatorChange: @Sendable (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onLocatorChange)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            do {
                let nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocator
                )
                nav.delegate = context.coordinator
                return nav
            } catch {
                return errorController("Failed to open EPUB: \(error.localizedDescription)")
            }
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    // MARK: Coordinator

    final class Coordinator: NSObject, EPUBNavigatorDelegate, @unchecked Sendable {
        let onChange: @Sendable (Locator) -> Void

        init(onChange: @escaping @Sendable (Locator) -> Void) {
            self.onChange = onChange
        }

        // NavigatorDelegate — fires on every location change including page turns.
        nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onChange(locator)
        }

        nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    }

    // MARK: Helpers

    private func errorController(_ message: String) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -24),
        ])
        return vc
    }
}
