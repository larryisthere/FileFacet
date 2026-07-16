import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case privacy
    case about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .privacy: "隐私"
        case .about: "关于"
        }
    }
    var systemImage: String {
        switch self {
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsSection? = .privacy
}

struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var navigation: SettingsNavigationModel
    let setAuthenticationEnabled: (Bool) -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 188, max: 220)
        } detail: {
            switch navigation.selection ?? .privacy {
            case .privacy:
                privacyView
            case .about:
                aboutView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var privacyView: some View {
        Form {
            Section {
                Toggle(
                    "启用应用锁",
                    isOn: Binding(
                        get: { preferences.authenticationEnabled },
                        set: { enabled in setAuthenticationEnabled(enabled) }
                    )
                )

                Picker("闲置后锁定", selection: $preferences.idleLockInterval) {
                    ForEach(IdleLockInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .disabled(preferences.authenticationEnabled == false)

                Text("开启时使用 Touch ID 或 Mac 登录密码验证。应用切换时始终隐藏窗口中的视频与标签信息。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("隐私")
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
    }

    private var aboutView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppConfiguration.displayName)
                            .font(.title2.weight(.semibold))
                        Text(AppConfiguration.versionDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow {
                        Text("最低系统要求").foregroundStyle(.secondary)
                        Text("macOS \(AppConfiguration.minimumSystemVersion)")
                    }
                    GridRow {
                        Text("数据与视频").foregroundStyle(.secondary)
                        Text("本地保存 · 原视频只读")
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
        }
        .navigationTitle("关于")
    }
}
