// Kios/Views/Reader/AskAboutSelectionSheet.swift
import SwiftUI

struct AskAboutSelectionSheet: View {
    let selection: String
    let bookID: UUID
    let bookTitle: String
    let chapterTitle: String?
    let engine: AIEngine
    let onClose: () -> Void

    @State private var question: String = ""
    @State private var showFullSelection: Bool = false
    @FocusState private var questionFocused: Bool
    @Bindable var service: AISummaryService

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        selectionPreview
                        questionField
                        answerArea
                    }
                    .padding()
                }
                Divider()
                Text(footerAttribution)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .onAppear { questionFocused = true }
        }
    }

    private var selectionPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From the passage:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(selection)
                .font(.body)
                .lineLimit(showFullSelection ? nil : 4)
            if selection.count > 200 {
                Button(showFullSelection ? "Show less" : "Show full") {
                    showFullSelection.toggle()
                }
                .font(.footnote)
            }
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your question:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("e.g. What does this paragraph mean?", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .submitLabel(.send)
                .onSubmit(ask)
            HStack {
                Spacer()
                Button(action: ask) { Label("Ask", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder private var answerArea: some View {
        switch service.questionState {
        case .idle:
            EmptyView()
        case .streaming(let s), .done(let s):
            Text(s).textSelection(.enabled)
        case .failed(let err):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't answer: \(err.localizedDescription)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again", action: ask)
            }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            await service.askAboutSelection(
                selection: selection, question: q,
                bookID: bookID, bookTitle: bookTitle,
                chapterTitle: chapterTitle, engine: engine
            )
        }
    }

    private var footerAttribution: String {
        switch engine {
        case .foundationModels: return "Generated with Apple Intelligence"
        case .gemma3_4b:        return "Generated with Gemma 3 4B (on-device)"
        }
    }
}
