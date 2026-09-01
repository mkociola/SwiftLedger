import Foundation

/// How a journal lines its posting amounts up.
///
/// Two conventions are in common use and the difference is visible in any file
/// that holds a negative amount:
///
/// ```
/// Expenses:Groceries                       $1,240.50     <- ends at the same
/// Assets:Checking                         $-1,240.50        column, .end
///
/// Expenses:Groceries                       $1,240.50     <- begins at the same
/// Assets:Checking                          $-1,240.50       column, .start
/// ```
///
/// SwiftLedger has always written the second, at column 52. Imposing it on a
/// file that uses the first shifts every rebuilt posting by the width of its
/// own sign — a change nobody asked for, in the one entry the user edited.
/// `JournalParser` therefore records which convention a file follows and
/// `JournalSerializer` writes it back.
public enum AmountAlignment: Sendable, Codable, Hashable {
    /// Amount fields begin at this column.
    case start(column: Int)
    /// Amount fields end at this column, so their last characters line up.
    case end(column: Int)
}
