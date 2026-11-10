import Foundation

/// A rejected request can be reviewed again. An uncertain write cannot be retried
/// from this sheet because GitHub may already have created the issue.
enum BugReportState: Equatable {
    case composing, preparing
    case reviewing(BugReportDraft), submitting(BugReportDraft)
    case rejected(BugReportDraft, expired: Bool)
    case unconfirmed(BugReportDraft)
    case sent(URL)

    var draft: BugReportDraft? {
        switch self {
        case let .reviewing(draft), let .submitting(draft), let .rejected(draft, _), let .unconfirmed(draft): return draft
        default: return nil
        }
    }
    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
    var message: String? {
        switch self {
        case .rejected(_, expired: true): return "This review expired. Review the report again before publishing."
        case .rejected: return "Your connection or GitHub account needs refreshing. Reconnect if needed, then review again."
        case .unconfirmed: return "Could not confirm whether the issue was created. Check existing issues before submitting again."
        default: return nil
        }
    }

    mutating func submissionFailed(_ error: Error) {
        guard case let .submitting(draft) = self else { return }
        // These responses reject the request before an issue can be created.
        if let status = (error as? CompanionError)?.statusCode, [401, 403, 409, 410].contains(status) {
            self = .rejected(draft, expired: status == 410)
        } else {
            self = .unconfirmed(draft)
        }
    }
}
