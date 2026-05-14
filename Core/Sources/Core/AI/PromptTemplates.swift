import Foundation

public enum PromptTemplates {

    public static func chapterSummary(
        chapterTitle: String,
        bookTitle: String,
        body: String,
        scope: SummaryScope
    ) -> (system: String, user: String) {
        let scopeNote: String
        switch scope {
        case .readSoFar:
            scopeNote = "The reader has only read up to a certain point in this chapter. Summarize only what is in the provided passage. Do NOT speculate about what happens later."
        case .full:
            scopeNote = "Summarize the full chapter."
        }
        let system = """
        You are a careful book-summarization assistant. Given a chapter passage, produce a clear, concise summary. \(scopeNote) Use the passage as the sole source of truth. Do not invent details. Aim for 3 to 6 short paragraphs.
        """
        let user = """
        Book: "\(bookTitle)"
        Chapter: "\(chapterTitle)"

        Passage:
        \(body)
        """
        return (system, user)
    }

    public static func mapStep(chunk: String, chapterTitle: String) -> (system: String, user: String) {
        let system = """
        You are a careful book-summarization assistant. You are summarizing one part of a longer chapter; produce a faithful, detail-preserving summary of THIS part only. Keep proper names and concrete details. 2 to 4 short paragraphs.
        """
        let user = """
        Chapter: "\(chapterTitle)"

        Part to summarize:
        \(chunk)
        """
        return (system, user)
    }

    public static func reduceStep(partials: [String], chapterTitle: String) -> (system: String, user: String) {
        let system = """
        You are a careful book-summarization assistant. You will receive several partial summaries from consecutive parts of one chapter. Combine them into a single coherent chapter summary. Preserve the chronological order. Do not invent details that are not in the partials. Aim for 3 to 6 short paragraphs.
        """
        let joined = partials.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        let user = """
        Chapter: "\(chapterTitle)"

        Partial summaries:
        \(joined)
        """
        return (system, user)
    }

    public static func selectionQuestion(
        selection: String,
        question: String,
        bookTitle: String,
        chapterTitle: String?
    ) -> (system: String, user: String) {
        let system = """
        You are a careful reading assistant. Answer the reader's question using ONLY the passage they have selected. If the answer is not present in the passage, say so plainly and do not guess. Keep the answer short — typically 1 to 3 short paragraphs.
        """
        let chapterLine = chapterTitle.map { "Chapter: \"\($0)\"\n" } ?? ""
        let user = """
        Book: "\(bookTitle)"
        \(chapterLine)
        Passage:
        \(selection)

        Question:
        \(question)
        """
        return (system, user)
    }
}
