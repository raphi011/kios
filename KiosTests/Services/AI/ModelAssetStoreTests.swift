// KiosTests/Services/AI/ModelAssetStoreTests.swift
import Testing
@testable import Kios
import Foundation

@Suite("ModelAssetStore")
struct ModelAssetStoreTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kios-mas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAsset(files: [(String, Data)]) -> ModelAsset {
        let assetFiles: [AssetFile] = files.map { name, data in
            let sha = Self.sha256(of: data)
            return AssetFile(path: name, sha256: sha, sizeBytes: Int64(data.count))
        }
        return ModelAsset(
            id: "test-asset",
            displayName: "Test",
            engine: .gemma3_4b,
            huggingFaceRepo: "test/test",
            revision: String(repeating: "a", count: 40),
            files: assetFiles,
            totalBytes: assetFiles.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    private static func sha256(of data: Data) -> String {
        // Use the same helper as the production code so test+impl stay consistent.
        return ModelAssetStore.sha256Hex(of: data)
    }

    @Test("notInstalled when no files exist")
    func notInstalled() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let asset = makeAsset(files: [("a.txt", Data("hello".utf8))])
        #expect(store.installationStatus(for: asset) == .notInstalled)
    }

    @Test("installed when all files match SHA")
    func installedGood() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let data = Data("hello world".utf8)
        let asset = makeAsset(files: [("model.bin", data)])
        let dir = store.directory(for: asset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("model.bin"))
        if case .installed = store.installationStatus(for: asset) {
            // ok
        } else {
            Issue.record("expected .installed; got \(store.installationStatus(for: asset))")
        }
        let ok = try await store.verifyIntegrity(of: asset)
        #expect(ok)
    }

    @Test("corrupt when file content changed")
    func corruptContent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let asset = makeAsset(files: [("model.bin", Data("expected".utf8))])
        let dir = store.directory(for: asset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("WRONG_CONTENT_SAME_LENGTH".utf8).prefix(8).write(to: dir.appendingPathComponent("model.bin"))
        let ok = try await store.verifyIntegrity(of: asset)
        #expect(!ok)
    }

    @Test("partial when some files missing")
    func partial() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let asset = makeAsset(files: [
            ("a.bin", Data("a".utf8)),
            ("b.bin", Data("bb".utf8)),
        ])
        let dir = store.directory(for: asset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.bin"))
        if case .partial = store.installationStatus(for: asset) { /* ok */ } else {
            Issue.record("expected .partial; got \(store.installationStatus(for: asset))")
        }
    }

    @Test("delete removes asset directory")
    func delete() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelAssetStore(rootDirectory: root)
        let asset = makeAsset(files: [("a.bin", Data("a".utf8))])
        let dir = store.directory(for: asset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try store.delete(asset)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
