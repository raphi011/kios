// Kios/Services/AI/FoundationModelsLanguageModel.swift
import Foundation
import Core

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
struct FoundationModelsLanguageModel: LanguageModel {
    let contextBudgetCharacters: Int = 12_000

    func complete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    // FoundationModels yields cumulative snapshots; convert to deltas
                    // so consumers can `partial += tok` (matches MockLanguageModel contract).
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: user) {
                        let cumulative = snapshot.content
                        if cumulative.hasPrefix(emitted) {
                            let delta = String(cumulative.dropFirst(emitted.count))
                            if !delta.isEmpty {
                                continuation.yield(delta)
                                emitted = cumulative
                            }
                        } else {
                            // Safety: model rewrote a prefix; emit the new cumulative as-is.
                            continuation.yield(cumulative)
                            emitted = cumulative
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
