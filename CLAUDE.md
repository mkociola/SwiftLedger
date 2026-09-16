# SwiftLedger

Read `CONTRIBUTING.md` first. It holds the development setup and the rules
below in full.

- Run `swift test` and `pre-commit run --all-files` before committing. CI runs
  both, plus a Conventional Commits check on the commit messages and the PR
  title.
- A change to what the parser reads or the serializer writes also adds an entry
  to `Examples/sample.ledger` and an assertion in
  `Tests/SwiftLedgerTests/ExampleJournalTests.swift`. See "The example journal"
  in `CONTRIBUTING.md` for the layout rules the file has to keep.
- Doc comments explain the why in full sentences. Match the voice of the file
  you are editing.
