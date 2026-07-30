import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case importOptions
    case privacy
    case about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .importOptions: String(localized: .settingsImport)
        case .privacy: String(localized: .settingsPrivacy)
        case .about: String(localized: .settingsAbout)
        }
    }
    var systemImage: String {
        switch self {
        case .importOptions: "tray.and.arrow.down"
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
            case .importOptions:
                importView
            case .privacy:
                privacyView
            case .about:
                aboutView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var importView: some View {
        Form {
            Section {
                Picker(
                    String(localized: .settingsFolderImportMethod),
                    selection: $preferences.folderImportPreference
                ) {
                    ForEach(FolderImportPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }

                Text(String(localized: .settingsFolderImportMethodHelp))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(
                    String(localized: .folderImportIncludeRoot),
                    isOn: $preferences.includeSelectedFolderAsRootTag
                )
                .disabled(preferences.folderImportPreference == .direct)

                Text(String(localized: .settingsIncludeSelectedFolderHelp))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: .settingsImport))
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
    }

    private var privacyView: some View {
        Form {
            Section {
                Toggle(
                    String(localized: .settingsEnableLock),
                    isOn: Binding(
                        get: { preferences.authenticationEnabled },
                        set: { enabled in setAuthenticationEnabled(enabled) }
                    )
                )

                Picker(String(localized: .settingsIdleLock), selection: $preferences.idleLockInterval) {
                    ForEach(IdleLockInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .disabled(preferences.authenticationEnabled == false)

                Text(String(localized: .settingsLockNote))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: .settingsPrivacy))
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
                        Text(String(localized: .aboutMinimumSystem)).foregroundStyle(.secondary)
                        Text("macOS \(AppConfiguration.minimumSystemVersion)")
                    }
                    GridRow {
                        Text(String(localized: .aboutDataAndVideos)).foregroundStyle(.secondary)
                        Text(String(localized: .aboutLocalReadOnly))
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
        }
        .navigationTitle(String(localized: .settingsAbout))
    }
}
