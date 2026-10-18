// MARK: - A commodity symbol in double quotes

import Foundation

extension JournalParser {
    /// Reads the symbol inside the double quotes `text` opens with, and hands
    /// back what follows the closing quote: `"Mutual Fund" 10` is the symbol
    /// `Mutual Fund` and the rest ` 10`. `nil` when `text` opens with no
    /// quote, which leaves the bare grammar to read it. A quote with no
    /// partner is refused, as hledger refuses it, naming the amount as the
    /// file wrote it. Nothing between the quotes is a symbol of nothing,
    /// which the caller reads as hledger reads it: the number is bare.
    ///
    /// hledger's rule: a symbol holding a space, a digit or punctuation is
    /// written in double quotes, and the quotes are no part of the name, so
    /// `10 "Mutual Fund"` is ten units of `Mutual Fund` and `10 "USD"` is ten
    /// `USD`. Read with the quotes kept, as they used to be, the fund was a
    /// commodity nobody could query by name, and the moment an entry was
    /// rebuilt with the bare name the account split in two (issue #38). What
    /// stands between the quotes is not policed here: a `;` has opened the
    /// comment before the amount is read, in hledger as here, and a line
    /// break has ended the line, so neither can reach this.
    static func quotedSymbol(opening text: Substring, raw: String) throws -> (symbol: String, rest: Substring)? {
        guard text.first == "\"" else { return nil }
        let content = text.dropFirst()
        guard let closing = content.firstIndex(of: "\"") else { throw LedgerError.invalidAmount(raw) }
        return (String(content[..<closing]), content[content.index(after: closing)...])
    }

    /// The symbol as a posting line writes it: in double quotes when it holds
    /// a character a bare symbol cannot, bare otherwise.
    ///
    /// The characters are the ones hledger's `print` quotes for, a digit,
    /// whitespace, or one of `-+.@*{}=`, and the comma, which opens a number
    /// here where hledger reads it as part of a bare symbol. Quoting a symbol
    /// hledger would write bare costs nothing, since it reads the quoted form
    /// the same, where a bare symbol it does not read leaves a file it
    /// refuses. The quote and the `;` are not in the list because no quoting
    /// writes them; `Transaction.init` refuses a symbol holding either.
    static func written(symbol: String) -> String {
        let needsQuotes = symbol.contains { $0.isASCIIDigit || $0.isWhitespace || quotedPunctuation.contains($0) }
        return needsQuotes ? "\"\(symbol)\"" : symbol
    }

    private static let quotedPunctuation: Set<Character> = ["-", "+", ".", ",", "@", "*", "{", "}", "="]
}

extension StringProtocol {
    /// The first character satisfying `predicate` that stands outside double
    /// quotes, or `nil`. What a quoted symbol holds is the symbol's, so a
    /// scan for an operator or a digit on the line skips it.
    func firstIndex(outsideQuotes predicate: (Character) -> Bool) -> Index? {
        var quoted = false
        // The label is spelled out: a trailing closure here resolves to this
        // very method, and the scan recursed until the stack ran out.
        return firstIndex(where: { character in
            if character == "\"" { quoted.toggle() }
            return !quoted && predicate(character)
        })
    }
}
