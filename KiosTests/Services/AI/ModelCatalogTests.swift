// KiosTests/Services/AI/ModelCatalogTests.swift
import Testing
@testable import Kios

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test("gemma4_e4b asset has pinned revision and at least one file")
    func gemmaAssetPinned() {
        let asset = ModelCatalog.gemma4_e4b
        #expect(asset.id == "gemma-4-e4b-it-4bit")
        #expect(asset.engine == .gemma4_e4b)
        #expect(asset.huggingFaceRepo == "mlx-community/gemma-4-e4b-it-4bit")
        #expect(asset.revision.count == 40, "revision must be a full 40-char commit SHA")
        #expect(!asset.files.isEmpty, "files must be populated")
        let expectedTotal = asset.files.reduce(0) { $0 + $1.sizeBytes }
        #expect(asset.totalBytes == expectedTotal,
                "totalBytes must equal sum of file sizes; got \(asset.totalBytes) vs \(expectedTotal)")
        for file in asset.files {
            #expect(file.sha256.count == 64, "SHA-256 must be 64 hex chars; got \(file.sha256.count)")
            #expect(file.sha256.allSatisfy { $0.isHexDigit }, "non-hex char in SHA: \(file.sha256)")
            #expect(file.sizeBytes > 0, "size must be positive: \(file.path)")
        }
    }

    @Test("asset(for:) maps engines correctly")
    func assetFor() {
        #expect(ModelCatalog.asset(for: .gemma4_e4b)?.id == ModelCatalog.gemma4_e4b.id)
        #expect(ModelCatalog.asset(for: .foundationModels) == nil)
    }
}
