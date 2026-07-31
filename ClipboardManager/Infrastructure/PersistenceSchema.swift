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
        [ClipboardEntityV1.self]
    }
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardEntitySchemaV2.ClipboardEntity.self]
    }
}

enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardEntitySchemaV3.ClipboardEntity.self]
    }
}

/// Migration plan describing every schema version this app understands and the
/// stages to move between them. Lightweight migrations add optional fields and
/// leave existing rows with nil values.
enum PersistenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: SchemaV1.self,
                toVersion: SchemaV2.self
            ),
            MigrationStage.lightweight(
                fromVersion: SchemaV2.self,
                toVersion: SchemaV3.self
            )
        ]
    }
}
