import Foundation
import SwiftData

/// Versioned schema definitions and migration plan for the SwiftData store.
///
/// The store's only model today is `ClipboardEntity`. Declaring an explicit
/// `VersionedSchema` (instead of a bare `Schema([...])`) lets SwiftData record
/// the schema version and lets us add `MigrationStage`s when the model changes
/// in the future, so incompatible on-disk stores can be migrated instead of
/// being silently wiped.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardEntity.self]
    }
}

/// Migration plan describing every schema version this app understands and the
/// stages to move between them. Currently only `SchemaV1` exists, so there are
/// no migration stages yet. Add `MigrationStage.custom(...)` /
/// `.lightweight(...)` entries here when a new `SchemaV*` is introduced.
enum PersistenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}
