import AppKit
import SwiftUI
import UsageQueryCore

/// `UsageQuery --render-snapshots <directory>`
///
/// Developer aid: scans once, renders each dashboard tab and the floating
/// window to PNG files offscreen, then exits. Lets the UI be reviewed without
/// screen recording permission or clicking through the menu bar.
@MainActor
enum SnapshotCommand {
    static let flag = "--render-snapshots"

    static func run() -> Never {
        let arguments = CommandLine.arguments
        let index = arguments.firstIndex(of: flag) ?? 0
        let directory = URL(fileURLWithPath: index + 1 < arguments.count ? arguments[index + 1] : ".")

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            let viewModel = UsageViewModel()
            await viewModel.refresh()
            let floatingPanel = FloatingPanelController(viewModel: viewModel)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = scheme == .aqua ? "light" : "dark"
                for tab in ["overview", "codex", "claude", "settings"] {
                    let view = UsageDashboardView(viewModel: viewModel, floatingPanel: floatingPanel, initialTab: tab)
                        .frame(width: 420, height: 580)
                    await render(view, appearance: scheme, to: directory.appendingPathComponent("\(tab)-\(suffix).png"))
                }
                let floating = FloatingUsageView(viewModel: viewModel, controller: floatingPanel)
                await render(floating, appearance: scheme, to: directory.appendingPathComponent("floating-\(suffix).png"))
            }
            exit(0)
        }
        application.run()
        exit(0)
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI a turn to finish layout and async content.
        try? await Task.sleep(for: .milliseconds(300))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
