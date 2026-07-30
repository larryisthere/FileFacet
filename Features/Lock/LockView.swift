import SwiftUI

struct LockView: View {
    let state: LockState
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)

            Text(AppConfiguration.displayName)
                .font(.title2.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)

            Button(actionTitle, action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(state == .authenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var message: String {
        switch state {
        case .locked:
            String(localized: .lockPrompt)
        case .authenticating:
            String(localized: .lockWaiting)
        case .unlocked:
            String(localized: .lockUnlocked)
        case .failed:
            String(localized: .lockFailed)
        }
    }

    private var actionTitle: String {
        state == .failed
            ? String(localized: .lockActionReauthenticate)
            : String(localized: .lockActionUnlock)
    }
}
