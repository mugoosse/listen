import CloudKit
import Foundation

/// One sentence a person can act on, for the errors a sync pass actually hits.
///
/// CloudKit's `localizedDescription` is written for developers, and it was the
/// only thing the retrying rows and the Sync pane had to show. The first
/// outside install stalled behind one of these with the reason technically on
/// screen and practically invisible: "Retrying sync" for a day, and the cause
/// (whatever it was) phrased for someone reading a stack trace. Mapped here,
/// once, at the moment the error object still exists: the string then travels
/// through `CloudActivity.detail` and `CloudReport.errors`, so every surface
/// that shows either gets the sentence. The raw description still reaches the
/// trace log at the call sites that log.
///
/// Only the codes a private-database sync can meet and a user can do something
/// about are named. Everything else keeps CloudKit's wording, because a wrong
/// friendly sentence is worse than a stiff accurate one.
public enum SyncTrouble {
    public static func plain(_ error: Error) -> String {
        // `StoreError` already speaks in sentences; see `RecordStore.swift`.
        if error is StoreError { return error.localizedDescription }
        guard let ck = error as? CKError else { return error.localizedDescription }

        // A batch failure names the real problem in its partial errors, and
        // reporting "partial failure" hides it. `batchRequestFailed` entries
        // are the innocent bystanders of the same batch, so the first entry
        // that is anything else is the one that caused it.
        if ck.code == .partialFailure,
           let inner = ck.partialErrorsByItemID?.values.first(where: {
               ($0 as? CKError)?.code != .batchRequestFailed
           }) {
            return plain(inner)
        }

        switch ck.code {
        case .quotaExceeded:
            return "Your iCloud storage is full, so nothing can be sent. "
                 + "Free some space or upgrade the plan and sync catches up on its own."
        case .notAuthenticated:
            return "Sign in to iCloud in System Settings to sync."
        case .networkUnavailable, .networkFailure:
            return "No connection to iCloud right now. Sync retries on its own."
        case .permissionFailure, .managedAccountRestricted:
            return "This iCloud account is not allowed to sync here. "
                 + "A managed or restricted account is usually why."
        case .serviceUnavailable, .zoneBusy, .requestRateLimited:
            return "iCloud is busy. Sync retries on its own."
        case .incompatibleVersion:
            return "This version of Listen is too old for the data in iCloud. Update Listen."
        default:
            return error.localizedDescription
        }
    }
}
