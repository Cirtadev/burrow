import AppKit
import BurrowKit
import SwiftUI

/// What the user typed in the sign-in window.
struct SignInEntry {
    var password = ""
    var passphrase = ""
    var code = ""
    var savePassword = false
}

/// Asks for what a configuration doesn't store (the password, the key's passphrase, the code), or answers a
/// question the server asked while connecting (`challenge`).
struct SignInView: View {
    let profile: VPNProfile
    let message: String?
    var challenge: TunnelChallenge?
    var onConnect: (SignInEntry) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var entry = SignInEntry()
    @FocusState private var focus: Field?

    private enum Field { case password, passphrase, code }

    /// The code field takes an authenticator code (digits) unless it answers the server's own question.
    private var codeIsOTP: Bool { challenge == nil && profile.effectiveOTPMode == .prompt }
    private var asksCode: Bool { challenge.map(\.responseRequired) ?? profile.needsCode }
    private var codeLabel: String {
        if challenge != nil { return "Answer" }
        return profile.summary.staticChallenge.map { _ in "Answer" } ?? "Code"
    }
    private var codeIsSecret: Bool {
        if let challenge { return !challenge.echo }
        if profile.summary.staticChallenge != nil { return !profile.summary.staticChallengeEcho }
        return false
    }
    private var question: String? { challenge?.text ?? profile.summary.staticChallenge }

    private var canConnect: Bool {
        if challenge != nil { return !asksCode || !entry.code.isEmpty }
        return (!profile.needsPassword || !entry.password.isEmpty)
            && (!profile.needsPassphrase || !entry.passphrase.isEmpty)
            && (!asksCode || (codeIsOTP ? entry.code.count >= 6 : !entry.code.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: challenge == nil ? "lock.shield" : "questionmark.bubble")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(challenge == nil ? "Connect to \(profile.name)" : "\(profile.name) asks").font(.headline)
                    if profile.usesPassword, !profile.username.isEmpty {
                        Text(profile.username).foregroundStyle(.secondary)
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let question, !question.isEmpty {
                Text(question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Form {
                if challenge == nil {
                    if profile.needsPassword {
                        SecureField("Password", text: $entry.password)
                            .focused($focus, equals: .password)
                    }
                    if profile.needsPassphrase {
                        SecureField("Key passphrase", text: $entry.passphrase)
                            .focused($focus, equals: .passphrase)
                    }
                    if profile.needsPassword || profile.needsPassphrase {
                        Toggle(profile.needsPassphrase && profile.usesPassword
                               ? "Save password and passphrase in the keychain" : profile.needsPassphrase
                               ? "Save passphrase in the keychain" : "Save password in the keychain",
                               isOn: $entry.savePassword)
                    }
                }
                if asksCode {
                    Group {
                        if codeIsSecret {
                            SecureField(codeLabel, text: $entry.code)
                        } else {
                            TextField(codeLabel, text: $entry.code, prompt: codeIsOTP ? Text("6-digit code") : nil)
                                .font(codeIsOTP ? .system(.body, design: .monospaced) : .body)
                        }
                    }
                    .focused($focus, equals: .code)
                    .onChange(of: entry.code) { _, new in
                        guard codeIsOTP else { return }
                        let digits = String(new.filter(\.isNumber).prefix(8))
                        if digits != new { entry.code = digits }
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(challenge == nil ? "Connect" : asksCode ? "Answer" : "Continue") { onConnect(entry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            focus = challenge != nil ? .code : profile.needsPassword ? .password : profile.needsPassphrase ? .passphrase : .code
        }
    }
}

@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    /// The server question on screen, if any.
    private(set) var shownChallengeID: Int?

    func show(for profile: VPNProfile, message: String?, onConnect: @escaping (SignInEntry) -> Void) {
        present(SignInView(profile: profile, message: message), challengeID: nil, onConnect: onConnect, onCancel: {})
    }

    /// The server's question; closing the window without answering calls `onCancel`.
    func show(_ challenge: TunnelChallenge, for profile: VPNProfile, onAnswer: @escaping (String) -> Void,
              onCancel: @escaping () -> Void) {
        guard shownChallengeID != challenge.id else { return }
        present(SignInView(profile: profile, message: nil, challenge: challenge), challengeID: challenge.id,
                onConnect: { onAnswer($0.code) }, onCancel: onCancel)
    }

    /// The question went away (answered elsewhere, or the connection ended): close its window.
    func closeChallenge() {
        guard shownChallengeID != nil else { return }
        onClose = nil
        window?.close()
    }

    private func present(_ view: SignInView, challengeID: Int?, onConnect: @escaping (SignInEntry) -> Void,
                         onCancel: @escaping () -> Void) {
        onClose = nil
        window?.close()
        var view = view
        view.onConnect = { [weak self] entry in
            self?.onClose = nil
            self?.window?.close()
            onConnect(entry)
        }
        view.onCancel = { [weak self] in self?.window?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Burrow"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        shownChallengeID = challengeID
        onClose = onCancel
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        let closed = onClose
        onClose = nil
        window = nil
        shownChallengeID = nil
        closed?()
    }
}
