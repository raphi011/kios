import UIKit
import ReadiumShared
import ReadiumNavigator

/// UIKit container that hosts `EPUBNavigatorViewController` as a child VC
/// and owns the input layer (taps, pinch, hardware keys, status-bar control).
@MainActor
final class ReaderContainerVC: UIViewController {

    // MARK: - Callbacks

    var onLocatorChange: ((Locator) -> Void)?
    var onCenterTap: (() -> Void)?
    /// Fires when `DirectionalNavigationAdapter` triggers a page turn (edge
    /// tap or arrow key). Hooked by SwiftUI to auto-hide the chrome so
    /// turning a page never leaves stale chrome lingering on screen.
    var onPageTurn: (() -> Void)?
    var onPinchUpdate: ((Int?) -> Void)?
    /// Live brightness percent while the left-edge pan is active; `nil` on
    /// release so SwiftUI can fade the HUD.
    var onBrightnessUpdate: ((Int?) -> Void)?
    var onDismissRequested: (() -> Void)?
    /// Fires when the user picks "Ask AI" from the text-selection edit menu.
    /// The string is `selection.locator.text.highlight` from the navigator,
    /// captured at tap time. SwiftUI presents the Ask sheet in response.
    var onAskAIRequested: ((String) -> Void)?

    // MARK: - Inputs (set via update())

    private(set) var fontSizePct: Int = 100

    // MARK: - Internals

    private let publication: Publication
    private let initialLocator: Locator?
    /// When true, the "Ask AI" custom editing action is added to the navigator
    /// config so the system edit menu surfaces it on text selection. Gated by
    /// the SwiftUI host via resolved AI availability — when AI is off / no
    /// engine is usable, the action is omitted entirely so it never appears.
    private let canAskAI: Bool
    private var navigator: EPUBNavigatorViewController?
    private var inputHandlers: ReaderInputHandlers?
    /// Retained so its `.tap` / `.click` / `.key` observer closures stay alive.
    /// Readium 3.9 made the adapter's observer closures capture `self` weakly
    /// (PR #757), so dropping the instance after `bind(to:)` deinits the
    /// adapter and auto-unbinds — silently breaking edge-tap page turns.
    private var directionalNavigationAdapter: DirectionalNavigationAdapter?
    /// `Locator.jsonString` of the most recently applied jump. Used to dedupe
    /// repeated `applyPendingJump` calls from SwiftUI re-renders so we don't
    /// replay the same navigation on every `updateUIViewController` pass.
    private var lastAppliedJumpJSON: String?
    /// Largest safe-area insets observed during the reader's lifetime.
    /// Returned by `navigatorContentInset` so the EPUB doesn't reflow when
    /// the chrome shows/hides the status bar.
    private var maxObservedInsets: UIEdgeInsets = .zero

    init(publication: Publication, initialLocator: Locator?, canAskAI: Bool) {
        self.publication = publication
        self.initialLocator = initialLocator
        self.canAskAI = canAskAI
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installNavigator()
        installInputObservers()
        installInputHandlers()
    }

    /// Always hidden — the reader is fully immersive. Showing/hiding the
    /// status bar would change `view.safeAreaInsets.top`, which would resize
    /// the navigator and reflow the EPUB columns every time chrome toggles.
    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Updates from SwiftUI

    /// Called from `ReaderHost.updateUIViewController` whenever SwiftUI re-renders.
    func update(fontSizePct: Int) {
        if self.fontSizePct != fontSizePct {
            self.fontSizePct = fontSizePct
            applyFontSize()
        }
    }

    /// Navigates to `locator` if it differs from the last jump applied. Pass
    /// `nil` to clear the deduper (no navigation occurs). Idempotent across
    /// SwiftUI's repeated `updateUIViewController` invocations.
    func applyPendingJump(_ locator: Locator?) {
        guard let locator,
              let json = try? locator.jsonString(),
              json != lastAppliedJumpJSON
        else { return }
        lastAppliedJumpJSON = json
        let nav = navigator
        Task { @MainActor in
            _ = await nav?.go(to: locator, options: NavigatorGoOptions(animated: false))
        }
    }

    // MARK: - Navigator setup

    private func installNavigator() {
        let prefs = EPUBPreferences(fontSize: Double(fontSizePct) / 100.0)
        // Append the custom "Ask AI" action only when AI is available — the
        // edit menu should not advertise a feature that's gated off. Readium's
        // `EditingActionsController` consults the responder chain for the
        // selector, so `askAITapped(_:)` lives on this VC below.
        var actions = EditingAction.defaultActions
        if canAskAI {
            actions.append(EditingAction(title: "Ask AI", action: #selector(askAITapped(_:))))
        }
        let config = EPUBNavigatorViewController.Configuration(
            preferences: prefs,
            editingActions: actions
        )
        do {
            let nav = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocator,
                config: config
            )
            nav.delegate = self
            addChild(nav)
            nav.view.frame = view.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(nav.view)
            nav.didMove(toParent: self)
            self.navigator = nav
        } catch {
            installErrorLabel("Failed to open EPUB: \(error.localizedDescription)")
        }
    }

    private func installErrorLabel(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Input observers (taps, arrow keys)

    /// Wires Readium's canonical input layer:
    /// - `DirectionalNavigationAdapter` handles edge-tap page turns AND
    ///   arrow-key navigation. Bound *first* so its observers see events
    ///   before ours.
    /// - `.activate` observer handles center taps (chrome toggle). Fires
    ///   only when the adapter returned `false` (tap wasn't on an edge).
    /// - `.key(.escape)` dismisses the reader.
    private func installInputObservers() {
        guard let nav = navigator else { return }

        let dna = DirectionalNavigationAdapter(
            pointerPolicy: .init(types: [.mouse, .touch]),
            onNavigation: { [weak self] in self?.onPageTurn?() }
        )
        dna.bind(to: nav)
        directionalNavigationAdapter = dna

        nav.addObserver(.activate { [weak self] _ in
            self?.onCenterTap?()
            return true
        })

        nav.addObserver(.key(.escape) { [weak self] in
            self?.onDismissRequested?()
            return true
        })
    }

    // MARK: - Pinch (font size)

    private func installInputHandlers() {
        let handlers = ReaderInputHandlers(currentFontSizePct: { [weak self] in
            self?.fontSizePct ?? 100
        })
        handlers.onPinchUpdate = { [weak self] pct in self?.onPinchUpdate?(pct) }
        handlers.onBrightnessUpdate = { [weak self] pct in self?.onBrightnessUpdate?(pct) }
        handlers.onPinchCommit = { [weak self] pct in
            // The container is the only place that owns the navigator handle.
            // Apply the preferences here; SwiftUI also writes @AppStorage,
            // which round-trips back via `update(fontSizePct:)` — that path
            // is a no-op because `fontSizePct` will already equal `pct`.
            self?.fontSizePct = pct
            self?.applyFontSize()
            self?.onPinchUpdate?(nil)  // dismiss HUD
            self?.onPinchCommitToSwiftUI?(pct)
        }
        handlers.attach(to: view)
        self.inputHandlers = handlers
    }

    /// Bridges pinch commit out to SwiftUI so it can persist via @AppStorage.
    var onPinchCommitToSwiftUI: ((Int) -> Void)?

    // MARK: - Font size

    private func applyFontSize() {
        guard let nav = navigator else { return }
        let prefs = EPUBPreferences(fontSize: Double(fontSizePct) / 100.0)
        nav.submitPreferences(prefs)
    }

    // MARK: - Ask AI edit-menu action

    /// Invoked by the UIKit responder chain when the user picks "Ask AI" from
    /// the text-selection edit menu. Readium routes the selector to the
    /// `EditingAction(title:action:)` registered in the navigator config.
    /// Reads the live selection from `navigator.currentSelection` (the
    /// `EditingActionsController` keeps this in sync with the WKWebView) and
    /// hands the highlighted text up to SwiftUI via `onAskAIRequested`.
    @objc func askAITapped(_ sender: Any?) {
        guard let nav = navigator,
              let selection = nav.currentSelection,
              let text = selection.locator.text.highlight,
              !text.isEmpty
        else { return }
        onAskAIRequested?(text)
    }
}

// MARK: - EPUBNavigatorDelegate

extension ReaderContainerVC: EPUBNavigatorDelegate {
    nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let enriched = await self.enrichWithVisibleSelector(locator)
            self.onLocatorChange?(enriched)
        }
    }

    nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

    /// Returns insets that already include the safe area, frozen at the
    /// largest values observed during the reader's lifetime. The default
    /// (returning `nil`) makes Readium track `view.safeAreaInsets`, which
    /// shrinks when the status bar is hidden — reflowing the EPUB content
    /// every time the chrome toggles. Locking in the maximum keeps the
    /// reading position stable across status-bar visibility changes.
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let current = view.safeAreaInsets
        maxObservedInsets = UIEdgeInsets(
            top: max(maxObservedInsets.top, current.top),
            left: max(maxObservedInsets.left, current.left),
            bottom: max(maxObservedInsets.bottom, current.bottom),
            right: max(maxObservedInsets.right, current.right)
        )
        return maxObservedInsets
    }

    /// Ask Readium for the cssSelector of the first visible block element on
    /// the current page. When that element is a koboSpan, the selector is
    /// `#kobo\.X\.Y` — exact koboSpan id, no interpolation. Merge it into the
    /// page-turn locator so `SyncService.augmentLocatorWithSpanID` skips the
    /// resolver and pushes the exact id.
    ///
    /// Returns the original locator unchanged when the visible element isn't
    /// a koboSpan (e.g. plain EPUBs, or a `<p>` without a koboSpan wrapping).
    /// In that case the existing `KEPUBSpanResolver` runs as fallback and
    /// picks via linear interpolation, same as today.
    @MainActor
    private func enrichWithVisibleSelector(_ locator: Locator) async -> Locator {
        guard let nav = navigator,
              let visible = await nav.firstVisibleElementLocator(),
              let selector = visible.locations["cssSelector"]?.string,
              selector.hasPrefix("#kobo") else {
            return locator
        }
        return locator.copy(locations: { locations in
            locations.otherLocations["cssSelector"] = .string(selector)
        })
    }
}
