import SwiftUI

@main
struct EvoSimMacApp: App {
    var body: some Scene {
        WindowGroup("evo-sim") {
            DebugView()
                .frame(minWidth: 640, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
