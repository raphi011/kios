// Kios/Services/AI/ModelCatalog.swift
import Foundation

enum ModelCatalog {
    /// Google's Gemma 4 E4B (instruct-tuned, 4-bit MLX quantization).
    /// Multimodal weights — vision and audio towers are bundled but unused
    /// here; mlx-community has not yet published a text-only conversion the
    /// way they did for Gemma 3n's `-lm-` variant. 128 K-token context, ~5.2 GB
    /// on-disk. KV-cache memory (not the model card's context claim) is what
    /// actually limits usable prompt size on iPhone; `MLXGemmaLanguageModel`
    /// pairs this with 4-bit KV-cache quantization to keep the cache footprint
    /// roughly 4× smaller than the fp16 default.
    static let gemma4_e4b: ModelAsset = ModelAsset(
        id: "gemma-4-e4b-it-4bit",
        displayName: "Gemma 4 E4B (4-bit)",
        engine: .gemma4_e4b,
        huggingFaceRepo: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "cc3b666c01c20395e0dcebd53854504c7d9821f9",
        files: [
            AssetFile(path: "chat_template.jinja",
                      sha256: "781d10940fbc44be40064b5d43a056fc486c84ceaa55538226368b57314132bf",
                      sizeBytes: 16_317),
            AssetFile(path: "config.json",
                      sha256: "18521c2237729a659a3b821eeb706f088e46518d8698f8e357df7bf7300e7041",
                      sizeBytes: 6_229),
            AssetFile(path: "generation_config.json",
                      sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de",
                      sizeBytes: 208),
            AssetFile(path: "model.safetensors",
                      sha256: "339409bd18494955556e1fde6ccc15faaa9f707b911b74791fe290b9d722beed",
                      sizeBytes: 5_217_361_182),
            AssetFile(path: "model.safetensors.index.json",
                      sha256: "50c54ba1baf793652f8f85fb61cf9bedfafdc2ea7b59f80cf56611c9912fccd0",
                      sizeBytes: 251_749),
            AssetFile(path: "processor_config.json",
                      sha256: "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8",
                      sizeBytes: 902),
            AssetFile(path: "tokenizer.json",
                      sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f",
                      sizeBytes: 32_169_626),
            AssetFile(path: "tokenizer_config.json",
                      sha256: "90c3a3ba5bf53818383a58e1a776cbcacd2a038d4812eaa373e1522f2d06f3df",
                      sizeBytes: 2_095),
        ],
        totalBytes: 5_249_808_308
    )

    static func asset(for engine: AIEngine) -> ModelAsset? {
        switch engine {
        case .foundationModels: return nil
        case .gemma4_e4b:       return gemma4_e4b
        }
    }

    /// IDs of every on-disk asset the catalog currently knows about. Used
    /// by `ModelAssetStore.cleanupOrphanDirectories(...)` at launch so an
    /// asset rename (or removal) auto-evicts the prior directory — e.g.
    /// the previous `gemma-3n-e4b-it-lm-4bit` directory disappears on
    /// next launch after this catalog update.
    static var allKnownAssetIDs: Set<String> {
        Set(AIEngine.allCases.compactMap { asset(for: $0)?.id })
    }
}
