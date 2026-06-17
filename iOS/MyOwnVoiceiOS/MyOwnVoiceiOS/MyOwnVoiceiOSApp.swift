import SwiftUI

@main
struct MyOwnVoiceiOSApp: App {
    @StateObject private var viewModel = VoiceDictationViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    viewModel.handleOpenURL(url)
                }
        }
    }
}
