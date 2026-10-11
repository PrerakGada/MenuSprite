import Foundation

/// A Claude Code session that was refused for a usage limit, read from the end of its own transcript.
///
/// Claude Code records the refusal as a synthetic assistant entry with `isApiErrorMessage: true` and
/// `apiError: "usage_limit_reached"`, carrying `quotaLimits` (`rateLimitType`, `resetsAt`). A session
/// that chose "continue automatically" then waits for `resetsAt` on a timer and never re-checks when the
/// login changes underneath it (Claude Code 2.1.296), so after a switch it has to be told to carry on.
public struct LimitWall: Sendable, Equatable {
    public let at: Date
    /// `five_hour`, `seven_day`, or a model-scoped type; nil when the entry did not say.
    public let limitType: String?
    public let resetsAt: Date?

    public init(at: Date, limitType: String?, resetsAt: Date?) {
        self.at = at; self.limitType = limitType; self.resetsAt = resetsAt
    }

    /// The session and weekly windows stop every request on the account; auto-switch acts on these only.
    public var isAccountWide: Bool { limitType == nil || limitType == "five_hour" || limitType == "seven_day" }

    public enum Reading: Sendable, Equatable {
        /// The last thing the session did was hit this wall; nothing has run since.
        case stopped(LimitWall)
        /// The tail shows work after the last wall, or no wall at all.
        case running
        /// The window held only bookkeeping lines; read further back.
        case undecided
    }

    /// Reads a transcript tail newest line first. A real prompt (typed, or Claude Code's own
    /// continuation) or any reply after the wall means the session carried on. Local slash commands
    /// such as `/rate-limit-options`, titles, snapshots and timing lines do not.
    public static func read(tail data: Data) -> Reading {
        let marker = Data("usage_limit_reached".utf8)
        for line in data.split(separator: 0x0A).reversed() {
            // Tool results and long replies are the only big lines: work happened after any wall.
            guard line.count < 65_536 else { return .running }
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "assistant":
                guard line.range(of: marker) != nil, json["isApiErrorMessage"] as? Bool == true,
                      json["apiError"] as? String == "usage_limit_reached" else { return .running }
                return .stopped(wall(json))
            case "user":
                if isLocalCommand(json) { continue }
                return .running
            default:
                continue
            }
        }
        return .undecided
    }

    private static func wall(_ json: [String: Any]) -> LimitWall {
        let quota = (json["quotaLimits"] as? [String: Any])
            ?? ((json["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any])
        let resets = (quota?["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return LimitWall(at: timestamp(json["timestamp"] as? String) ?? .distantPast,
                         limitType: quota?["rateLimitType"] as? String, resetsAt: resets)
    }

    private static func isLocalCommand(_ json: [String: Any]) -> Bool {
        guard let content = (json["message"] as? [String: Any])?["content"] as? String else { return false }
        return content.hasPrefix("<local-command") || content.hasPrefix("<command-")
    }

    private static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
