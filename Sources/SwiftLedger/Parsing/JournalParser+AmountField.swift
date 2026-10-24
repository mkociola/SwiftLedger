// MARK: - Splitting a posting's amount field

import Foundation

extension JournalParser {
    /// The parts a posting's amount field can carry: the amount itself, an
    /// optional price after `@` / `@@`, and an optional balance assertion
    /// after `=`, `==`, `=*` or `==*`.
    ///
    /// Each part is raw source text, trimmed, for `parseAmount` to interpret.
    /// `amount` is empty when the posting elides it and writes only an
    /// assertion, as `Assets:Cash    = $500.00` does.
    struct AmountField {
        var amount: String
        var price: String?
        var priceIsTotal: Bool
        var assertion: String?
        var assertionOperator = BalanceAssertionOperator.single
    }

    /// Splits everything written after the account name on a posting line into
    /// its amount, price and balance-assertion parts.
    ///
    /// ledger and hledger write these in one order — `AMOUNT [@|@@ PRICE]
    /// [= ASSERTION]` — so a single left-to-right scan for the first `@` or `=`
    /// finds where the amount stops. A field carrying neither operator comes
    /// back as the amount alone and takes exactly the path it always took;
    /// splitting only ever changes what happens to a line that would otherwise
    /// have had `@ $150.00` swallowed into its commodity name.
    ///
    /// Spacing around the operators is free-form in the source and is not
    /// recorded here: `10 AAPL@$150.00` and `10 AAPL @ $150.00` split alike,
    /// and a posting the serializer has to format is spaced canonically.
    ///
    /// An operator inside double quotes is part of a commodity symbol, as it
    /// is in hledger, so the scan skips a quoted span: `10 "A@B" @ $5.00`
    /// prices ten of `A@B`. Split at the first `@` wherever it stood, the
    /// line was refused over a quote with no partner.
    func splitAmountField(_ field: String) -> AmountField {
        guard let operatorIndex = field.firstIndex(outsideQuotes: { $0 == "@" || $0 == "=" }) else {
            return AmountField(amount: trimmedField(field), price: nil, priceIsTotal: false)
        }
        let amount = trimmedField(field[..<operatorIndex])
        let rest = field[operatorIndex...]
        if rest.first == "=" {
            var field = AmountField(amount: amount, price: nil, priceIsTotal: false)
            (field.assertionOperator, field.assertion) = assertion(rest)
            return field
        }

        var price = rest.dropFirst()
        let isTotal = price.first == "@"
        if isTotal { price = price.dropFirst() }
        guard let assertionIndex = price.firstIndex(outsideQuotes: { $0 == "=" }) else {
            return AmountField(amount: amount, price: trimmedField(price), priceIsTotal: isTotal)
        }
        var field = AmountField(amount: amount, price: trimmedField(price[..<assertionIndex]), priceIsTotal: isTotal)
        (field.assertionOperator, field.assertion) = assertion(price[assertionIndex...])
        return field
    }

    /// The operator and the amount text of a balance assertion whose leading
    /// `=` is still attached.
    ///
    /// hledger reads the operator as `=`, then an optional second `=`, then
    /// an optional `*`, with nothing between them, so `= *$5` is an `=`
    /// followed by an amount that starts with a star, and is refused as one.
    private func assertion(_ text: Substring) -> (BalanceAssertionOperator, String) {
        var rest = text.dropFirst()
        var written = "="
        if rest.first == "=" { rest = rest.dropFirst(); written += "=" }
        if rest.first == "*" { rest = rest.dropFirst(); written += "*" }
        return (BalanceAssertionOperator(rawValue: written) ?? .single, trimmedField(rest))
    }

    private func trimmedField(_ text: some StringProtocol) -> String {
        String(text).trimmingCharacters(in: .whitespaces)
    }
}
