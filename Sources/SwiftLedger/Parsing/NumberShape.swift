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
}
