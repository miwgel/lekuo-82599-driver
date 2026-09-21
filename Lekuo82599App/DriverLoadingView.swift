/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The SwiftUI view that provides the driver-loading UI.
*/

import SwiftUI

struct DriverLoadingView: View {

    @ObservedObject var viewModel: DriverLoadingViewModel = .init()
    @State private var hasHandledLaunchRequest = false

    var body: some View {
        VStack(alignment: .center) {
            Text("Driver Manager")
                .padding()
                .font(.title)
            Text(self.viewModel.dextLoadingState)
                .multilineTextAlignment(.center)
            HStack {
                Button(
                    action: {
                        self.viewModel.activateMyDext()
                    }, label: {
                        Text("Install Dext")
                    }
                )
                Button(
                    action: {
                        self.viewModel.deactivateMyDext()
                    }, label: {
                        Text("Remove Dext")
                    }
                )
            }
            .disabled(!self.viewModel.canSubmitRequest)
        }
        .frame(width: 500, height: 200, alignment: .center)
        .onAppear {
            guard !hasHandledLaunchRequest else { return }
            hasHandledLaunchRequest = true
            let arguments = ProcessInfo.processInfo.arguments
            let activate = arguments.contains("--activate-extension")
            let deactivate = arguments.contains("--deactivate-extension")
            guard activate != deactivate else { return }
            if activate {
                viewModel.activateMyDext()
            } else {
                viewModel.deactivateMyDext()
            }
        }
    }
}

struct DriverLoadingView_Previews: PreviewProvider {
    static var previews: some View {
        DriverLoadingView()
    }
}
