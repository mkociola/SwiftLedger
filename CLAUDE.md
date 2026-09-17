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
- A change to how the parser reads a journal also removes every name from
  `knownDivergences` in `Tests/SwiftLedgerTests/HledgerConformanceTests.swift`
  that it makes pass, and pins new behaviour with a journal under
  `Tests/SwiftLedgerTests/Conformance/` plus fixtures from
  `Scripts/hledger-fixtures.sh`. See "hledger conformance" in `CONTRIBUTING.md`.
- Doc comments explain the why in full sentences. Match the voice of the file
  you are editing.
