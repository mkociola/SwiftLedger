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
///
/// What lines up either way is the amount, and a `@ price` or `= assertion`
/// trails past the column, which is how hledger lays a posting out. Both ends
/// of this hold to that: the parser measures a line's amount and nothing
/// after it, and the serializer pads to the same thing.
public enum AmountAlignment: Sendable, Codable, Hashable {
    /// Amounts begin at this column.
    case start(column: Int)
    /// Amounts end at this column, so their last digits line up.
    case end(column: Int)
}
