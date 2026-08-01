# Remaining Features

## Architecture status

The current refactoring has lightweight history-list DTOs, lazy payload access,
repository-mediated persistence, presentation view models, and coordinators owned by
`AppContainer`. Main and settings window construction is delegated to their window
coordinators. The SwiftData schema and migration plan are unchanged.

## Remaining product work

Deferred product decisions remain tracked exclusively in `docs/open-questions.md`.
No new user-visible behavior was introduced by the architecture refactoring.

## Remaining test engineering

The current architecture and isolation contract are documented in
`docs/testing.md`; this section tracks only work that is not implemented yet.

- Expand the SwiftPM unit/contract suite beyond its current view-model, paste
  orchestration, validator, history-filter, and formatting coverage.
- Add infrastructure integration tests for temporary SwiftData stores, named
  pasteboards, process timeout/failure handling, limits, and migrations.
- Run `swift build` and the deterministic test layers on pull requests. Keep
  XCUITest local-only until its signing and Accessibility requirements have a
  dedicated runner.
- Add a production-bundle packaging smoke check for the important Info.plist
  keys and menu-bar launch configuration.
- Split the long Macro XCUITest workflow and the single smoke-test source file
  when changing those workflows; preserve stable accessibility identifiers and
  replace remaining fixed UI propagation waits with bounded state polling where
  an observable state is available.
