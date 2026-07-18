import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let model: AppModel
    private let updater: UpdaterModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private weak var updateMenuItem: NSMenuItem?

    init(model: AppModel, updater: UpdaterModel) {
        self.model = model
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configurePopover()
        configureContextMenu()

        #if DEBUG
        if ProcessInfo.processInfo.environment["PEDALS_SHOW_POPOVER_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = statusItem.button else { return }
                togglePopover(relativeTo: button)
            }
        }
        #endif
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Pedals"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let root = MenuView()
            .environmentObject(model)
            .environmentObject(updater)
        let hostingController = NSHostingController(rootView: root)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
    }

    private func configureContextMenu() {
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false

        let update = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        update.target = self
        contextMenu.addItem(update)
        updateMenuItem = update

        contextMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Pedals",
            action: #selector(quitPedals),
            keyEquivalent: "q"
        )
        quit.target = self
        contextMenu.addItem(quit)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            contextMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 2),
                in: sender
            )
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItem?.isEnabled = updater.canCheckForUpdates
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func quitPedals() {
        NSApplication.shared.terminate(nil)
    }
}
