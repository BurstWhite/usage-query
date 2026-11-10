import AppKit
import SwiftUI

/// Owns the always-on-top usage panel that can stay visible while the menu bar
/// popover is closed.
@MainActor
final class FloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    private static let visibleKey = "floatingPanelVisible"

    @Published private(set) var isVisible = false

    private let viewModel: UsageViewModel
    private var panel: NSPanel?

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
    }

    /// Reopens the panel if it was showing when the app last quit.
    func restore() {
        if UserDefaults.standard.bool(forKey: Self.visibleKey) {
            show()
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        setVisible(true)
        Task { await viewModel.refresh() }
    }

    func hide() {
        panel?.orderOut(nil)
        setVisible(false)
    }

    func windowWillClose(_: Notification) {
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        viewModel.autoRefreshInterval = visible ? UsageViewModel.floatingRefreshInterval : UsageViewModel.backgroundRefreshInterval
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: FloatingUsageView.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let hosting = NSHostingController(rootView: FloatingUsageView(viewModel: viewModel, controller: self))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // First launch: top-right of the main screen. Afterwards the saved position wins.
        if let screen = NSScreen.main?.visibleFrame {
            let size = hosting.view.fittingSize
            panel.setFrame(
                NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24, width: size.width, height: size.height),
                display: false
            )
        }
        panel.setFrameAutosaveName("UsageQueryFloatingPanel")
        return panel
    }
}
