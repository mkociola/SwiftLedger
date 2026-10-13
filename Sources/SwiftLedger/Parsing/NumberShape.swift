// MARK: - The written shape of a number

/// The written shape of one amount: what its digits looked like before
/// `Decimal` normalised them away.
///
/// Filled in by the scan that reads the value, never by a second pass over the
/// text, so that the shape and the quantity can never disagree about which
/// mark divided the fraction. A file written `1.000,00` shows two fraction
/// digits and groups its thousands; reading that text again against the
/// assumption that `.` always divides, as this used to, records five fraction
/// digits and no grouping, and every amount written back into the file
/// inherits the mistake.
struct NumberShape {
    /// How many digits followed the decimal mark.
    var fractionDigits: Int
    /// Whether the integer part was written in digit groups.
    var usesSeparator: Bool
    /// Whether the integer part is long enough for a group mark to have been
    /// visible at all.
    var canShowGrouping: Bool
    /// The character that divided the fraction, as the number was read: `,`
    /// in `1.000,00`, `.` in `1,000.00`, `nil` when it wrote no such mark.
    var decimalMark: Character?
    /// The character that separated the digit groups, on the same terms: `.`
    /// in `1.000,00`, `,` in `1,000.00`, `nil` in `1.000`.
    var groupMark: Character?
    /// Whether the number itself or a directive above it settled which mark
    /// was which, rather than the tie-break settling it for the number.
    ///
    /// False for the one shape no number can settle on its own, a mark with
    /// exactly three digits after it, when no directive above it settled it
    /// either. `1,000` and `1.000` still get the value the scanner has always
    /// given them, and the marks above say what that reading was, but the
    /// collector makes them abstain on the question of which convention the
    /// file follows: one `€12,50` says more about that than a page of `€1.000`
    /// does. Settled by a directive, the same number votes.
    var isSettled: Bool
}
