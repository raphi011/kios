import Foundation
import SwiftData
import Core

/// Downloads books from OPDS acquisition URLs into the app's books directory.
/// Uses a background URLSession configuration so downloads can survive app
/// suspension. SwiftData updates are bounced to @MainActor.
@MainActor
final class DownloadService: NSObject {
    private let context: ModelContext

    // `booksDirectory` is an immutable Sendable value, so delegate methods
    // (which run on the session's delegate queue, not @MainActor) can read
    // it directly without a Task bounce.
    nonisolated let booksDirectory: URL
    private var credentials: BasicCredentials

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "me.iosreader.downloads"
        )
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Maps URLSession task identifier → book UUID for routing delegate
    /// callbacks back to the right Download row / continuation.
    private var bookByTask: [Int: UUID] = [:]
    private var continuations: [UUID: CheckedContinuation<URL, Swift.Error>] = [:]

    init(context: ModelContext, booksDirectory: URL, credentials: BasicCredentials) {
        self.context = context
        self.booksDirectory = booksDirectory
        self.credentials = credentials
        super.init()
        try? FileManager.default.createDirectory(
            at: booksDirectory, withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// Begins downloading `book.acquisitionURL`. Returns the saved file URL.
    /// Throws if the download fails or the file move fails.
    func download(book: Book) async throws -> URL {
        let bookID = book.id
        let url = book.acquisitionURL
        return try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url)
            req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            let task = session.downloadTask(with: req)
            bookByTask[task.taskIdentifier] = bookID
            continuations[bookID] = cont
            upsertDownload(bookID: bookID, state: .running)
            task.resume()
        }
    }

    /// Updates the auth header used for subsequent download tasks. Existing
    /// in-flight tasks keep their original header (URLSession copies headers
    /// at task creation).
    func update(credentials new: BasicCredentials) {
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
            let hash = (try? DocumentHasher.partialMD5(of: dest)) ?? ""
            let descriptor = FetchDescriptor<Book>(
                predicate: #Predicate { $0.id == bookID }
            )
            if let book = try? context.fetch(descriptor).first {
                book.fileURL = dest
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
        let dest = Self.makeDestURL(in: booksDirectory, mime: mime)
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

    private nonisolated static func makeDestURL(in directory: URL, mime: String?) -> URL {
        let format = mime.flatMap(BookFormat.init(mimeType:)) ?? .epub
        return directory.appendingPathComponent(
            "\(UUID().uuidString).\(format.fileExtension)"
        )
    }
}
