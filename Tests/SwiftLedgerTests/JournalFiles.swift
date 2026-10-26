import Foundation
@testable import SwiftLedger

/// A fresh directory of journal files for one test, so that a journal which
/// includes others can be read from disk the way a user's journal is.
/// `remove()` belongs in a `defer` right after the directory is made.
struct JournalFiles {
    let directory: URL

    /// Writes each file under its relative path, making the directories a
    /// path names.
    init(_ files: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory).standardizedFileURL
        for (name, text) in files {
            try write(name, text)
        }
    }

    func url(_ name: String) -> URL {
        directory.appending(path: name).standardizedFileURL
    }

    func write(_ name: String, _ text: String) throws {
        let file = url(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    func parse(_ name: String) throws -> Journal {
        try JournalParser().parse(fileAt: url(name))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
