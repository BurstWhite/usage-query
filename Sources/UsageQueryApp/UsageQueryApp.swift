import SwiftUI
import UsageQueryCore

@main
enum UsageQueryMain {
    static func main() {
        // Claude Code can run this same binary as its status line command.
        if CommandLine.arguments.contains(StatusLineBridgeCommand.flag) {
            StatusLineBridgeCommand.run()
        }
        if CommandLine.arguments.contains(SnapshotCommand.flag) {
            MainActor.assumeIsolated { SnapshotCommand.run() }
        }
        UsageQueryApp.main()
    }
}

struct UsageQueryApp: App {
    @StateObject private var viewModel: UsageViewModel
    @StateObject private var floatingPanel: FloatingPanelController

    init() {
        let viewModel = UsageViewModel()
        let floatingPanel = FloatingPanelController(viewModel: viewModel)
        _viewModel = StateObject(wrappedValue: viewModel)
        _floatingPanel = StateObject(wrappedValue: floatingPanel)
        DispatchQueue.main.async {
            viewModel.startAutoRefresh()
            floatingPanel.restore()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsageDashboardView(viewModel: viewModel, floatingPanel: floatingPanel)
                .frame(width: 420, height: 580)
                .task {
                    await viewModel.refresh()
                }
        } label: {
            Label(viewModel.menuBarTitle, systemImage: "gauge.with.dots.needle.bottom.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
