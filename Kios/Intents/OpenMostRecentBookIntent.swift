import Foundation
import AppIntents
import SwiftData

/// Opens the book the user was most recently reading. Bindable to the
/// iPhone Action Button via the "Continue Reading" `AppShortcut`.
///
/// `openAppWhenRun: true` foregrounds Kios. The intent writes the target
/// book ID into `BookOpenCoordinator.shared`; `RootView` observes that
/// and routes through `ReaderRouter.openReader`.
struct OpenMostRecentBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Most Recent Book"
    static let description = IntentDescription(
        "Opens the book you were last reading.",
        categoryName: "Reading"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try ModelContainer.kios()
        let context = ModelContext(container)
        guard let book = MostRecentBookSelector.pick(in: context) else {
            throw OpenMostRecentBookError.noBook
        }
        BookOpenCoordinator.shared.request(book.id)
        return .result()
    }
}

enum OpenMostRecentBookError: Error, CustomLocalizedStringResourceConvertible {
    case noBook

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noBook: "No book to open yet."
        }
    }
}

struct KiosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMostRecentBookIntent(),
            phrases: [
                "Open my book in \(.applicationName)",
                "Continue reading in \(.applicationName)",
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book.fill"
        )
    }
}
