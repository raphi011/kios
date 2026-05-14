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
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: FoundationModelsError(from: error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extract<T: Decodable & Sendable>(
        _ type: T.Type,
        schema: String,
        system: String,
        user: String
    ) async throws -> T {
        let session = LanguageModelSession(instructions: system)
        do {
            if type == ChapterCharactersResponse.self {
                let fm = try await session.respond(
                    to: user,
                    generating: FMChapterCharactersResponse.self
                ).content
                return ChapterCharactersResponse(fm) as! T
            }
            if type == ProfilesSynthesisResponse.self {
                let fm = try await session.respond(
                    to: user,
                    generating: FMProfilesSynthesisResponse.self
                ).content
                return ProfilesSynthesisResponse(fm) as! T
            }
            throw ExtractionError.unsupportedType(String(describing: type))
        } catch let error as LanguageModelSession.GenerationError {
            throw FoundationModelsError(from: error)
        }
    }
}

/// Translation layer over `LanguageModelSession.GenerationError` so the
/// summary sheet shows an actionable message instead of `error -1`.
@available(iOS 26, *)
struct FoundationModelsError: LocalizedError {
    let underlying: LanguageModelSession.GenerationError

    init(from error: LanguageModelSession.GenerationError) {
        self.underlying = error
    }

    var errorDescription: String? {
        switch underlying {
        case .assetsUnavailable:
            return "Apple Intelligence assets aren't ready on this device. Open the iOS Settings app, go to Apple Intelligence & Siri, and make sure it's turned on and finished downloading. Then try again."
        case .exceededContextWindowSize:
            return "This chapter is too long for the Built-in engine. Switch to the Bigger context (Gemma) engine in Settings, or try summarizing through what you've read so far instead of the full chapter."
        case .guardrailViolation:
            return "Apple Intelligence declined to summarize this passage. The on-device safety filter flagged the content. Try a different chapter or selection."
        case .rateLimited:
            return "Too many requests. Wait a moment and try again."
        case .concurrentRequests:
            return "Another summary is already running. Wait for it to finish, then try again."
        case .unsupportedLanguageOrLocale:
            return "This text is in a language Apple Intelligence doesn't yet support."
        case .unsupportedGuide:
            return "The summary couldn't be generated (unsupported guide). This is a bug — please report it."
        case .decodingFailure:
            return "The model returned a malformed response. Try again."
        case .refusal:
            return "Apple Intelligence declined to answer."
        @unknown default:
            return "The Built-in engine failed: \(underlying.localizedDescription)"
        }
    }
}
#endif
