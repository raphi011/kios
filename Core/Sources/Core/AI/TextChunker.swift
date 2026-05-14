import Foundation

public struct TextChunker: Sendable {
    public let budgetCharacters: Int
    public let overlapCharacters: Int

    public init(budgetCharacters: Int, overlapCharacters: Int = 200) {
        precondition(budgetCharacters > 0, "budget must be positive")
        precondition(overlapCharacters >= 0 && overlapCharacters < budgetCharacters,
                     "overlap must be non-negative and < budget")
        self.budgetCharacters = budgetCharacters
        self.overlapCharacters = overlapCharacters
    }

    public func chunks(of text: String) -> [String] {
        guard text.count > budgetCharacters else { return [text] }

        var result: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let remaining = text.distance(from: cursor, to: text.endIndex)
            if remaining <= budgetCharacters {
                result.append(String(text[cursor...]))
                break
            }

            let windowEnd = text.index(cursor, offsetBy: budgetCharacters)
            let cutIndex = bestBoundary(in: text, from: cursor, to: windowEnd) ?? windowEnd

            let chunk = String(text[cursor..<cutIndex])
            result.append(chunk)

            let overlapBack = min(overlapCharacters, text.distance(from: cursor, to: cutIndex) - 1)
            cursor = text.index(cutIndex, offsetBy: -overlapBack)
            if cursor <= result.last.flatMap({ text.range(of: $0)?.lowerBound }) ?? text.startIndex {
                cursor = cutIndex
            }
        }
        return result
    }

    private func bestBoundary(in text: String, from: String.Index, to: String.Index) -> String.Index? {
        let slice = text[from..<to]
        if let r = slice.range(of: "\n\n", options: .backwards) {
            return r.upperBound
        }
        if let r = slice.range(of: ". ", options: .backwards) {
            return text.index(r.upperBound, offsetBy: 0)
        }
        if let r = slice.range(of: "\n", options: .backwards) {
            return r.upperBound
        }
        return nil
    }
}
