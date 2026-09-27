import JavaScriptKit

extension DurableObjectStorage {
    /// The object's SQL storage: the runtime's `ctx.storage.sql`, backed by
    /// SQLite.
    ///
    /// Every Durable Object is SQLite-backed once created with the
    /// `new_sqlite_classes` migration (the default for new classes); in
    /// workerd's own configuration, its namespace also needs
    /// `enableSql = true`. Accessing this property on an older, KV-only
    /// namespace throws.
    public var sql: SQLStorage {
        SQLStorage(jsObject.sql.object!)
    }
}

/// A Durable Object's SQL storage: the runtime's `ctx.storage.sql`, like
/// workers-rs' `SqlStorage`.
///
///     let sql = state.storage.sql
///     try sql.exec("CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER)")
///     try sql.exec("INSERT INTO counters (name, value) VALUES (?, 1) ON CONFLICT(name) DO UPDATE SET value = value + 1", "x")
///     let count = try sql.exec("SELECT value FROM counters WHERE name = ?", "x").rows().first?["value", as: Int.self]
///
/// SQLite runs in the same process as the Durable Object, so every call here
/// is synchronous even though it can throw: there is no `await`, and (unlike
/// `DurableObjectStorage`) a statement takes effect immediately, without a
/// transaction boundary of its own.
public final class SQLStorage: @unchecked Sendable {
    /// The underlying JavaScript `SqlStorage`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// Runs `query`, binding its `?` placeholders to `bindings` in order.
    ///
    /// The returned cursor is fully materialized by the time this call
    /// returns; a syntax error or a constraint violation is thrown from here,
    /// not from a later call on the cursor.
    @discardableResult
    public func exec(_ query: String, _ bindings: any ConvertibleToJSValue...) throws -> SQLCursor {
        try exec(query, bindings: bindings)
    }

    /// Runs a `SELECT` and decodes each row as `T`, matching column names to
    /// `T`'s `Decodable` keys. A shorthand for `exec(_:_:).decode(as:)`.
    public func query<T: Decodable>(
        _ query: String,
        _ bindings: any ConvertibleToJSValue...,
        as type: T.Type = T.self
    ) throws -> [T] {
        try exec(query, bindings: bindings).decode(as: T.self)
    }

    private func exec(_ query: String, bindings: [any ConvertibleToJSValue]) throws -> SQLCursor {
        guard let exec = jsObject["exec"].function else {
            throw JSException(message: "ctx.storage.sql.exec is not a function")
        }
        var arguments: [any ConvertibleToJSValue] = [query]
        arguments.append(contentsOf: bindings)
        let result = try exec.throws(this: jsObject, arguments: arguments)
        guard let cursor = result.object else {
            throw JSException(message: "sql.exec(\(query)) did not return a cursor")
        }
        return SQLCursor(cursor)
    }
}

/// The result of `SQLStorage.exec(_:_:)`: the runtime's `SqlStorageCursor`.
public final class SQLCursor: @unchecked Sendable {
    /// The underlying JavaScript `SqlStorageCursor`.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The result columns, in order.
    public var columnNames: [String] {
        guard let array = jsObject.columnNames.object.flatMap(JSArray.init) else {
            return []
        }
        return array.compactMap(\.string)
    }

    /// The number of rows the statement read.
    public var rowsRead: Int {
        Int(jsObject.rowsRead.number ?? 0)
    }

    /// The number of rows the statement wrote.
    public var rowsWritten: Int {
        Int(jsObject.rowsWritten.number ?? 0)
    }

    /// The result rows.
    public func rows() -> [SQLRow] {
        guard let array = jsObject.toArray!().object.flatMap(JSArray.init) else {
            return []
        }
        return array.compactMap { $0.object.map(SQLRow.init) }
    }

    /// Decodes each row as `T`, matching column names to `T`'s `Decodable`
    /// keys.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> [T] {
        try rows().map { try $0.decode(as: T.self) }
    }
}

/// One row of a ``SQLCursor``: `{column: value}`, as SQLite and JavaScript
/// represent it. A column's value is a `String`, a `Double`, `null`, or (for
/// a `BLOB`) an `ArrayBuffer`.
public struct SQLRow: @unchecked Sendable {
    /// The underlying JavaScript row object.
    public let jsObject: JSObject

    public init(_ jsObject: JSObject) {
        self.jsObject = jsObject
    }

    /// The value of `column`, converted to `T`, or `nil` when the column is
    /// `NULL` or holds a value that is not a `T`.
    public subscript<T: ConstructibleFromJSValue>(column: String, as type: T.Type = T.self) -> T? {
        T.construct(from: jsObject[column])
    }

    /// The value of a `BLOB` column, as bytes, or `nil` when the column is
    /// `NULL`.
    public func bytes(_ column: String) -> [UInt8]? {
        let value = jsObject[column]
        guard value.object != nil else {
            return nil
        }
        let array = JSTypedArray<UInt8>(unsafelyWrapping: JSObject.global.Uint8Array.object!.new(value))
        return array.withUnsafeBytes { Array($0) }
    }

    /// Decodes the row as `T`, matching column names to `T`'s `Decodable`
    /// keys.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSValueDecoder().decode(T.self, from: .object(jsObject))
    }
}
