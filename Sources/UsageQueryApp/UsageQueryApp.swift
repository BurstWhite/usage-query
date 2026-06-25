import SwiftUI
import UsageQueryCore

@main
struct UsageQueryApp: App {
    @StateObject private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsageDashboardView(viewModel: viewModel)
                .frame(width: 420, height: 560)
                .task {
                    await viewModel.refresh()
                }
        } label: {
            Label(viewModel.menuBarTitle, systemImage: "gauge.with.dots.needle.bottom.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
