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
            "通过 Touch ID 或 Mac 登录密码继续"
        case .authenticating:
            "正在等待系统验证…"
        case .unlocked:
            "已解锁"
        case .failed:
            "验证未完成，请重试"
        }
    }

    private var actionTitle: String {
        state == .failed ? "重新验证" : "解锁"
    }
}
