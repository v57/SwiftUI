// SQLite3 stand-in (Linux, Windows, Android): the SQLite C API as Apple's SQLite3 module has it, from the system's
// SQLite on Linux and the toolchain's own build (swift-toolchain-sqlite) elsewhere, so `import SQLite3` code builds
// unchanged.
#if os(Linux)
@_exported import CSQLite3System
#else
@_exported import SwiftToolchainCSQLite

// The toolchain's SQLite is built without SQLITE_ENABLE_COLUMN_METADATA (Apple's has it): the header declares
// these, but nothing defines them. Defined here, they know no column's origin (as for an expression column).
@_cdecl("sqlite3_column_table_name")
func _sqlite3ColumnTableName(_ statement: OpaquePointer?, _ column: Int32) -> UnsafePointer<CChar>? { nil }

@_cdecl("sqlite3_column_database_name")
func _sqlite3ColumnDatabaseName(_ statement: OpaquePointer?, _ column: Int32) -> UnsafePointer<CChar>? { nil }

@_cdecl("sqlite3_column_origin_name")
func _sqlite3ColumnOriginName(_ statement: OpaquePointer?, _ column: Int32) -> UnsafePointer<CChar>? { nil }
#endif
