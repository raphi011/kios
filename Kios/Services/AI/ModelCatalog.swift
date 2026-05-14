// Kios/Services/AI/ModelCatalog.swift
import Foundation

enum ModelCatalog {
    static let gemma3_4b: ModelAsset = ModelAsset(
        id: "gemma-3-4b-it-q4-mlx",
        displayName: "Gemma 3 4B (4-bit)",
        engine: .gemma3_4b,
        huggingFaceRepo: "mlx-community/gemma-3-4b-it-4bit",
        revision: "93724907d4ed1745d2fe50baadf3b0b01a65abf2",
        files: [
            AssetFile(path: "added_tokens.json",
                      sha256: "50b2f405ba56a26d4913fd772089992252d7f942123cc0a034d96424221ba946",
                      sizeBytes: 35),
            AssetFile(path: "chat_template.json",
                      sha256: "fe16baf728db49457cde32802cd7efc0ac8a7a9877dbe22fe3322b2d9dc6ccd9",
                      sizeBytes: 1615),
            AssetFile(path: "config.json",
                      sha256: "5ccdde91da736e6e6f8f138268c620adcbf1219c973b884240b719a54122465b",
                      sizeBytes: 1072),
            AssetFile(path: "generation_config.json",
                      sha256: "e04ecb65db447404710114fb282baaac482d22a95e2244ecaab428b81672ba78",
                      sizeBytes: 192),
            AssetFile(path: "model.safetensors",
                      sha256: "94d3d701367d78584a9334ca00672b1c86e4aefa6a94167556c0485381e74af3",
                      sizeBytes: 3_400_569_562),
            AssetFile(path: "model.safetensors.index.json",
                      sha256: "77f4b67de084c31c7bcd373b039908108eee6c6181607e6d53da730e5f0bc659",
                      sizeBytes: 90_558),
            AssetFile(path: "preprocessor_config.json",
                      sha256: "f688d6bb20c5017601c4011de7ca656da8485b540b05013efdaf986c0fcc918d",
                      sizeBytes: 570),
            AssetFile(path: "processor_config.json",
                      sha256: "3ffd5f11778dc73e2b69b3c00535e4121e1badf7018136263cd17b5b34fbaa53",
                      sizeBytes: 70),
            AssetFile(path: "special_tokens_map.json",
                      sha256: "2f7b0adf4fb469770bb1490e3e35df87b1dc578246c5e7e6fc76ecf33213a397",
                      sizeBytes: 662),
            AssetFile(path: "tokenizer.json",
                      sha256: "4667f2089529e8e7657cfb6d1c19910ae71ff5f28aa7ab2ff2763330affad795",
                      sizeBytes: 33_384_568),
            AssetFile(path: "tokenizer.model",
                      sha256: "1299c11d7cf632ef3b4e11937501358ada021bbdf7c47638d13c0ee982f2e79c",
                      sizeBytes: 4_689_074),
            AssetFile(path: "tokenizer_config.json",
                      sha256: "0d95398b39395e5cfb290683a78f3fb0551223c672d8b033333c1a5307473760",
                      sizeBytes: 1_157_007),
        ],
        totalBytes: 3_439_894_985
    )

    static func asset(for engine: AIEngine) -> ModelAsset? {
        switch engine {
        case .foundationModels: return nil
        case .gemma3_4b:        return gemma3_4b
        }
    }
}
