import Combine
import PedalsKit
import UIKit

/// Safari-style main screen: floating glass tab strip on top, the active
/// session's terminal filling the screen beneath it (content scrolls under the
/// glass), and a persistent glass input toolbar at the bottom that rides above
/// the keyboard. Horizontal pans on the terminal page between sessions, with
/// the tab strip following the gesture.
@MainActor
final class MainViewController: UIViewController {
    private let services: AppServices

    // Terminal hosting: one live emulator per attached session.
    private let pagesContainer = UIView()
    private var hosts: [Int: TerminalHost] = [:]
    private var orderedIds: [Int] = []
    private var visibleHostId: Int?

    private let tabStrip = TabStripView()
    private let toolbar = TerminalToolbar()

    private let unpairedView = UnpairedStateView()
    private let noSessionsView = UIView()

    private var panGesture: UIPanGestureRecognizer!
    /// In-flight pan: target index we are dragging toward.
    private var panTarget: Int?

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
        view.backgroundColor = services.preferences.backgroundColor
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
            guard let self, let id = visibleHostId else { return }
            services.connection.sendStdin(sessionId: UInt32(id), data: bytes)
        }
        toolbar.onStickyCtrl = { [weak self] armed in
            guard let self, let id = visibleHostId else { return }
            hosts[id]?.stickyCtrl = armed
        }
        view.addSubview(toolbar)

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] id in self?.services.sessionStore.activate(id) }
        tabStrip.onClose = { [weak self] id in self?.services.connection.closeSession(id: id) }
        tabStrip.onSettings = { [weak self] in self?.presentSettings() }
        tabStrip.onCreate = { [weak self] in self?.createSession() }
        view.addSubview(tabStrip)

        noSessionsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noSessionsView)
        buildNoSessionsHint()

        unpairedView.translatesAutoresizingMaskIntoConstraints = false
        unpairedView.onScan = { [weak self] in self?.presentScanner() }
        unpairedView.onPaste = { [weak self] in self?.presentPasteAlert() }
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
        label.text = "No sessions"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center

        var config = UIButton.Configuration.bordered()
        config.title = "New Session"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 6
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.createSession() }, for: .touchUpInside)

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
        let store = services.sessionStore
        store.$sessions
            .combineLatest(store.$activeSessionId)
            .sink { [weak self] sessions, activeId in
                self?.apply(sessions: sessions, activeId: activeId)
            }
            .store(in: &cancellables)

        services.connection.events
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)

        services.connection.$pairing
            .map { $0 == nil }
            .removeDuplicates()
            .sink { [weak self] unpaired in
                self?.unpairedView.isHidden = !unpaired
                self?.tabStrip.isHidden = unpaired
                self?.toolbar.isHidden = unpaired
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppServices.appearanceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                view.backgroundColor = services.preferences.backgroundColor
            }
            .store(in: &cancellables)
    }

    private func handle(_ event: ConnectionController.HostEvent) {
        switch event {
        case let .stdout(sessionId, data):
            hosts[Int(sessionId)]?.feed(data)
        case let .replay(sessionId, data):
            hosts[Int(sessionId)]?.feedReplay(data)
        case let .exit(id, code):
            hosts[id]?.markExited(code: code)
        case .sessions, .created, .title, .error:
            break // handled via SessionStore
        }
    }

    // MARK: - Session/terminal reconciliation

    private func apply(sessions: [SessionInfo], activeId: Int?) {
        let ids = Set(sessions.map(\.id))
        orderedIds = sessions.map(\.id)

        for (id, host) in hosts where !ids.contains(id) {
            host.view.removeFromSuperview()
            hosts.removeValue(forKey: id)
            if visibleHostId == id { visibleHostId = nil }
        }

        for session in sessions where hosts[session.id] == nil {
            let host = TerminalHost(
                sessionId: session.id, controller: services.makeTerminalController()
            )
            let sid = UInt32(session.id)
            host.onInput = { [weak self] data in
                self?.services.connection.sendStdin(sessionId: sid, data: data)
            }
            host.onResize = { [weak self] cols, rows in
                self?.services.connection.sendResize(sessionId: sid, cols: cols, rows: rows)
            }
            host.onStickyCtrlConsumed = { [weak self] in
                self?.toolbar.consumeStickyCtrl()
            }
            hosts[session.id] = host

            host.view.isHidden = true
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.frame = pagesContainer.bounds
            pagesContainer.addSubview(host.view)

            services.connection.attach(id: session.id)
        }

        setVisibleHost(activeId)

        tabStrip.update(
            tabs: sessions.map {
                .init(
                    id: $0.id, title: $0.title, alive: $0.alive,
                    agent: $0.agent, agentState: $0.agentState
                )
            },
            activeId: activeId
        )
        noSessionsView.isHidden =
            !(sessions.isEmpty && services.connection.pairing != nil)
    }

    /// Idempotent on purpose: activeSessionId can update BEFORE the session
    /// list does (create flow), so the first call may record an id whose host
    /// doesn't exist yet — the re-run after host creation must still unhide it.
    private func setVisibleHost(_ id: Int?) {
        visibleHostId = id
        for (hostId, host) in hosts {
            host.view.isHidden = hostId != id
            host.view.frame = pagesContainer.bounds
        }
        if let id, let host = hosts[id] {
            host.stickyCtrl = toolbar.ctrlArmed
            if !host.view.isFirstResponder {
                host.view.becomeFirstResponder()
            }
            // Unhiding does not fire didMoveToWindow, so nothing else
            // repaints output that arrived while the view was hidden.
            host.kickRender()
        }
    }

    private func createSession() {
        let active = visibleHostId.flatMap { hosts[$0] }
        services.connection.createSession(
            cols: Int(active?.cols ?? 120),
            rows: Int(active?.rows ?? 40)
        )
    }

    // MARK: - Horizontal pan between sessions

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let activeId = visibleHostId,
              let activeIndex = orderedIds.firstIndex(of: activeId),
              let activeHost = hosts[activeId]
        else { return }

        let width = pagesContainer.bounds.width
        let tx = gesture.translation(in: pagesContainer).x
        // Dragging left (tx < 0) reveals the NEXT session, and vice versa.
        let direction = tx < 0 ? 1 : -1
        let targetIndex = activeIndex + direction
        let hasTarget = orderedIds.indices.contains(targetIndex)
        let targetHost = hasTarget ? hosts[orderedIds[targetIndex]] : nil

        switch gesture.state {
        case .changed:
            // Rubber-band when there is no neighbor on that side.
            let effectiveTx = hasTarget ? tx : tx / 3
            activeHost.view.frame.origin.x = effectiveTx

            if let targetHost, hasTarget {
                if panTarget != targetIndex {
                    // Direction changed mid-gesture: hide the old candidate.
                    if let old = panTarget, orderedIds.indices.contains(old),
                       old != targetIndex, let oldHost = hosts[orderedIds[old]]
                    {
                        oldHost.view.isHidden = true
                    }
                    panTarget = targetIndex
                    targetHost.view.isHidden = false
                }
                targetHost.view.frame = pagesContainer.bounds.offsetBy(
                    dx: effectiveTx + CGFloat(direction) * width, dy: 0
                )
                tabStrip.setSwitchProgress(
                    from: activeIndex, to: targetIndex, progress: abs(effectiveTx) / width
                )
            }

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: pagesContainer).x
            let commit = hasTarget
                && (abs(tx) > width * 0.35 || abs(velocity) > 700)
                && (velocity == 0 || (velocity < 0) == (direction == 1))

            if commit, let targetHost, gesture.state == .ended {
                let targetId = orderedIds[targetIndex]
                UIView.animate(
                    withDuration: 0.42, delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: abs(velocity) / width,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    activeHost.view.frame = self.pagesContainer.bounds.offsetBy(
                        dx: CGFloat(-direction) * width, dy: 0
                    )
                    targetHost.view.frame = self.pagesContainer.bounds
                } completion: { _ in
                    self.panTarget = nil
                    // Drives setVisibleHost + tab strip settle via the binding.
                    self.services.sessionStore.activate(targetId)
                }
            } else {
                UIView.animate(
                    withDuration: 0.38, delay: 0,
                    usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    activeHost.view.frame = self.pagesContainer.bounds
                    if let targetHost, hasTarget {
                        targetHost.view.frame = self.pagesContainer.bounds.offsetBy(
                            dx: CGFloat(direction) * width, dy: 0
                        )
                    }
                } completion: { _ in
                    if let target = self.panTarget,
                       self.orderedIds.indices.contains(target),
                       self.orderedIds[target] != self.visibleHostId
                    {
                        self.hosts[self.orderedIds[target]]?.view.isHidden = true
                    }
                    self.panTarget = nil
                }
                tabStrip.cancelSwitchProgress()
            }

        default:
            break
        }
    }

    // MARK: - Pairing entry points

    private func presentScanner() {
        let scanner = PairingScanViewController()
        scanner.onPaired = { [weak self] info in
            self?.services.connection.pair(with: info)
        }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    private func presentPasteAlert() {
        let alert = UIAlertController(
            title: "Paste Pairing Link",
            message: "Paste the pedals:// link printed by “pedals pair”.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "pedals://pair?…"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            if let clip = UIPasteboard.general.string, clip.hasPrefix("pedals://") {
                field.text = clip
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let text = alert?.textFields?.first?.text?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  services.handlePairingURL(url)
            else {
                self?.presentInvalidLinkAlert()
                return
            }
        })
        present(alert, animated: true)
    }

    private func presentInvalidLinkAlert() {
        let alert = UIAlertController(
            title: "Invalid Pairing Link",
            message: "That doesn’t look like a pedals:// pairing link.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
