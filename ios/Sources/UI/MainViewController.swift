import Combine
import PedalsKit
import UIKit

/// Safari-style main screen: floating glass tab strip on top, the active
/// terminal filling the screen beneath it, and a persistent glass input
/// toolbar at the bottom that rides above the keyboard. Terminals can live on
/// different computers; every computer's full session list is shown as tabs.
/// Horizontal pans page between terminals, with the tab strip following.
@MainActor
final class MainViewController: UIViewController {
    private let services: AppServices
    private var manager: TerminalManager { services.terminals }

    /// One page per terminal: the Ghostty host plus its freeze/loading mask,
    /// wrapped in a container that the pan gesture slides around.
    @MainActor
    private final class Page {
        let host: TerminalHost
        let container = UIView()
        let overlay = TerminalStatusOverlay()

        init(host: TerminalHost) {
            self.host = host
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.frame = container.bounds
            container.addSubview(host.view)
            overlay.translatesAutoresizingMaskIntoConstraints = true
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.frame = container.bounds
            container.addSubview(overlay)
        }
    }

    private let pagesContainer = UIView()
    private var pages: [TerminalID: Page] = [:]
    private var orderedIds: [TerminalID] = []
    private var visibleId: TerminalID?

    private let tabStrip = TabStripView()
    private let toolbar = TerminalToolbar()

    private let unpairedView = UnpairedStateView()
    private let noSessionsView = UIView()
    private weak var noSessionsCreateButton: UIButton?

    /// Bound computer count, taken from the `$computers` EMISSION — never read
    /// `manager.computers` inside a sink (@Published emits during willSet, so
    /// the property still holds the old value there).
    private var computerCount = 0

    private var panGesture: UIPanGestureRecognizer!
    /// In-flight pan: target index we are dragging toward.
    private var panTarget: Int?
    /// True between the first `.changed` and the end of a pan. While set,
    /// `apply()` defers page-visibility reconciliation so a `sessions`
    /// rebroadcast (title/cwd poll) can't hide the page under the finger.
    private var isPanning = false
    private var deferredApply = false

    private var cancellables: Set<AnyCancellable> = []

    init(services: AppServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PedalsTheme.uiCanvas
        buildLayout()
        bind()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func buildLayout() {
        // Content: full-bleed from the very top (scrolls under the tab strip)
        // down to the toolbar, so the grid never hides behind the keyboard bar.
        pagesContainer.clipsToBounds = true
        pagesContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagesContainer)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onBytes = { [weak self] bytes in
            guard let self, let id = visibleId else { return }
            manager.sendStdin(id, data: bytes)
        }
        toolbar.onStickyCtrl = { [weak self] armed in
            guard let self, let id = visibleId else { return }
            pages[id]?.host.stickyCtrl = armed
        }
        view.addSubview(toolbar)

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] id in self?.manager.activate(id) }
        tabStrip.onClose = { [weak self] id in self?.manager.closeTerminal(id) }
        tabStrip.onSettings = { [weak self] in self?.presentSettings() }
        tabStrip.onCreate = { [weak self] in self?.createOnOnlyComputer() }
        view.addSubview(tabStrip)

        noSessionsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noSessionsView)
        buildNoSessionsHint()

        unpairedView.translatesAutoresizingMaskIntoConstraints = false
        unpairedView.onEnterCode = { [weak self] in self?.presentPairingCode() }
        view.addSubview(unpairedView)

        NSLayoutConstraint.activate([
            // libghostty has no asymmetric content inset, so the grid sits
            // strictly between the tab strip and the toolbar — nothing may
            // cover terminal content.
            pagesContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 4),
            pagesContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagesContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pagesContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -6),

            tabStrip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),

            toolbar.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12
            ),
            toolbar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12
            ),
            toolbar.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6
            ),
            toolbar.heightAnchor.constraint(equalToConstant: TerminalToolbar.height),

            noSessionsView.centerXAnchor.constraint(equalTo: pagesContainer.centerXAnchor),
            noSessionsView.centerYAnchor.constraint(equalTo: pagesContainer.centerYAnchor),

            unpairedView.topAnchor.constraint(equalTo: view.topAnchor),
            unpairedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            unpairedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unpairedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        pagesContainer.addGestureRecognizer(panGesture)
    }

    private func buildNoSessionsHint() {
        let label = UILabel()
        label.text = "No terminals"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center

        var config = UIButton.Configuration.bordered()
        config.title = "New Terminal"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 6
        config.baseForegroundColor = PedalsTheme.uiContent
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in self?.createOnOnlyComputer() }, for: .touchUpInside
        )
        // With several computers bound this button carries the same picker menu
        // as the tab strip's + (installed by the $computers sink).
        noSessionsCreateButton = button

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        noSessionsView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: noSessionsView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: noSessionsView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: noSessionsView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: noSessionsView.trailingAnchor),
        ])
    }

    // MARK: - Bindings

    private func bind() {
        manager.$terminals
            .combineLatest(manager.$activeID)
            .sink { [weak self] terminals, activeId in
                self?.apply(terminals: terminals, activeId: activeId)
            }
            .store(in: &cancellables)

        manager.outputs
            .sink { [weak self] id, output in self?.handle(id: id, output: output) }
            .store(in: &cancellables)

        manager.exits
            .sink { [weak self] id, code in self?.pages[id]?.host.markExited(code: code) }
            .store(in: &cancellables)

        // NOTE: @Published emits during willSet — inside a sink the source
        // property still holds the OLD value, so overlay state must be
        // computed from the emitted values, never read back off the manager.
        manager.$phases
            .sink { [weak self] phases in
                guard let self else { return }
                updateOverlays(terminals: manager.terminals, phases: phases)
            }
            .store(in: &cancellables)

        manager.$computers
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                guard let self else { return }
                computerCount = count
                let unpaired = count == 0
                unpairedView.isHidden = !unpaired
                tabStrip.isHidden = unpaired
                toolbar.isHidden = unpaired
                let menu = count > 1 ? makeCreateMenu() : nil
                tabStrip.setCreateMenu(menu)
                noSessionsCreateButton?.menu = menu
                noSessionsCreateButton?.showsMenuAsPrimaryAction = menu != nil
                noSessionsView.isHidden = !(manager.terminals.isEmpty && !unpaired)
                // The tab-title "machine · " prefix depends on the computer
                // count; refresh titles when it crosses the 1↔many boundary
                // even if no session changed (e.g. binding an idle computer).
                apply(terminals: manager.terminals, activeId: manager.activeID)
            }
            .store(in: &cancellables)

        manager.errors
            .sink { [weak self] message in self?.presentError(message) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.manager.kickAll() }
            .store(in: &cancellables)

    }

    private func handle(id: TerminalID, output: TerminalManager.Output) {
        guard let page = pages[id] else { return }
        switch output {
        case .replay(let data):
            page.host.feedReplay(data)
            // Sync the daemon-side grid to this device's current geometry
            // (the replay was rendered for whoever attached last).
            if let cols = page.host.cols, let rows = page.host.rows {
                manager.sendResize(id, cols: cols, rows: rows)
            }
        case .stdout(let data):
            page.host.feed(data)
        }
    }

    // MARK: - Terminal/page reconciliation

    private func apply(terminals: [Terminal], activeId: TerminalID?) {
        // A pan drives page frames/visibility by hand; a mid-gesture rebuild
        // would hide the page being dragged. Re-run once the gesture settles.
        if isPanning {
            deferredApply = true
            return
        }
        let ids = Set(terminals.map(\.id))
        orderedIds = terminals.map(\.id)

        for (id, page) in pages where !ids.contains(id) {
            page.container.removeFromSuperview()
            pages.removeValue(forKey: id)
            if visibleId == id { visibleId = nil }
        }

        for terminal in terminals where pages[terminal.id] == nil {
            let page = Page(host: TerminalHost(controller: services.makeTerminalController()))
            let id = terminal.id
            page.host.onInput = { [weak self] data in
                self?.manager.sendStdin(id, data: data)
            }
            page.host.onResize = { [weak self] cols, rows in
                self?.manager.sendResize(id, cols: cols, rows: rows)
            }
            page.host.onStickyCtrlConsumed = { [weak self] in
                self?.toolbar.consumeStickyCtrl()
            }
            pages[id] = page

            page.container.isHidden = true
            page.container.translatesAutoresizingMaskIntoConstraints = true
            page.container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.container.frame = pagesContainer.bounds
            pagesContainer.addSubview(page.container)

            // The channel can go live while apply() is deferred by a pan — the
            // replay arrived with no page to feed and was dropped. Fetch a
            // fresh snapshot so the new page isn't permanently blank.
            if manager.phases[id] == .live {
                manager.requestReplay(id)
            }
        }

        setVisiblePage(activeId)
        updateOverlays(terminals: terminals, phases: manager.phases)

        let showComputer = computerCount > 1
        tabStrip.update(
            tabs: terminals.map {
                .init(
                    id: $0.id,
                    title: showComputer ? "\($0.computerName) · \($0.info.title)" : $0.info.title,
                    alive: $0.info.alive && !$0.closing
                )
            },
            activeId: activeId
        )
        noSessionsView.isHidden = !(terminals.isEmpty && computerCount > 0)
    }

    /// Idempotent on purpose: activeID can update BEFORE the terminal list
    /// does (create flow), so the first call may record an id whose page
    /// doesn't exist yet — the re-run after page creation must still unhide it.
    private func setVisiblePage(_ id: TerminalID?) {
        visibleId = id
        for (pageId, page) in pages {
            page.container.isHidden = pageId != id
            page.container.frame = pagesContainer.bounds
        }
        if let id, let page = pages[id] {
            page.host.stickyCtrl = toolbar.ctrlArmed
            if !page.host.view.isFirstResponder {
                page.host.view.becomeFirstResponder()
            }
            // Unhiding does not fire didMoveToWindow, so nothing else
            // repaints output that arrived while the view was hidden.
            page.host.kickRender()
        }
    }

    private func updateOverlays(terminals: [Terminal], phases: [TerminalID: TerminalChannel.Phase]) {
        for (id, page) in pages {
            let mode: TerminalStatusOverlay.Mode
            if terminals.first(where: { $0.id == id })?.closing == true {
                mode = .closing
            } else {
                switch phases[id] {
                case .connecting: mode = .connecting
                case .reconnecting: mode = .reconnecting
                case .live: mode = .hidden
                // Asleep (pooled out) or never attached: switching to the tab
                // opens a channel immediately, so show the loading state.
                case nil: mode = id == visibleId ? .connecting : .hidden
                }
            }
            page.overlay.setMode(mode)
        }
    }

    // MARK: - Create

    /// Direct + tap when 0–1 computers are bound (the multi-computer menu is
    /// installed via `setCreateMenu` otherwise).
    private func createOnOnlyComputer() {
        guard let computer = manager.computers.first else { return }
        create(on: computer.id)
    }

    private func create(on computerID: String) {
        // The picker menu already disables offline computers; this covers the
        // single-computer and empty-state paths (and races): a create sent to
        // an absent host is dropped by the relay and would fail silently.
        guard let computer = manager.computer(id: computerID) else { return }
        guard computer.hostOnline else {
            presentError("“\(computer.displayName)” is offline.")
            return
        }
        let active = visibleId.flatMap { pages[$0] }?.host
        manager.createTerminal(
            on: computerID,
            cols: Int(active?.cols ?? 120),
            rows: Int(active?.rows ?? 40)
        )
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: "Terminal Error", message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Menu listing every bound computer; rebuilt each presentation so names
    /// and connection states are current.
    private func makeCreateMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                let actions = manager.computers.map { computer in
                    let online = computer.hostOnline
                    let action = UIAction(
                        title: computer.displayName,
                        image: UIImage(systemName: online ? "desktopcomputer" : "wifi.slash"),
                        attributes: online ? [] : [.disabled],
                        state: visibleId?.computerID == computer.id ? .on : .off
                    ) { [weak self] _ in
                        self?.create(on: computer.id)
                    }
                    if !online { action.subtitle = "Offline" }
                    return action
                }
                completion(actions)
            }
        ])
    }

    // MARK: - Horizontal pan between terminals

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let activeId = visibleId,
              let activeIndex = orderedIds.firstIndex(of: activeId),
              let activePage = pages[activeId]
        else { return }

        let width = pagesContainer.bounds.width
        let tx = gesture.translation(in: pagesContainer).x
        // Dragging left (tx < 0) reveals the NEXT terminal, and vice versa.
        let direction = tx < 0 ? 1 : -1
        let targetIndex = activeIndex + direction
        let hasTarget = orderedIds.indices.contains(targetIndex)
        let targetPage = hasTarget ? pages[orderedIds[targetIndex]] : nil

        switch gesture.state {
        case .changed:
            isPanning = true
            // Rubber-band when there is no neighbor on that side.
            let effectiveTx = hasTarget ? tx : tx / 3
            activePage.container.frame.origin.x = effectiveTx

            if let targetPage, hasTarget {
                if panTarget != targetIndex {
                    // Direction changed mid-gesture: hide the old candidate.
                    if let old = panTarget, orderedIds.indices.contains(old),
                       old != targetIndex, let oldPage = pages[orderedIds[old]]
                    {
                        oldPage.container.isHidden = true
                    }
                    panTarget = targetIndex
                    targetPage.container.isHidden = false
                }
                targetPage.container.frame = pagesContainer.bounds.offsetBy(
                    dx: effectiveTx + CGFloat(direction) * width, dy: 0
                )
                tabStrip.setSwitchProgress(
                    from: activeIndex, to: targetIndex, progress: abs(effectiveTx) / width
                )
            }

        case .ended, .cancelled:
            // Keep apply() deferred through the settle animation too — an active
            // page hasn't been committed yet, so a mid-animation rebuild would
            // hide the page sliding in. Cleared in the completion blocks.
            let velocity = gesture.velocity(in: pagesContainer).x
            let commit = hasTarget
                && (abs(tx) > width * 0.35 || abs(velocity) > 700)
                && (velocity == 0 || (velocity < 0) == (direction == 1))

            if commit, let targetPage, gesture.state == .ended {
                let targetId = orderedIds[targetIndex]
                // Settle the tab strip in parallel with the page slide (same
                // spring) so they track; the completion's model update then
                // re-animates nothing.
                tabStrip.commitSwitch(
                    to: targetIndex,
                    duration: 0.42, damping: 0.86,
                    initialVelocity: abs(velocity) / width
                )
                UIView.animate(
                    withDuration: 0.42, delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: abs(velocity) / width,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    activePage.container.frame = self.pagesContainer.bounds.offsetBy(
                        dx: CGFloat(-direction) * width, dy: 0
                    )
                    targetPage.container.frame = self.pagesContainer.bounds
                } completion: { _ in
                    self.panTarget = nil
                    self.isPanning = false
                    let missedApply = self.deferredApply
                    self.deferredApply = false
                    // Drives setVisiblePage + tab strip settle via the binding.
                    self.manager.activate(targetId)
                    // activate() no-ops if the target was removed mid-gesture
                    // (its reconcile was deferred above) — nothing would emit,
                    // so run the skipped apply explicitly.
                    if missedApply {
                        self.apply(terminals: self.manager.terminals, activeId: self.manager.activeID)
                    }
                }
            } else {
                UIView.animate(
                    withDuration: 0.38, delay: 0,
                    usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    activePage.container.frame = self.pagesContainer.bounds
                    if let targetPage, hasTarget {
                        targetPage.container.frame = self.pagesContainer.bounds.offsetBy(
                            dx: CGFloat(direction) * width, dy: 0
                        )
                    }
                } completion: { _ in
                    if let target = self.panTarget,
                       self.orderedIds.indices.contains(target),
                       self.orderedIds[target] != self.visibleId
                    {
                        self.pages[self.orderedIds[target]]?.container.isHidden = true
                    }
                    self.panTarget = nil
                    self.isPanning = false
                    // A rebroadcast was skipped mid-gesture; reconcile now that
                    // we settled back on the same page.
                    if self.deferredApply {
                        self.deferredApply = false
                        self.apply(terminals: self.manager.terminals, activeId: self.manager.activeID)
                    }
                }
                tabStrip.cancelSwitchProgress()
            }

        default:
            break
        }
    }

    // MARK: - Pairing entry points

    private func presentPairingCode() {
        let controller = PairingCodeViewController()
        let services = services
        controller.onPair = { code in
            try await services.bind(code: code)
        }
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    // MARK: - Settings

    private func presentSettings() {
        let settings = SettingsViewController(services: services)
        present(UINavigationController(rootViewController: settings), animated: true)
    }
}

extension MainViewController: UIGestureRecognizerDelegate {
    /// Claim only clearly-horizontal pans; everything else stays with the
    /// terminal (vertical scrollback, taps, long-press selection).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        let velocity = panGesture.velocity(in: pagesContainer)
        return abs(velocity.x) > abs(velocity.y) * 1.4
    }

    /// The terminal's own recognizers (touch scroll, taps) must wait for the
    /// horizontal pan to fail; it fails immediately for vertical movement, so
    /// scrollback stays responsive.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === panGesture
            && otherGestureRecognizer.view?.isDescendant(of: pagesContainer) == true
    }
}
