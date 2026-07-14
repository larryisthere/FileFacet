import OSLog

enum AppLogger {
    static let lifecycle = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "lifecycle")
    static let database = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "database")
    static let library = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "library")
    static let security = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "security")
}
