/// How a journal ends its lines.
///
/// The raw value is the ending itself, as it is written to the file. A file
/// ends its lines with one or the other, and which one it uses says nothing
/// about what the journal records, so it is layout in the same sense
/// as the posting indent and the amount margin. `JournalParser` learns it
/// and `JournalSerializer` writes it back: an entry rebuilt in a journal
/// kept on Windows would otherwise be the only lines in the file ending in a
/// bare `\n`, which is a change nobody asked for, in the one entry the user
/// edited, drawn by most diff tools as every one of its lines changed.
///
/// A lone `\r`, the classic Mac ending, is not a case. Nothing reading this
/// format ends a line on it, and a journal written that way does not load.
public enum LineEnding: String, Sendable {
    /// `\n`: what a journal built in code is written with, and what every
    /// journal SwiftLedger wrote before it learned the ending was.
    case unix = "\n"
    /// `\r\n`.
    case windows = "\r\n"
}
