# Remaining Features

## Architecture status

The current refactoring has lightweight history-list DTOs, lazy payload access,
repository-mediated persistence, presentation view models, and coordinators owned by
`AppContainer`. Main and settings window construction is delegated to their window
coordinators. The SwiftData schema and migration plan are unchanged.

## Remaining product work

Deferred product decisions remain tracked exclusively in `docs/open-questions.md`.
No new user-visible behavior was introduced by the architecture refactoring.
