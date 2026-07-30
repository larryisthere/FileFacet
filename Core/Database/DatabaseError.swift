import Foundation

enum DatabaseError: LocalizedError {
    case openFailed
    case statementFailed
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .openFailed:
            String(localized: .errorDatabaseOpen)
        case .statementFailed:
            String(localized: .errorDatabaseOperation)
        case .migrationFailed:
            String(localized: .errorDatabaseMigration)
        }
    }
}
