import Foundation
import SwiftUI

// Mirrors scripts/_sync.py Status enum. Wire values must stay in sync with
// the Python side; see scripts/_sync.py:418.
//
// `notClonedYet` is synthetic — never emitted by the Python. The
// InventoryStore uses it for repos the API knows about but that we
// don't have a local clone of yet.
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
    case notClonedYet  = "not-cloned-yet"   // synthetic; inventory-only
    case notSyncedYet  = "not-synced-yet"   // synthetic; on disk, no sync data

    var isAnomaly: Bool {
        switch self {
        case .updatedDirty, .dirty, .diverged, .branchMissing,
             .staleOnDisk, .nonGitDir, .error:
            return true
        case .cloned, .updated, .upToDate, .emptyRemote, .skipped, .notClonedYet,
             .notSyncedYet:
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
        case .notClonedYet:                              return "icloud.and.arrow.down"
        case .notSyncedYet:                              return "circle.dashed"
        }
    }

    // SwiftUI semantic color — adapts automatically in Dark Mode.
    var color: Color {
        switch self {
        case .cloned, .updated, .upToDate:    return .green
        case .emptyRemote:                    return .secondary
        case .updatedDirty, .dirty:           return .yellow
        case .diverged, .branchMissing:       return .orange
        case .staleOnDisk, .nonGitDir:        return .orange
        case .skipped:                        return .secondary
        case .error:                          return .red
        case .notClonedYet:                   return .blue
        case .notSyncedYet:                   return .gray
        }
    }

    // Tooltip / hover-explainer text. Useful for the inventory's status
    // pill so the user doesn't have to remember what each value means.
    var explanation: String {
        switch self {
        case .cloned:        return "Freshly cloned from the remote."
        case .updated:       return "Local branch fast-forwarded to the new remote tip."
        case .updatedDirty:  return "Fast-forwarded over uncommitted changes on paths that didn't collide."
        case .upToDate:      return "Already in sync with the remote; nothing to do."
        case .emptyRemote:   return "Remote has no refs (empty repository)."
        case .dirty:         return "Working tree has uncommitted changes; sync was blocked to protect them."
        case .diverged:      return "Local has commits not on the remote, or is checked out to a non-default branch."
        case .branchMissing: return "The remote no longer has the default branch this repo was tracking."
        case .staleOnDisk:   return "Repo exists locally but the remote doesn't list it anymore (deleted, renamed, or transferred)."
        case .nonGitDir:     return "Directory under the sync root with no .git inside — not managed by GitSync."
        case .skipped:       return "Matched a pattern in GIT_SYNC_SKIP."
        case .error:         return "Network, auth, or other failure during sync. See the log for details."
        case .notClonedYet:  return "Remote knows about this repo; it hasn't been cloned locally yet."
        case .notSyncedYet:  return "Found on disk, but no sync has recorded its status yet. Run a sync to populate it."
        }
    }
}
