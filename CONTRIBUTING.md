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
