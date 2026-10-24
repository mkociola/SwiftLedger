import Foundation

/// The `alias` and `apply account` lines in force at a point of a journal,
/// and what they make of an account name written there.
///
/// hledger books a posting, and declares an `account` line, under the name
/// these directives give it rather than the one the line writes: under
/// `apply account Personal` the line `Expenses:Rent` posts to
/// `Personal:Expenses:Rent`, and under `alias checking = Assets:Checking` the
/// line `checking` posts to `Assets:Checking`. Read as written, every such
/// posting landed in an account of its own, typed `.unclassified`, and
/// missed every report (issue #44).
///
/// The file keeps the name it wrote, so the parser records that name beside
/// the booked one and the serializer writes it back (`spelling(of:written:)`).
/// It lives on `JournalStyleCollector` because that is what
/// `JournalParser.declare(at:in:into:year:)` keeps for the parser and the
/// serializer alike, so both read the directives in force where an entry
/// stands the same way.
struct AccountNameRewrites {
    /// One `alias` line.
    enum Alias {
        /// `alias OLD = NEW`: the name `OLD`, and every name under it.
        case name(old: String, new: String)
        /// `alias /PATTERN/ = NEW`, with `NEW` already turned into a template.
        case pattern(NSRegularExpression, template: String)

        func rewrite(_ name: String) -> String {
            switch self {
            case let .name(old, new):
                if name == old { return new }
                return name.hasPrefix(old + ":") ? new + name.dropFirst(old.count) : name
            case let .pattern(regex, template):
                let range = NSRange(name.startIndex..., in: name)
                return regex.stringByReplacingMatches(in: name, range: range, withTemplate: template)
            }
        }
    }

    /// Every `alias` line since the last `end aliases`, the oldest first.
    var aliases: [Alias] = []
    /// The names of the `apply account` blocks open here, the outermost first.
    var parents: [String] = []

    /// The account a name written here is booked under, as hledger reads it:
    /// the open blocks' names go in front, outermost first, and then every
    /// alias rewrites the result of the one before it, the latest first.
    /// This runs on every posting a file parses, and most files hold neither
    /// directive, so a name with nothing in force is handed back untouched
    /// rather than joined into a copy of itself.
    func booked(_ name: String) -> String {
        guard !aliases.isEmpty || !parents.isEmpty else { return name }
        return aliases.reversed().reduce((parents + [name]).joined(separator: ":")) { $1.rewrite($0) }
    }

    /// What to write here for an account booked as `name`: the name the file
    /// wrote it under, when there is one and it still books `name` here, or
    /// else the name without the open blocks' prefix, or the name itself.
    ///
    /// The written name is what keeps a rebuilt entry in the file's own
    /// vocabulary. It may not book `name` where the entry now stands, after
    /// an edit moved it past `end aliases`, and a posting built in code has
    /// none: written as booked under `apply account Personal`, its
    /// `Personal:Expenses:Food` came back from the next parse as
    /// `Personal:Personal:Expenses:Food`. An alias cannot be undone in
    /// general, so a name no spelling books here is written as `written`, or
    /// as booked, and reads back as whatever the directives make of it.
    func spelling(of name: String, written: String?) -> String {
        let prefix = parents.map { $0 + ":" }.joined()
        let unprefixed = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
        return [written, unprefixed, name].compactMap(\.self).first { booked($0) == name } ?? written ?? name
    }
}

extension JournalParser {
    /// Reads an `alias`, `end aliases`, `apply account` or `end apply account`
    /// line at the margin into `names`, and leaves any other line alone.
    ///
    /// hledger refuses an alias with no `=`, one whose pattern does not
    /// compile, an `apply account` line with no name or with two spaces in
    /// it, and an `end apply account` with no block open, and so does this,
    /// with `LedgerError.unreadableDirective`: kept as a line nobody reads,
    /// each would leave every posting below it booked under a name hledger
    /// does not book it under. The line itself is kept verbatim like any
    /// other directive.
    func declareAccountNames(from line: String, into names: inout AccountNameRewrites) throws {
        let words = line.split(whereSeparator: \.isWhitespace)
        switch (words.first ?? "", words.dropFirst().first ?? "") {
        case ("alias", _):
            try names.aliases.append(Self.alias(from: line.dropFirst("alias".count), line: line))
        case ("end", "aliases"):
            names.aliases = []
        case ("apply", "account"):
            let parent = line.dropFirst("apply".count).drop(while: \.isWhitespace)
                .dropFirst("account".count).trimmingCharacters(in: .whitespaces)
            guard !parent.isEmpty, !parent.contains("  "), !parent.contains("\t") else {
                throw LedgerError.unreadableDirective(line, reason: "it takes one account name")
            }
            names.parents.append(parent)
        case ("end", "apply") where words.dropFirst(2).first == "account":
            guard names.parents.popLast() != nil else {
                throw LedgerError.unreadableDirective(line, reason: "no apply account block is open")
            }
        default:
            return
        }
    }

    /// Reads what follows the `alias` keyword: `OLD = NEW`, or `/PATTERN/ =
    /// NEW`, where the pattern ends at the first `/` an `=` follows, so that
    /// a `/` or an `=` inside it is the pattern's.
    private static func alias(from rest: Substring, line: String) throws -> AccountNameRewrites.Alias {
        let rest = rest.drop { $0 == " " || $0 == "\t" }
        let unreadable = { LedgerError.unreadableDirective(line, reason: $0) }
        if rest.first == "/" {
            let body = rest.dropFirst()
            let close = body.indices.first {
                body[$0] == "/" && body[body.index(after: $0)...].drop { $0 == " " || $0 == "\t" }.first == "="
            }
            guard let close else { throw unreadable("it takes /PATTERN/ = NEW") }
            let replacement = body[body.index(after: close)...].drop { $0 != "=" }.dropFirst()
            guard let regex = try? NSRegularExpression(pattern: String(body[..<close]), options: .caseInsensitive)
            else { throw unreadable("its pattern is not a regular expression") }
            // hledger writes a group `\1`, where a template writes `$1` and
            // reads `\` and `$` as its own, so both are escaped first.
            let template = NSRegularExpression.escapedTemplate(for: replacement.trimmingCharacters(in: .whitespaces))
                .replacingOccurrences(of: #"\\\\(\d)"#, with: "\\$$1", options: .regularExpression)
            return .pattern(regex, template: template)
        }
        let equals = rest.firstIndex(of: "=")
        let old = rest[..<(equals ?? rest.startIndex)].trimmingCharacters(in: .whitespaces)
        guard let equals, !old.isEmpty else { throw unreadable("it takes OLD = NEW") }
        return .name(old: old, new: rest[rest.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }
}
