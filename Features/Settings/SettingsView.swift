import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    let setAuthenticationEnabled: (Bool) -> Void

    var body: some View {
        Form {
            Section("隐私") {
                Toggle(
                    "启用应用锁",
                    isOn: Binding(
                        get: { preferences.authenticationEnabled },
                        set: { enabled in setAuthenticationEnabled(enabled) }
                    )
                )

                Text("开启时使用 Touch ID 或 Mac 登录密码验证。应用切换时始终隐藏窗口中的视频与标签信息。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 220)
        .scenePadding()
    }
}
