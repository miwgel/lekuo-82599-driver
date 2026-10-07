/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The SwiftUI scene builder that sets up the driver installation UI.
*/

import SwiftUI

@main
struct Lekuo82599App: App {
    var body: some Scene {
        WindowGroup {
            DriverLoadingView()
        }
        .defaultSize(width: 880, height: 760)
        .windowResizability(.contentMinSize)
    }
}
