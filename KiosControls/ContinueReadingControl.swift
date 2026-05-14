import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Action Button "Control" that opens the most recent book.
/// Mirrors `KiosShortcuts`' AppShortcut surface, but for the iOS 18 Controls
/// gallery. `OpenMostRecentBookIntent.openAppWhenRun` is `true`, so the tap
/// foregrounds Kios and `perform()` runs in the app process — the extension
/// only carries the intent's metadata.
struct ContinueReadingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.raphi011.kios.Controls.ContinueReading"
        ) {
            ControlWidgetButton(action: OpenMostRecentBookIntent()) {
                Label("Continue Reading", systemImage: "book.fill")
            }
        }
        .displayName("Continue Reading")
        .description("Opens the book you were last reading.")
    }
}
