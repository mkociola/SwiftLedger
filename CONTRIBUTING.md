# Contributing

## Development setup

### Pre-commit hooks

This project uses [pre-commit](https://pre-commit.com)

Install [uv](https://docs.astral.sh/uv/) if you don't have it:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Install pre-commit with the [pre-commit-uv](https://github.com/thibaudcolas/pre-commit-uv) backend:

```bash
uv tool install pre-commit --with pre-commit-uv
```

Install the git hooks:

```bash
pre-commit install
```

Hooks run automatically on `git commit`. To run them manually across all files:

```bash
pre-commit run --all-files
```

> The first run will be slower while pre-commit bootstraps its hook environments.

### Tests

```bash
swift test
```

## The example journal

`Examples/sample.ledger` is the journal the README points a reader at, and
`Tests/SwiftLedgerTests/ExampleJournalTests.swift` reads it straight from the
repository, so editing the file is enough to test it. Any change to what the
parser reads or the serializer writes comes with both:

- an entry in the example, under a commented section that says what the entry
  shows and why it is valid, laid out from what the file already shows: amounts
  start at the same column and the negative sign sits on the same side of the
  commodity, because the file teaches SwiftLedger the style it rebuilds entries
  in;
- an assertion in the `example journal` suite that the entry parses to what its
  comment claims, so the example cannot drift from the parser unnoticed.

The example has to keep parsing and serialising byte for byte, and any balance
assertion it carries has to be the balance its own entries produce, because the
library preserves assertions without checking them.

## hledger conformance

hledger is the reference for how a journal is read. The journals under
`Tests/SwiftLedgerTests/Conformance/` are each kept beside what hledger made
of them, and `HledgerConformanceTests` reads every journal with
`JournalParser` and compares the two: every transaction, posting, amount,
cost and assertion, then the flat balance report. A journal hledger refuses
has to be refused too.

The tests never run hledger. The fixtures are generated once and committed:

```bash
brew install hledger jq
Scripts/hledger-fixtures.sh
```

The script writes `NAME.print.json` and `NAME.balance.json` for a journal
hledger reads, or `NAME.error.txt` for one it refuses, and records the hledger
version in `hledger-version.txt`. CI regenerates them and fails if the
committed files differ, so a fixture cannot be edited by hand and a new
hledger release that reads a journal differently shows up as a diff.

A journal SwiftLedger is known to read differently is named in
`knownDivergences` at the top of the test. Its case then passes only while the
divergence remains, so fixing one means removing its name, and the list is the
distance to hledger the repository currently admits to.

To pin down a behaviour: write the smallest journal that shows it, run the
script, commit the fixtures, and add the name to `knownDivergences` if the
test fails. A file whose name starts with `_` is a part other journals
`include`, not a case of its own.
