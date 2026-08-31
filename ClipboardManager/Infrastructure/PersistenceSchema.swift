import Foundation
import SwiftData

/// Versioned schema definitions and migration plan for the SwiftData store.
///
/// The store's only model today is `ClipboardEntity`. Declaring an explicit
/// `VersionedSchema` (instead of a bare `Schema([...])`) lets SwiftData record
/// the schema version and lets us add `MigrationStage`s when the model changes
/// in the future, so incompatible on-disk stores can be migrated instead of
/// being silently wiped. V3 is the oldest supported store; older stores follow
/// `PersistenceController`'s backup-and-recreate recovery path.

enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardEntitySchemaV3.ClipboardEntity.self]
    }
}

enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardEntitySchemaV4.ClipboardEntity.self]
    }
}

/// Migration plan describing every schema version this app understands and the
/// stages to move between them. Lightweight migrations add optional fields and
/// leave existing rows with nil values.
enum PersistenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV3.self, SchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: SchemaV3.self,
                toVersion: SchemaV4.self
            )
        ]
    }
}
