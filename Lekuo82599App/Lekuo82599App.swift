/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The SwiftUI scene builder that sets up the driver installation UI.
*/

import SwiftUI

@main
struct Lekuo82599App: App {
    var body: some Scene {
        WindowGroup("Lekuo Control") {
            DriverLoadingView()
        }
        .defaultSize(width: 880, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Link("Lekuo Control on GitHub", destination: URL(string: "https://github.com/miwgel/lekuo-82599-driver")!)
                Link("Installation and Troubleshooting", destination: URL(string: "https://github.com/miwgel/lekuo-82599-driver/blob/main/README.md")!)
            }
        }
    }
}
