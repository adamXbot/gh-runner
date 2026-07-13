# Contributing to Runner Menu

Thanks for helping improve Runner Menu. Small, focused changes with clear tests and rationale are the
easiest to review.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- For a substantial feature or behavior change, open an issue first so the design can be discussed.
- Use a test repository for workflows that register, unregister, start, stop, or update a runner.
- Never post credentials, runner tokens, repository secrets, or unredacted runner logs.

## Development setup

You need macOS 14 or later, a Swift 6-compatible toolchain, and GitHub CLI for integration testing.
Clone the repository, then run:

```bash
./run-tests.sh
swift build
```

Build the app bundle with:

```bash
./build-app.sh
```

The app appears in the menu bar rather than the Dock. Set `RUNNERMENU_DOCK=1` while debugging if you
need a Dock icon.

## Making a change

1. Create a branch from `main`.
2. Keep the change focused and follow the existing Swift and SwiftUI style.
3. Add or update tests for behavior that can be tested without a live GitHub runner.
4. Run `./run-tests.sh` and `swift build -c release`.
5. Exercise relevant items in the README's manual QA checklist for UI or integration changes.
6. Open a pull request that explains the problem, the approach, and the verification performed.

Use short, imperative commit subjects, such as `Handle runner config BOM`.

## Pull requests

Pull requests should:

- Be reasonably scoped and avoid unrelated formatting changes.
- Include tests or explain why automated coverage is not practical.
- Update user-facing documentation when behavior or requirements change.
- Preserve accessibility, dark mode, and increased-contrast support for UI changes.
- Pass the repository's GitHub Actions checks.

By contributing, you agree that your contributions are licensed under the repository's MIT License.

## Reporting security issues

Follow [SECURITY.md](SECURITY.md) and report suspected vulnerabilities privately. Do not open a
public issue with exploit details.
