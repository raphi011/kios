// Kios/Views/Reader/ChapterSummarySheet.swift
import SwiftUI
import Core

struct ChapterSummarySheet: View {
    let bookID: UUID
    let chapterHref: String
    let chapterTitle: String
    let cutoff: Double?
    let engine: AIEngine
    let onClose: () -> Void

    @State private var scope: SummaryScope = .readSoFar
    @State private var hasStartedFirstRun: Bool = false
    @Bindable var service: AISummaryService

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Scope", selection: $scope) {
                    Text("Through what you've read").tag(SummaryScope.readSoFar)
                    Text("Full chapter").tag(SummaryScope.full)
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let p = service.progress {
                            Text("Summarizing… \(p.done) of \(p.total) sections")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        switch service.summaryState {
                        case .idle:
                            if hasStartedFirstRun {
                                preparingIndicator
                            } else {
                                Text("Tap Summarize to begin.")
                                    .foregroundStyle(.secondary)
                            }
                        case .streaming(let s):
                            if s.isEmpty {
                                preparingIndicator
                            } else {
                                Text(s).textSelection(.enabled)
                            }
                        case .done(let s):
                            Text(s).textSelection(.enabled)
                        case .failed(let err):
                            errorCard(err)
                        }
                    }
                    .padding()
                }

                Divider()

                HStack {
                    Text(footerAttribution)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: regenerate) {
                        Label("Summarize", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle(chapterTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .task(id: scope) { await runSummary() }
        }
    }

    private func runSummary() async {
        hasStartedFirstRun = true
        await service.summarizeCurrentChapter(
            bookID: bookID,
            chapterHref: chapterHref,
            chapterTitle: chapterTitle,
            cutoff: scope == .readSoFar ? cutoff : nil,
            scope: scope,
            engine: engine
        )
    }

    private var preparingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Preparing summary…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func regenerate() {
        Task { await runSummary() }
    }

    private func errorCard(_ err: any Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Summary failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err.localizedDescription)
                .font(.footnote)
            Button("Try again", action: regenerate).buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var footerAttribution: String {
        switch engine {
        case .foundationModels: return "Generated with Apple Intelligence"
        case .gemma4_e4b:       return "Generated with Gemma 4 E4B (on-device)"
        }
    }
}
