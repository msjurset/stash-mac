# Project Rules

- Do not add any Gemini or Anthropic authorship references (Co-Authored-By, comments, documentation, commit messages, or otherwise) anywhere in this project.

# Build & Test

- Build: `swift build` or `make build` (release)
- Test: `swift test` or `make test`
- Deploy: `make deploy` (builds, bundles, installs to /Applications)
- Generate Xcode project: `swift package generate-xcodeproj`

# Architecture

Stash Mac is a SwiftUI frontend for the `stash` CLI. All data operations are delegated to the CLI binary via `Process` — the app does not store data itself. The core principle: delegate to the CLI, never reimplement the storage engine.

- Uses Swift 6.0 Testing framework (`@Test`, `#expect`), not XCTest
- macOS 15.0+ only, no external dependencies
- `@Observable` + `@MainActor` for state management

# Maintenance Rules

When source code changes, the following files must be kept in sync:

## View/Feature Changes
When views or features are added or modified:
- Update the README.md features list
- Update the help content in `Views/Help/HelpContent.swift` (add/update relevant topic)
- Add contextual `ContextualHelpButton` to new views where appropriate
- Update keyboard shortcuts topic if new shortcuts are added

## Model Changes
When data models are modified:
- Ensure JSON decoding alignment with the `stash` CLI's output format
- Update `StashStore` if the model change affects state management
- Update `ItemDetailView` if display fields change
- Add or update tests in `Tests/StashMacTests/`

## CLI Integration Changes
When CLI commands or arguments change:
- Update methods in `Services/StashCLI.swift`
- Update the "CLI Integration" help topic in `HelpContent.swift`
- Update the README.md Architecture section

## Dependency Changes
When dependencies are added, removed, or updated:
- Update the NOTICES file with the dependency's license information
- For removed dependencies, remove their entry from NOTICES

## Build/Release Changes
When build targets, supported platforms, or release artifacts change:
- Update the Makefile accordingly
- Update GitHub Actions workflows if the build process changed
- Update the README.md install/build sections if instructions changed

## Function/API Changes
When exported or public functions/computed properties are added or modified:
- Add or update corresponding unit tests to cover the new/changed behavior
- Test edge cases, error paths, and boundary conditions
