import SwiftUI
import EvoSimAppKit

@main
struct EvoSimMacApp: App {
    var body: some Scene {
        WindowGroup("evo-sim") {
            TankView()
                .frame(minWidth: 720, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
