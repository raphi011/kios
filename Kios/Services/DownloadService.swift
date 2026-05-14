import Foundation
import SwiftData
import Core

/// Downloads books from OPDS acquisition URLs into the app's books directory.
/// Uses a background URLSession configuration so downloads can survive app
/// suspension. SwiftData updates are bounced to @MainActor.
@MainActor
final class DownloadService: NSObject {
    private let context: ModelContext

    private var credentials: BasicCredentials?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.raphi011.kios.downloads"
        )
        config.sessionSendsLaunchEvents = true
        // Belt-and-braces: when credentials are present, set auth in
        // httpAdditionalHeaders so downloads completed during a
        // background-relaunch (where the system re-creates the session and
        // replays events) carry the correct credential. httpAdditionalHeaders
        // is frozen at session-construction time, so this captures the
        // credentials that exist at the time of the first download(book:) call.
        // Per-task headers (set in download(book:)) also remain in place for
        // all foreground-initiated downloads.
        //
        // In Kobo mode `credentials` is nil — the catalog hands us pre-signed
        // CDN URLs whose signature would be rejected if we attached an
        // Authorization header, so we deliberately leave the header off. We
        // never recreate the URLSession when credentials flip between nil and
        // non-nil: constructing a background session with an identifier that
        // already exists in-process throws NSGenericException.
        if let credentials {
            config.httpAdditionalHeaders = [
                "Authorization": credentials.authorizationHeader
            ]
        }
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Maps URLSession task identifier → book UUID for routing delegate
    /// callbacks back to the right Download row / continuation.
    ///
    /// `Int` is URLSessionTask.taskIdentifier; reused per-process after a task
    /// completes. Safe here because we remove on finish/error before the next
    /// download could collide. Single-flight per book is enforced by caller.
    private var bookByTask: [Int: UUID] = [:]
    private var continuations: [UUID: CheckedContinuation<URL, Swift.Error>] = [:]

    init(context: ModelContext, credentials: BasicCredentials?) {
        self.context = context
        self.credentials = credentials
        super.init()
        // AppPaths.booksDirectory creates the directory on first access; touch
        // it now so subsequent moveItem calls don't race the mkdir.
        _ = AppPaths.booksDirectory
    }

    // MARK: - Public API

    /// Begins downloading `book.acquisitionURL`. Returns the saved file URL.
    /// Throws if the download fails or the file move fails.
    func download(book: Book) async throws -> URL {
        let bookID = book.id
        guard let url = book.acquisitionURL else {
            preconditionFailure(
                "DownloadService.download called for a book with no acquisitionURL "
                + "(source=\(book.source))"
            )
        }
        return try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url)
            // Kobo mode (credentials == nil) intentionally sends no
            // Authorization header — the URL is a pre-signed CDN link and any
            // header we attach invalidates the signature.
            if let credentials {
                req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            }
            let task = session.downloadTask(with: req)
            bookByTask[task.taskIdentifier] = bookID
            continuations[bookID] = cont
            upsertDownload(bookID: bookID, state: .running)
            task.resume()
        }
    }

    /// Updates the auth header used for download tasks created AFTER this call.
    ///
    /// In-flight tasks keep their original `Authorization` header. Background
    /// downloads completed during an app-relaunch use whatever credentials
    /// were in `httpAdditionalHeaders` when the session was first constructed
    /// (i.e., the credentials at the time of the first `download(book:)` call
    /// in this process). If the user changes credentials mid-flight, any
    /// already-running downloads continue with the old creds.
    ///
    /// Passing `nil` switches subsequent foreground downloads to send no
    /// Authorization header — used when the active sync protocol is Kobo,
    /// whose CDN URLs are pre-signed.
    func update(credentials new: BasicCredentials?) {
        self.credentials = new
    }

    // MARK: - Private @MainActor helpers

    private func upsertDownload(
        bookID: UUID,
        state: DownloadState,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        error: String? = nil
    ) {
        let descriptor = FetchDescriptor<Download>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.state = state
            existing.bytesReceived = bytesReceived
            existing.totalBytes = totalBytes
            existing.error = error
        } else {
            context.insert(Download(
                bookID: bookID,
                state: state,
                bytesReceived: bytesReceived,
                totalBytes: totalBytes,
                error: error
            ))
        }
        try? context.save()
    }

    /// Called from the delegate (via Task) after the file move has already
    /// happened synchronously on the delegate queue.
    private func applyFinish(taskID: Int, moveResult: Result<URL, Swift.Error>) {
        guard let bookID = bookByTask.removeValue(forKey: taskID) else { return }
        let cont = continuations.removeValue(forKey: bookID)
        switch moveResult {
        case .success(let dest):
            // nil hash means the file is present but kosync sync will be skipped
            // (SyncService.onOpen guards on partialMD5 != nil). Better than ""
            // which is non-nil but invalid as a kosync document identifier.
            let hash = try? DocumentHasher.partialMD5(of: dest)
            let descriptor = FetchDescriptor<Book>(
                predicate: #Predicate { $0.id == bookID }
            )
            if let book = try? context.fetch(descriptor).first {
                // Persist only the filename — `AppPaths.booksDirectory` resolves
                // it to an absolute URL on each read, immune to container-UUID
                // changes across reinstalls/redeploys.
                book.filename = dest.lastPathComponent
                book.partialMD5 = hash
            }
            upsertDownload(bookID: bookID, state: .completed)
            try? context.save()
            cont?.resume(returning: dest)
        case .failure(let error):
            upsertDownload(bookID: bookID, state: .failed, error: error.localizedDescription)
            cont?.resume(throwing: error)
        }
    }

    private func applyError(taskID: Int, error: Swift.Error) {
        guard let bookID = bookByTask.removeValue(forKey: taskID) else { return }
        upsertDownload(bookID: bookID, state: .failed, error: error.localizedDescription)
        continuations.removeValue(forKey: bookID)?.resume(throwing: error)
    }

    private func applyProgress(taskID: Int, written: Int64, expected: Int64) {
        guard let bookID = bookByTask[taskID] else { return }
        upsertDownload(
            bookID: bookID, state: .running,
            bytesReceived: written, totalBytes: expected
        )
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadService: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // IMPORTANT: The temp file at `location` is deleted when this method
        // returns. The move MUST happen synchronously here, on the delegate
        // queue, before we bounce anything to @MainActor.
        let mime = (downloadTask.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")
        let dest = Self.makeDestURL(mime: mime)
        let moveResult = Result<URL, Swift.Error> {
            try FileManager.default.moveItem(at: location, to: dest)
            return dest
        }
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            self.applyFinish(taskID: taskID, moveResult: moveResult)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Swift.Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            self.applyError(taskID: taskID, error: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            self.applyProgress(
                taskID: taskID,
                written: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    // MARK: - Helpers

    private nonisolated static func makeDestURL(mime: String?) -> URL {
        let format = mime.flatMap(BookFormat.init(mimeType:)) ?? .epub
        return AppPaths.booksDirectory.appendingPathComponent(
            "\(UUID().uuidString).\(format.fileExtension)"
        )
    }
}
