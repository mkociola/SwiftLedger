/// Indicates whether a transaction or posting has been reviewed/cleared.
public enum ClearingStatus: String, Sendable, Codable, Hashable {
    /// No mark — not yet reviewed.
    case unmarked = ""
    /// `!` — flagged / pending review.
    case pending  = "!"
    /// `*` — cleared / reconciled.
    case cleared  = "*"
}
