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
