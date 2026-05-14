// KiosTests/Services/AI/ModelDownloadServiceTests.swift
import Testing
@testable import Kios
import Foundation

@Suite("ModelDownloadService")
struct ModelDownloadServiceTests {
    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let responder = Self.responder else { client?.urlProtocolDidFinishLoading(self); return }
            let (resp, data, err) = responder(request)
            if let err = err {
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data = data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class CallFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool = false
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func set() {
            lock.lock(); defer { lock.unlock() }
            _value = true
        }
    }

    private func makeAsset(files: [(name: String, content: Data)]) -> ModelAsset {
        let assetFiles = files.map { f in
            AssetFile(path: f.name, sha256: ModelAssetStore.sha256Hex(of: f.content), sizeBytes: Int64(f.content.count))
        }
        return ModelAsset(
            id: "dl-test",
            displayName: "DL Test",
            engine: .gemma3_4b,
            huggingFaceRepo: "test/test",
            revision: String(repeating: "a", count: 40),
            files: assetFiles,
            totalBytes: assetFiles.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kios-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("happy path: download writes all files and reports installed")
    @MainActor
    func happyPath() async throws {
        let files = [
            (name: "config.json", content: Data("{\"x\":1}".utf8)),
            (name: "model.bin", content: Data("BINARY".utf8)),
        ]
        let asset = makeAsset(files: files)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)

        let map: [String: Data] = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.content) })
        MockURLProtocol.responder = { req in
            let name = req.url!.lastPathComponent
            let data = map[name]!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(data.count)])!
            return (resp, data, nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = ModelDownloadService(assetStore: store, configuration: config)

        await service.startDownload(of: asset, allowCellular: false)
        if case .installed = store.installationStatus(for: asset) { /* ok */ } else {
            Issue.record("expected .installed after download; got \(store.installationStatus(for: asset))")
        }
        #expect(service.lastError == nil)
    }

    @Test("SHA mismatch surfaces integrityCheckFailed")
    @MainActor
    func shaMismatch() async throws {
        let asset = makeAsset(files: [(name: "x.bin", content: Data("expected".utf8))])
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        MockURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("CORRUPTED!!".utf8), nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = ModelDownloadService(assetStore: store, configuration: config)

        await service.startDownload(of: asset, allowCellular: false)
        if case .integrityCheckFailed = service.lastError { /* ok */ } else {
            Issue.record("expected integrityCheckFailed; got \(String(describing: service.lastError))")
        }
    }

    @Test("not enough storage reports notEnoughStorage without making network calls")
    @MainActor
    func notEnoughStorage() async throws {
        let asset = ModelAsset(
            id: "huge", displayName: "Huge", engine: .gemma3_4b,
            huggingFaceRepo: "t/t", revision: String(repeating: "a", count: 40),
            files: [AssetFile(path: "f", sha256: String(repeating: "0", count: 64), sizeBytes: Int64.max - 1)],
            totalBytes: Int64.max - 1
        )
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let responderCalled = CallFlag()
        MockURLProtocol.responder = { req in
            responderCalled.set()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(), nil)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = ModelDownloadService(assetStore: store, configuration: config)
        await service.startDownload(of: asset, allowCellular: false)
        #expect(!responderCalled.value, "must not network if storage check fails")
        if case .notEnoughStorage = service.lastError { /* ok */ } else {
            Issue.record("expected notEnoughStorage; got \(String(describing: service.lastError))")
        }
    }
}
