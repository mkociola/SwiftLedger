// MARK: - Posting amount parsing

import Foundation

extension JournalParser {
    /// Parses an amount string such as `$100`, `-$50`, `$-50`, `100 USD`, `100.00`.
    func parseAmount(_ raw: String, lineNumber _: Int) throws -> Amount {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.invalidAmount(raw) }

        var str = trimmed
        var sign = Decimal(1)
        if str.hasPrefix("-") {
            sign = -1
            str = String(str.dropFirst())
        } else if str.hasPrefix("+") {
            str = String(str.dropFirst())
        }

        guard let firstChar = str.unicodeScalars.first else { throw LedgerError.invalidAmount(raw) }
        if !CharacterSet.decimalDigits.union(.init(charactersIn: ".")).contains(firstChar) {
            return try parsePrefixCommodityAmount(str, sign: sign, raw: raw)
        }
        return try parseSuffixCommodityAmount(str, sign: sign, raw: raw)
    }

    private func parsePrefixCommodityAmount(_ str: String, sign: Decimal, raw: String) throws -> Amount {
        var commodityEnd = str.endIndex
        for idx in str.indices {
            let char = str[idx]
            if char.isNumber || char == "." || char == "-" || char == "+" {
                commodityEnd = idx
                break
            }
        }
        let commodity = String(str[..<commodityEnd])
        var numStr = String(str[commodityEnd...])
        var adjustedSign = sign
        if numStr.hasPrefix("-") {
            adjustedSign *= -1
            numStr = String(numStr.dropFirst())
        } else if numStr.hasPrefix("+") {
            numStr = String(numStr.dropFirst())
        }
        numStr = numStr.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let quantity = Decimal(string: numStr) else { throw LedgerError.invalidAmount(raw) }
        return Amount(quantity: adjustedSign * quantity, commodity: commodity, commodityIsPrefix: true)
    }

    private func parseSuffixCommodityAmount(_ str: String, sign: Decimal, raw: String) throws -> Amount {
        var end = str.startIndex
        for idx in str.indices {
            let char = str[idx]
            if char.isNumber || char == "." || char == "," {
                end = str.index(after: idx)
            } else {
                break
            }
        }
        let numStr = String(str[..<end]).replacingOccurrences(of: ",", with: "")
        let remainder = String(str[end...]).trimmingCharacters(in: .whitespaces)
        guard let quantity = Decimal(string: numStr) else { throw LedgerError.invalidAmount(raw) }
        let commodity = remainder.isEmpty ? "USD" : remainder
        return Amount(quantity: sign * quantity, commodity: commodity, commodityIsPrefix: false)
    }

    /// The parts a posting's amount field can carry: the amount itself, an
    /// optional price after `@` / `@@`, and an optional balance assertion
    /// after `=`.
    ///
    /// Each part is raw source text, trimmed, for `parseAmount` to interpret.
    /// `amount` is empty when the posting elides it and writes only an
    /// assertion, as `Assets:Cash    = $500.00` does.
    struct AmountField {
        var amount: String
        var price: String?
        var priceIsTotal: Bool
        var assertion: String?
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
    func splitAmountField(_ field: String) -> AmountField {
        guard let operatorIndex = field.firstIndex(where: { $0 == "@" || $0 == "=" }) else {
            return AmountField(amount: trimmedField(field), price: nil, priceIsTotal: false, assertion: nil)
        }
        let amount = trimmedField(field[..<operatorIndex])
        let rest = field[operatorIndex...]
        if rest.first == "=" {
            return AmountField(amount: amount, price: nil, priceIsTotal: false, assertion: assertionText(rest))
        }

        var price = rest.dropFirst()
        let isTotal = price.first == "@"
        if isTotal { price = price.dropFirst() }
        guard let assertionIndex = price.firstIndex(of: "=") else {
            return AmountField(
                amount: amount,
                price: trimmedField(price),
                priceIsTotal: isTotal,
                assertion: nil,
            )
        }
        return AmountField(
            amount: amount,
            price: trimmedField(price[..<assertionIndex]),
            priceIsTotal: isTotal,
            assertion: assertionText(price[assertionIndex...]),
        )
    }

    /// The amount text of a balance assertion whose leading `=` is still attached.
    ///
    /// hledger spells a second, stronger form `==` — an assertion over every
    /// commodity in the account rather than this posting's alone. Both are read
    /// as assertions here: the distinction is not modelled, but reading either
    /// operator as part of the commodity name is what made the file refuse to
    /// load, and that is the failure worth removing first.
    private func assertionText(_ text: Substring) -> String {
        var rest = text.dropFirst()
        if rest.first == "=" { rest = rest.dropFirst() }
        return trimmedField(rest)
    }

    private func trimmedField(_ text: some StringProtocol) -> String {
        String(text).trimmingCharacters(in: .whitespaces)
    }
}
