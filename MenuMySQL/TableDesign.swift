import Foundation

/// A column as the table editor shows it. `original` is the column it was in the table before
/// editing, so its data can follow it through a rename; nil for a column being added.
struct ColumnDraft: Equatable {
    var name = ""
    var type = "VARCHAR(255)"
    var primaryKey = false
    var notNull = false
    var unique = false
    /// As SQL: 0, 'text', CURRENT_TIMESTAMP, (expression). Plain words are quoted as text when the SQL is made.
    var defaultValue = ""
    var autoincrement = false
    var comment = ""
    /// Kept from the table as it was, since the editor doesn't show them: a definition that
    /// changes the column has to say them again or they'd be lost.
    var onUpdate: String?
    var generated: String?
    var collation: String?
    var original: String?

    /// The same column, ignoring where it came from.
    func sameDefinition(as other: ColumnDraft) -> Bool {
        var a = self, b = other
        a.original = nil
        b.original = nil
        return a == b
    }
}

/// A table as it was when editing began: what changing it needs to know, read once so that
/// remaking the SQL as the user types doesn't ask the server each time.
struct TableSnapshot {
    let name: String
    let columns: [ColumnDraft]
    /// The single-column unique indexes (not the primary key), by column, with the index's name.
    let uniqueIndexes: [String: String]
}

/// Makes the SQL that creates a table, or changes one to match its edited columns. MySQL changes
/// a table in place, so an edit is one ALTER TABLE: columns dropped, changed, added and moved,
/// the key and unique indexes, and the name, all in one statement that applies whole or not at all.
enum TableDesign {
    static let types = ["INT", "BIGINT", "TINYINT", "SMALLINT", "INT UNSIGNED", "BIGINT UNSIGNED", "DECIMAL(10,2)", "DOUBLE",
                        "VARCHAR(255)", "CHAR(10)", "TEXT", "MEDIUMTEXT", "LONGTEXT", "DATE", "DATETIME", "TIMESTAMP", "TIME",
                        "BOOLEAN", "JSON", "BLOB", "LONGBLOB", "ENUM('a','b')"]

    static func snapshot(of table: String, in database: MySQLDatabase) throws -> TableSnapshot {
        let indexes = try database.indexes(of: table)
        var unique: [String: String] = [:]
        for index in indexes where index.unique && index.name != "PRIMARY" && index.columns.count == 1 {
            if unique[index.columns[0]] == nil { unique[index.columns[0]] = index.name }
        }
        let columns = try database.columns(of: table).map { column in
            ColumnDraft(name: column.name, type: column.type, primaryKey: column.primaryKey > 0, notNull: column.notNull,
                        unique: unique[column.name] != nil && column.primaryKey == 0, defaultValue: column.defaultValue ?? "",
                        autoincrement: column.autoIncrement, comment: column.comment, onUpdate: column.onUpdate,
                        generated: column.generated, collation: column.collation, original: column.name)
        }
        return TableSnapshot(name: table, columns: columns, uniqueIndexes: unique)
    }

    /// What's wrong with the draft, for the editor to show; nil when it can be saved.
    static func problem(name: String, columns: [ColumnDraft]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return tr("請輸入資料表名稱。", "Enter a name for the table.") }
        if columns.isEmpty { return tr("資料表至少要有一個欄位。", "A table needs at least one column.") }
        let names = columns.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("") { return tr("每個欄位都要有名稱。", "Every column needs a name.") }
        if Set(names).count != names.count { return tr("欄位名稱不能重複。", "Column names must be different.") }
        if columns.contains(where: { $0.type.trimmingCharacters(in: .whitespaces).isEmpty }) { return tr("每個欄位都要有類型。", "Every column needs a type.") }
        let automatic = columns.filter(\.autoincrement)
        if automatic.count > 1 { return tr("只能有一個自動遞增的欄位。", "Only one column can be AUTO_INCREMENT.") }
        if let column = automatic.first, !column.primaryKey, !column.unique {
            return tr("自動遞增的欄位要是主鍵或唯一。", "An AUTO_INCREMENT column has to be the key or unique.")
        }
        return nil
    }

    // MARK: Creating

    static func createSQL(name: String, columns: [ColumnDraft]) -> String {
        var lines = columns.map(definition)
        let keys = columns.filter(\.primaryKey)
        if !keys.isEmpty { lines.append("PRIMARY KEY (" + keys.map { Database.quote($0.name) }.joined(separator: ", ") + ")") }
        for column in columns where column.unique && !column.primaryKey {
            lines.append("UNIQUE KEY (\(Database.quote(column.name)))")
        }
        return "CREATE TABLE \(Database.quote(name)) (\n    " + lines.joined(separator: ",\n    ") + "\n);"
    }

    /// One column's definition, without its place in the table or its keys.
    private static func definition(_ column: ColumnDraft) -> String {
        var parts = [Database.quote(column.name), column.type.trimmingCharacters(in: .whitespaces)]
        if let collation = column.collation { parts.append("COLLATE \(collation)") }
        if let generated = column.generated {
            parts.append(generated)
        } else {
            if column.notNull || column.primaryKey { parts.append("NOT NULL") }
            let value = column.defaultValue.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { parts.append("DEFAULT " + defaultSQL(value)) }
            if let onUpdate = column.onUpdate { parts.append(onUpdate) }
            if column.autoincrement { parts.append("AUTO_INCREMENT") }
        }
        if !column.comment.isEmpty { parts.append("COMMENT " + Value.text(column.comment).sqlLiteral) }
        return parts.joined(separator: " ")
    }

    /// A default as typed: numbers, NULL, the current time, quoted text, b'bits' and (expressions)
    /// stay as they are; anything else is taken as text and quoted.
    static func defaultSQL(_ value: String) -> String {
        let upper = value.uppercased()
        if Double(value) != nil || ["NULL", "TRUE", "FALSE", "CURRENT_DATE", "CURRENT_TIME", "CURDATE()"].contains(upper)
            || upper.hasPrefix("CURRENT_TIMESTAMP") || upper.hasPrefix("NOW(") || upper.hasPrefix("LOCALTIME")
            || value.hasPrefix("'") || value.hasPrefix("(") || upper.hasPrefix("X'") || upper.hasPrefix("B'") {
            return value
        }
        return Value.text(value).sqlLiteral
    }

    // MARK: Changing

    /// The ALTER TABLE that turns the table as it is into the edited one, and what the change
    /// gives up (a dropped column's data, say), to show before it runs.
    static func alterSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft]) -> (sql: String, warnings: [String]) {
        var clauses: [String] = [], warnings: [String] = []
        let before = table.columns
        let dropped = before.filter { old in !columns.contains { $0.original == old.name } }
        for column in dropped { clauses.append("DROP COLUMN \(Database.quote(column.name))") }
        if !dropped.isEmpty {
            warnings.append(tr("會刪除欄位 \(dropped.map(\.name).joined(separator: "、")) 和其中的資料。",
                               "Deletes the column\(dropped.count == 1 ? "" : "s") \(dropped.map(\.name).joined(separator: ", ")) and the data in \(dropped.count == 1 ? "it" : "them")."))
        }

        // The kept columns as they stand once the dropped ones are gone; from the first place the
        // new order differs, every column is given its place again (MySQL takes the columns that
        // are moved out first, then puts each one after the column named).
        let remaining = before.map(\.name).filter { name in !dropped.contains { $0.name == name } }
        let keptInNewOrder = columns.compactMap(\.original)
        let reordered = keptInNewOrder != remaining
        let firstMoved = reordered ? (columns.indices.first { i in i >= remaining.count || columns[i].original != remaining[i] } ?? 0) : columns.count
        for (i, column) in columns.enumerated() {
            let place = i == 0 ? " FIRST" : " AFTER \(Database.quote(columns[i - 1].name))"
            if let original = column.original, let old = before.first(where: { $0.name == original }) {
                if i >= firstMoved {
                    clauses.append("CHANGE COLUMN \(Database.quote(original)) \(definition(column))\(place)")
                } else if !column.sameDefinition(as: old) {
                    clauses.append("CHANGE COLUMN \(Database.quote(original)) \(definition(column))")
                }
            } else {
                // A new column: at the end it needs no place, elsewhere after the one before it.
                let atEnd = !reordered && columns[(i + 1)...].allSatisfy { $0.original == nil }
                clauses.append("ADD COLUMN \(definition(column))\(atEnd ? "" : place)")
            }
        }

        // The primary key, if its columns (or their order) changed.
        let oldKey = before.filter(\.primaryKey).map(\.name)
        let newKey = columns.filter(\.primaryKey)
        if newKey.map({ $0.original ?? "\u{0}" }) != oldKey {
            if !oldKey.isEmpty { clauses.append("DROP PRIMARY KEY") }
            if !newKey.isEmpty { clauses.append("ADD PRIMARY KEY (" + newKey.map { Database.quote($0.name) }.joined(separator: ", ") + ")") }
        }

        // Unique indexes on one column: dropped when the box is cleared, made when it's ticked.
        // A dropped column's index goes with it, and a renamed one's follows it.
        for column in columns {
            let index = column.original.flatMap { table.uniqueIndexes[$0] }
            let wanted = column.unique && !column.primaryKey
            if let index, !wanted {
                clauses.append("DROP INDEX \(Database.quote(index))")
            } else if index == nil, wanted {
                clauses.append("ADD UNIQUE (\(Database.quote(column.name)))")
            }
        }

        if newName != table.name { clauses.append("RENAME TO \(Database.quote(newName))") }
        guard !clauses.isEmpty else { return ("", []) }
        return ("ALTER TABLE \(Database.quote(table.name))\n  " + clauses.joined(separator: ",\n  ") + ";", warnings)
    }

    /// Runs a change.
    static func apply(_ sql: String, to database: MySQLDatabase) throws {
        try database.run(sql)
    }
}
