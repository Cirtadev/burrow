import AppKit
import SystemExtensions

/// Installs and updates BurrowTunnel, the packet-tunnel system extension inside Burrow.app. macOS copies it to
/// /Library/SystemExtensions and runs it as root; the first install waits for the user to allow it in
/// System Settings, later versions replace it without asking.
@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    nonisolated static let approvalHint = "Allow Burrow's VPN: in System Settings › Login Items & Extensions, click ⓘ next to Burrow and switch it on."

    /// Called when macOS starts waiting for the user's approval.
    var onNeedsApproval: (() -> Void)?
    /// macOS is waiting for the user to allow the extension.
    private(set) var needsApproval = false
    private var isActive = false
    private var inFlight = false
    private var waiting: [CheckedContinuation<Void, Error>] = []

    /// Returns once the extension bundled with this copy of Burrow is the active one. Cheap after the first time.
    func activate() async throws {
        if isActive { return }
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard !inFlight else { return }
            inFlight = true
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: VPNController.tunnelBundleIdentifier, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    /// Opens the pane where the user allows the extension.
    func openApprovalSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(pane)
    }

    private func finish(_ result: Result<Void, Error>) {
        inFlight = false
        needsApproval = false
        if case .success = result { isActive = true }
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(with: result) }
    }

    // MARK: - OSSystemExtensionRequestDelegate (on the main queue)

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // An updated Burrow brings its own tunnel; the system swaps it in (a running tunnel stops).
        NSLog("Burrow: replacing tunnel extension %@ (%@) with %@ (%@)", existing.bundleShortVersion,
              existing.bundleVersion, ext.bundleShortVersion, ext.bundleVersion)
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            needsApproval = true
            onNeedsApproval?()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            if result == .willCompleteAfterReboot {
                finish(.failure(ActivationError("Restart your Mac to finish installing Burrow's VPN.")))
            } else {
                finish(.success(()))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(ActivationError(error))) }
    }

    struct ActivationError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }

        init(_ error: Error) {
            let nsError = error as NSError
            guard nsError.domain == OSSystemExtensionErrorDomain,
                  let code = OSSystemExtensionError.Code(rawValue: nsError.code) else {
                errorDescription = nsError.localizedDescription
                return
            }
            errorDescription = switch code {
            case .unsupportedParentBundleLocation:
                "Move Burrow to the Applications folder and open it from there: macOS only installs its VPN from Applications."
            case .forbiddenBySystemPolicy:
                "This Mac's management settings don't allow Burrow's VPN."
            case .authorizationRequired:
                SystemExtensionActivator.approvalHint
            case .requestCanceled, .requestSuperseded:
                "Installing Burrow's VPN was interrupted. Try again."
            case .missingEntitlement, .extensionNotFound, .extensionMissingIdentifier, .duplicateExtensionIdentifer,
                 .unknownExtensionCategory, .codeSignatureInvalid, .validationFailed:
                "This copy of Burrow can't install its VPN (error \(nsError.code)). Download Burrow again."
            default:
                nsError.localizedDescription
            }
        }
    }
}
