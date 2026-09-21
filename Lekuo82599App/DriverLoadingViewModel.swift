/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The view model that indicates the state of driver loading.
*/

import Foundation
import SystemExtensions
import os.log

class DriverLoadingStateMachine {

    enum State {
        case unloaded
        case activating
        case needsApproval
        case needsReboot
        case activated
        case activationError
        case deactivating
        case deactivationNeedsApproval
        case deactivationNeedsReboot
        case deactivationError
    }

    enum Event {
        case activationStarted
        case promptForApproval
        case activationFinished
        case activationPendingReboot
        case activationFailed
        case deactivationStarted
        case deactivationPromptForApproval
        case deactivationFinished
        case deactivationPendingReboot
        case deactivationFailed
    }

    static func process(_ state: State, _ event: Event) -> State {

        switch event {
        case .deactivationStarted:
            return .deactivating
        case .deactivationPromptForApproval:
            return .deactivationNeedsApproval
        case .deactivationFinished:
            return .unloaded
        case .deactivationPendingReboot:
            return .deactivationNeedsReboot
        case .deactivationFailed:
            return .deactivationError
        default:
            break
        }

        switch state {
        case .unloaded:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval, .activationFinished, .activationPendingReboot, .activationFailed:
                return .activationError
            default:
                return state
            }

        case .activating, .needsApproval:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval:
                return .needsApproval
            case .activationFinished:
                return .activated
            case .activationPendingReboot:
                return .needsReboot
            case .activationFailed:
                return .activationError
            default:
                return state
            }

        case .needsReboot:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval, .activationPendingReboot:
                return .needsReboot
            case .activationFinished:
                return .activated
            case .activationFailed:
                return .activationError
            default:
                return state
            }

        case .activated:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval, .activationPendingReboot, .activationFailed:
                return .activationError
            case .activationFinished:
                return .activated
            default:
                return state
            }

        case .activationError:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval, .activationFinished, .activationPendingReboot, .activationFailed:
                return .activationError
            default:
                return state
            }

        case .deactivating, .deactivationNeedsApproval,
             .deactivationNeedsReboot, .deactivationError:
            switch event {
            case .activationStarted:
                return .activating
            case .promptForApproval, .activationFinished,
                 .activationPendingReboot, .activationFailed:
                return .activationError
            default:
                return state
            }
        }
    }
}

class DriverLoadingViewModel: NSObject {

    private enum PendingOperation {
        case activation
        case deactivation
    }

    // Your dext may not start in unloaded state every time. Add logic or states to check this.
    @Published private var state: DriverLoadingStateMachine.State = .unloaded

    private let dextIdentifier: String = "com.example.Lekuo82599Driver"
    private var pendingOperation: PendingOperation = .activation

    public var canSubmitRequest: Bool {
        switch state {
        case .activating, .needsApproval, .deactivating,
             .deactivationNeedsApproval:
            return false
        default:
            return true
        }
    }

    public var dextLoadingState: String {
        switch state {
        case .unloaded:
            return "Lekuo82599 isn't loaded."
        case .activating:
            return "Activating Lekuo82599, please wait."
        case .needsApproval:
            return "Please follow the prompt to approve Lekuo82599."
        case .needsReboot:
            return "macOS accepted the extension request; activation requires a restart."
        case .activated:
            return "Extension activation finished. The live SFP+ function is enabled in this development build."
        case .activationError:
            return "Lekuo82599 has experienced an error during activation.\nPlease check the logs to find the error."
        case .deactivating:
            return "Removing Lekuo82599, please wait."
        case .deactivationNeedsApproval:
            return "Please follow the prompt to approve removal of Lekuo82599."
        case .deactivationNeedsReboot:
            return "macOS accepted the removal request; removal requires a restart."
        case .deactivationError:
            return "Lekuo82599 has experienced an error during removal.\nPlease check the logs to find the error."
        }
    }
}

extension DriverLoadingViewModel: ObservableObject {

}

extension DriverLoadingViewModel {

    func activateMyDext() {
        activateExtension(dextIdentifier)
    }

    /// - Tag: ActivateExtension
    func activateExtension(_ dextIdentifier: String) {

        pendingOperation = .activation

        let request = OSSystemExtensionRequest
            .activationRequest(forExtensionWithIdentifier: dextIdentifier,
                               queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)

        self.state = DriverLoadingStateMachine.process(self.state, .activationStarted)
    }
    
    func deactivateMyDext() {
        deactivateExtension(dextIdentifier)
    }

    func deactivateExtension(_ dextIdentifier: String) {

        pendingOperation = .deactivation

        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: dextIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)

        self.state = DriverLoadingStateMachine.process(self.state, .deactivationStarted)
    }
}

extension DriverLoadingViewModel: OSSystemExtensionRequestDelegate {

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {

        var replacementAction: OSSystemExtensionRequest.ReplacementAction

        os_log("sysex actionForReplacingExtension: %@ %@", existing, ext)

        // Add appropriate logic here to determine whether the extension should be
        // replaced by the new extension. Common things to check for include
        // testing whether the new extension's version number is newer than
        // the current version number, or that the bundleIdentifier has changed.
        // For simplicity, this sample always replaces the current extension
        // with the new one.
        replacementAction = .replace

        // The upgrade case may require a separate set of states.
        self.state = DriverLoadingStateMachine.process(self.state, .activationStarted)

        return replacementAction
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {

        os_log("sysex requestNeedsUserApproval")

        self.state = DriverLoadingStateMachine.process(
            self.state,
            pendingOperation == .activation ? .promptForApproval :
                .deactivationPromptForApproval
        )
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {

        os_log("sysex didFinishWithResult: %d", result.rawValue)

        let event: DriverLoadingStateMachine.Event
        if pendingOperation == .activation {
            event = result == .willCompleteAfterReboot ?
                .activationPendingReboot : .activationFinished
        } else {
            event = result == .willCompleteAfterReboot ?
                .deactivationPendingReboot : .deactivationFinished
        }
        self.state = DriverLoadingStateMachine.process(self.state, event)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {

        os_log("sysex didFailWithError: %@", error.localizedDescription)

        // Some possible errors to check for:
        // Error 4: The dext identifier string in the code needs to match the one used in the project settings.
        // Error 8: Indicates a signing problem. During development, set signing to "automatic" and "sign to run locally". See README.md for more.

        // While this app only logs errors, production apps should provide feedback to customers about any errors encountered while loading the dext.

        self.state = DriverLoadingStateMachine.process(
            self.state,
            pendingOperation == .activation ? .activationFailed :
                .deactivationFailed
        )
    }
}
