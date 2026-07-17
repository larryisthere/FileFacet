import Foundation

enum AppConfiguration {
    static let internalName = "FileFacet"
    static let bundleIdentifier = "com.larryisthere.video-tag-manager"
    static let minimumSystemVersion = "14.0"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? internalName
    }

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return "版本 \(version)（构建 \(build)）"
        case let (.some(version), .none):
            return "版本 \(version)"
        case let (.none, .some(build)):
            return "构建 \(build)"
        case (.none, .none):
            return "版本信息不可用"
        }
    }
}
