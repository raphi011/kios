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

    @State private var book: Book?
    @State private var publication: Publication?
    @State private var initialLocator: Locator?
    @State private var loadError: String?
    @State private var pendingPrompt: PromptInfo?

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: ProgressDownload
    }

    var body: some View {
        Group {
            if let book, let publication {
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
            } else if let loadError {
                Text(loadError).foregroundStyle(.orange)
            } else {
                ProgressView("Loading…")
            }
        }
        .task { await load() }
    }

    // MARK: - Private

    private func load() async {
        let id = bookID
        guard let fetched = try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first else {
            loadError = "Book not found"
            return
        }
        book = fetched

        guard let fileURL = fetched.fileURL else {
            loadError = "Book not downloaded"
            return
        }

        // Restore reading position from local progress (graceful: nil on any failure).
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            initialLocator = try? Locator(jsonString: progress.locatorJSON)
        }

        do {
            publication = try await openPublication(at: fileURL)
        } catch {
            loadError = "Failed to open: \(error.localizedDescription)"
        }
    }

    /// Opens a Publication from a local file URL using Readium 3.8's streamer.
    /// Uses CompositePublicationParser with EPUBParser only (v1 supports EPUB).
    private func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw OpenError.invalidFileURL
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

    private enum OpenError: Error {
        case invalidFileURL
        case asset(AssetRetrieveURLError)
        case publication(PublicationOpenError)
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

    private func pushLocator(bookID: UUID, locator: Locator) async {
        let id = bookID
        guard let book = try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        let intra = locator.locations.progression ?? 0
        let total = locator.locations.totalProgression ?? 0
        // Locator uses its own JSON coding (not Encodable); skip push if serialisation fails
        // rather than sending an empty/invalid JSON stub to the server.
        guard let json = locator.jsonString else { return }
        // Chapter index is 0 in v1 (best-effort); ProgressMapper handles this.
        await env.sync?.push(
            book: book, locatorJSON: json,
            chapter: 0, intraProgression: intra, percentage: total
        )
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
