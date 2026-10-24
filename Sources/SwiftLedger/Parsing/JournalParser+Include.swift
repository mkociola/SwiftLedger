// MARK: - Following `include` lines

import Foundation

extension JournalParser {
    /// What a parse needs beyond the text: the file the text came from, with
    /// a way to read the files it includes and the files that included it,
    /// and the declarations in force where an `include` line reads it.
    ///
    /// Text with no file reads with none of it, which is how `parse(_:)`
    /// keeps an `include` line as a directive.
    struct ParseContext {
        var file: URL?
        var read: ((URL) throws -> String)?
        /// The file being read and every file whose `include` line led to it,
        /// to refuse a file that includes one of its own includers.
        var chain: [URL] = []
        var style = JournalStyleCollector()
        var year: Int?
    }

    /// The reader formats hledger reads through `include` besides the
    /// journal format, by extension or by a `FORMAT:` prefix. hledger 1.52.4
    /// reads no other prefix: `rules:x.csv` and `ledger:x` are file names.
    private static let otherFormats: Set<String> = ["timeclock", "timedot", "csv", "ssv", "tsv"]

    /// Parses the file at `url`, following its `include` lines as hledger
    /// does, and returns its `Journal`.
    ///
    /// An included file's journal sits in the `.include` item of the line
    /// that read it, so each file keeps its own layout and its own `file`,
    /// and an edit is written back to the file it came from. A relative path
    /// is read from the directory of the file holding the line, `~` is the
    /// home directory, and a glob (`*`, `?`, `[...]`, `**`) reads every match
    /// in sorted order, passing over the including file itself. The included
    /// file reads under the `alias`, `apply account`, `Y`, `D`, `commodity`
    /// and `decimal-mark` lines in force at the line, and what it declares
    /// stays in it, but for its `commodity` lines, which hledger keeps in
    /// force below the line.
    ///
    /// - Throws: `LedgerError.unreadableInclude` for a line matching no file
    ///   or a file that cannot be read, since loading without it would show
    ///   balances missing every entry in it; `LedgerError.parseError` for an
    ///   `include` with no path, one that forms a cycle, or one hledger would
    ///   read as CSV, timeclock or timedot, which SwiftLedger does not read;
    ///   `LedgerError.inIncludedFile`, located at the `include` line, for an
    ///   error inside an included file. The top file's own read error is
    ///   thrown as it came.
    public func parse(fileAt url: URL) throws -> Journal {
        try parse(fileAt: url) { try String(contentsOf: $0, encoding: .utf8) }
    }

    /// `parse(fileAt:)` with every file, the top one included, read by
    /// `read`, so the store can record what it read and the manager can
    /// serve the text it is about to save.
    func parse(fileAt url: URL, reading read: @escaping (URL) throws -> String) throws -> Journal {
        let file = url.standardizedFileURL
        return try parse(read(file), in: ParseContext(file: file, read: read, chain: [file])).journal
    }

    /// The item for a line the earlier branches of `parse` left alone: the
    /// line read for what it declares and kept as a `.directive`, or, in a
    /// file, an `include` line with the journals of the files it names.
    func unmodelledItem(
        at index: Int,
        in lines: [String],
        style: inout JournalStyleCollector,
        year: inout Int?,
        context: ParseContext,
    ) throws -> JournalItem {
        try declare(at: index, in: lines, into: &style, year: &year)
        let line = lines[index]
        guard let file = context.file, let read = context.read,
              let argument = try Self.includeArgument(line, lineNumber: index + 1)
        else { return .directive(line) }
        let path = try Self.journalPath(argument, lineNumber: index + 1)
        let matches = Self.includeMatches(path, from: file.deletingLastPathComponent())
        guard !matches.isEmpty else { throw LedgerError.unreadableInclude(argument, reason: "No files were matched") }
        // A glob matching the file it is written in, `*.journal` in a
        // `.journal` file, passes over it, as hledger does.
        let journals = try matches.filter { $0.path != file.path }.map { url in
            guard !context.chain.contains(where: { $0.path == url.path }) else {
                throw LedgerError.parseError(line: index + 1, message: "This included file forms a cycle: \(url.path)")
            }
            let text: String
            do { text = try read(url) } catch {
                throw LedgerError.unreadableInclude(argument, reason: error.localizedDescription)
            }
            let child = ParseContext(
                file: url, read: read, chain: context.chain + [url], style: style.declarations, year: year,
            )
            do {
                let (journal, childStyle) = try parse(text, in: child)
                // hledger keeps an included file's `commodity` lines in force
                // after the `include` line, in this file and in the files it
                // includes next, where every other declaration stays behind.
                style.adoptCommodityDeclarations(of: childStyle)
                return journal
            } catch let error as LedgerError {
                throw LedgerError.inIncludedFile(url.path, underlying: error)
            }
        }
        return .include(IncludedFiles(line: line, journals: journals))
    }

    /// The path an `include` line at the margin names, as written, or `nil`
    /// for any other line. A `;` ends it, however few spaces come before it,
    /// as do the spaces after it; a `#` does not, as hledger reads it.
    private static func includeArgument(_ line: String, lineNumber: Int) throws -> String? {
        let body = line.hasPrefix("!") ? line.dropFirst() : line[...]
        guard body.hasPrefix("include") else { return nil }
        let rest = body.dropFirst("include".count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let argument = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else {
            let message = "include needs a file path or glob pattern argument"
            throw LedgerError.parseError(line: lineNumber, message: message)
        }
        return argument
    }

    /// The path to look for, `journal:` taken off and `~` expanded. A path
    /// hledger reads in another format is refused: reading it as a journal
    /// would misread it, and leaving it out would drop its entries unseen.
    private static func journalPath(_ argument: String, lineNumber: Int) throws -> String {
        var path = argument
        if path.hasPrefix("journal:") {
            path.removeFirst("journal:".count)
        } else {
            let prefix = path.prefix { $0 != ":" }
            let isPrefixed = prefix.count < path.count && otherFormats.contains(String(prefix))
            guard !isPrefixed, !otherFormats.contains((path as NSString).pathExtension.lowercased()) else {
                throw LedgerError.parseError(
                    line: lineNumber,
                    message: "SwiftLedger reads only journal files, and hledger reads \(argument) in another format",
                )
            }
        }
        if path == "~" || path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        return path
    }

    /// The regular files `path` names, read from `directory` when it is
    /// relative, sorted by path, with no file twice.
    ///
    /// A component holding `*`, `?` or `[` is matched against the names in
    /// each directory reached so far with `fnmatch`, `FNM_PERIOD` keeping
    /// `*` off dotfiles as a shell does, and `**` stands for that directory
    /// and every one below it. A directory is never a match.
    static func includeMatches(_ path: String, from directory: URL) -> [URL] {
        var candidates = [path.hasPrefix("/") ? URL(fileURLWithPath: "/") : directory]
        let manager = FileManager.default
        for component in path.split(separator: "/").map(String.init) {
            if component == "**" {
                candidates = candidates.flatMap { [$0] + subdirectories(of: $0) }
            } else if component.contains(where: { "*?[".contains($0) }) {
                candidates = candidates.flatMap { parent in
                    let names = (try? manager.contentsOfDirectory(atPath: parent.path)) ?? []
                    return names.filter { fnmatch(component, $0, FNM_PERIOD) == 0 }.map { parent.appending(path: $0) }
                }
            } else {
                candidates = candidates.map { $0.appending(path: component) }
            }
        }
        let files = candidates.map(\.standardizedFileURL).filter { url in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// Every directory below `directory`, hidden ones left out as `**` leaves
    /// them out in a shell.
    private static func subdirectories(of directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

extension Journal {
    /// A journal of one file, with the layout `style` watched it written in.
    init(items: [JournalItem], style: JournalStyleCollector, lineEnding: LineEnding, file: URL?) {
        self.init(
            items: items,
            commodityFormats: style.formats,
            amountAlignment: style.amountAlignment,
            postingIndent: style.postingIndent,
            lineEnding: lineEnding,
            file: file,
        )
    }
}
