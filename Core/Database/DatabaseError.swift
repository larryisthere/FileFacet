import Foundation

enum DatabaseError: LocalizedError {
    case openFailed
    case statementFailed
    case migrationFailed
    case relinkConfirmationRequired
    case relinkExistingRecord(videoID: String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            String(localized: .errorDatabaseOpen)
        case .statementFailed:
            String(localized: .errorDatabaseOperation)
        case .migrationFailed:
            String(localized: .errorDatabaseMigration)
        case .relinkConfirmationRequired:
            String(
                localized: "error.relinkConfirmationRequired",
                defaultValue: "The selected file requires confirmation before it can be linked."
            )
        case .relinkExistingRecord:
            String(
                localized: "error.relinkExistingRecord",
                defaultValue: "The selected file already belongs to another video."
            )
        }
    }
}
