import Foundation

enum AppConfiguration {
    static let internalName = "VideoTagManager"
    static let bundleIdentifier = "com.larryisthere.video-tag-manager"
    static let minimumSystemVersion = "14.0"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? internalName
    }
}
