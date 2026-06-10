import Foundation

// Mirrors scripts/_sync.py Status enum. Wire values must stay in sync with
// the Python side; see scripts/_sync.py:418.
enum SyncStatus: String, Codable, CaseIterable, Sendable {
    case cloned        = "cloned"
    case updated       = "updated"
    case updatedDirty  = "updated-dirty"
    case upToDate      = "up-to-date"
    case emptyRemote   = "empty-remote"
    case dirty         = "dirty"
    case diverged      = "diverged"
    case branchMissing = "branch-missing"
    case staleOnDisk   = "stale-on-disk"
    case nonGitDir     = "non-git-dir"
    case skipped       = "skipped"
    case error         = "error"

    var isAnomaly: Bool {
        switch self {
        case .updatedDirty, .dirty, .diverged, .branchMissing,
             .staleOnDisk, .nonGitDir, .error:
            return true
        case .cloned, .updated, .upToDate, .emptyRemote, .skipped:
            return false
        }
    }

    var displayName: String {
        rawValue
    }

    var sfSymbol: String {
        switch self {
        case .cloned, .updated, .upToDate, .emptyRemote: return "checkmark.circle"
        case .updatedDirty, .dirty:                      return "pencil.circle"
        case .diverged:                                  return "arrow.triangle.branch"
        case .branchMissing:                             return "questionmark.circle"
        case .staleOnDisk:                               return "tray.full"
        case .nonGitDir:                                 return "folder.badge.questionmark"
        case .skipped:                                   return "minus.circle"
        case .error:                                     return "xmark.octagon"
        }
    }
}
