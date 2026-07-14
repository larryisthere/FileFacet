import Foundation

enum DatabaseError: LocalizedError {
    case openFailed
    case statementFailed(String)
    case migrationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            "无法打开应用数据库。"
        case .statementFailed(let operation):
            "数据库操作失败：\(operation)"
        case .migrationFailed(let version):
            "数据库迁移失败：版本 \(version)"
        }
    }
}
