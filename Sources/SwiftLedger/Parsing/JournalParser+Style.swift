// MARK: - Reading a journal's own layout and declared display styles

import Foundation

extension JournalParser {
    /// Reads the display style a `D` or `commodity` directive states, if the
    /// line is one.
    ///
    /// ledger and hledger both spell a style as a sample amount, in three
    /// places: `D $1,000.00`, the one-line `commodity $1,000.00`, and the
    /// indented `format $1,000.00` inside a `commodity` block. An indented line
    /// can only reach here from such a block — the ones inside a transaction
    /// are consumed with it — so no block tracking is needed to tell them
    /// apart.
    ///
    /// Anything that does not parse as an amount is left alone. A directive
    /// SwiftLedger misreads here costs nothing but the guess: the line itself
    /// is still written back verbatim.
    func declareFormat(from line: String, into style: inout JournalStyleCollector) {
        let isIndented = line.first == " " || line.first == "\t"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let keyword = ["D ", "commodity ", "format "].first { trimmed.hasPrefix($0) }
        guard let keyword else { return }
        guard keyword != "format " || isIndented else { return }

        let sample = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        // `commodity $` names a commodity without stating a style; only the
        // sample-amount forms say anything to record.
        guard sample.contains(where: \.isNumber),
              let amount = try? parseAmount(sample, lineNumber: 0),
              !amount.commodity.isEmpty else { return }
        style.declare(sample, commodity: amount.commodity)
    }

    /// The column `line`'s amount field starts at: past the account name, past
    /// the run of two or more spaces that ends it.
    ///
    /// Measured on the original line, indentation included, because that is
    /// what a column is. Characters, not display width — a tab counts once,
    /// which is what the serializer will write against anyway.
    static func amountColumn(in line: String, after accountName: String) -> Int? {
        guard !accountName.isEmpty, let account = line.range(of: accountName) else { return nil }
        var index = account.upperBound
        var spaces = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            spaces += 1
            index = line.index(after: index)
        }
        guard spaces >= 2, index < line.endIndex else { return nil }
        return line.distance(from: line.startIndex, to: index)
    }
}
