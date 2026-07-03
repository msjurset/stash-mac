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

## Performance Constraints & Safeguards

When working with high-frequency rendering and layout inside SwiftUI (specifically complex `Canvas` draws inside ScrollViews like in `XRayAudioView`), strictly adhere to the following optimizations to prevent "beachballing" and main-thread starvation:

1. **State Isolation for High-Frequency Events**: Never bind high-frequency events (like `.onContinuousHover` cursor coordinates) directly to a root view's `@State`. Always isolate them in a separate `@Observable` object (e.g., `XRayHoverState`). This prevents SwiftUI from regenerating massive view hierarchies (like `ScrollView`) every time the mouse moves.
2. **Hover Coalescing**: Do NOT wrap `.onContinuousHover` state mutations in `DispatchQueue.main.async`. Doing so defeats SwiftUI's native run-loop coalescing and will flood the main thread with thousands of un-cancellable tasks during rapid scrolls. Let the updates run synchronously so SwiftUI can batch them per frame.
3. **Threshold Guarding**: Always implement delta-thresholding for pointer tracking. For instance, if you only care about horizontal tracking, ensure `abs(current - new) > 0.5` before committing the state to avoid meaningless invalidations from vertical scrolling or floating-point drift.
4. **Hardware Acceleration**: Always add `.drawingGroup()` to `Canvas` wrappers that generate thousands of paths (e.g., waveforms) to opt-in to Metal GPU acceleration. Relying on default CPU rendering will cause stutters on dense views.
5. **Draw Loop Allocations**: When building large arrays (like `[CGRect]` for paths) inside a frame draw loop, ALWAYS use `.reserveCapacity()` before the loop to prevent Swift from stalling the thread with dynamic memory re-allocations mid-draw.
6. **No Dictionary Hashing in Hot Loops**: Never use SwiftUI `Color` as a dictionary key inside a rendering loop (e.g., grouping rects by color). `Color` hashing is extremely expensive. Use an indexed `Array` instead.
7. **Consolidate Path Generation**: If a view requires both a `.fill` pass and a `.stroke` pass over the same dataset, consolidate them into a single iteration block to halve the math overhead.
