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
    /// A generated column's expression, nil for an ordinary column; `stored` says whether its
    /// values are kept (STORED, MariaDB's PERSISTENT) or worked out when read (VIRTUAL).
    var expression: String?
    var stored = false
    /// nil for the table's own. The Binary box is a `_bin` collation.
    var collation: String?
    /// Kept from the table as it was, since the editor doesn't show it: a definition that
    /// changes the column has to say it again or it'd be lost.
    var onUpdate: String?
    var original: String?

    /// The same column, ignoring where it came from.
    func sameDefinition(as other: ColumnDraft) -> Bool {
        var a = self, b = other
        a.original = nil
        b.original = nil
        return a == b
    }
}

/// An index as the table editor shows it: its name, kind and columns. Each column is written as
/// in SQL, maybe with a prefix length or an order: `name`, `title(20)`, `created DESC`.
/// `original` is the index's name in the table before editing; nil for one being added.
struct IndexDraft: Equatable {
    enum Kind: String, CaseIterable {
        case index = "INDEX", unique = "UNIQUE", fulltext = "FULLTEXT", spatial = "SPATIAL"
    }
    var name = ""
    var kind = Kind.index
    var columns: [String] = []
    var original: String?

    /// The column a part names: what comes before a prefix length or an order.
    static func column(of part: String) -> String {
        let text = part.trimmingCharacters(in: .whitespaces)
        let name = text.prefix { $0 != "(" && $0 != " " }
        return name.count >= 2 && name.hasPrefix("`") && name.hasSuffix("`") ? String(name.dropFirst().dropLast()) : String(name)
    }

    /// The part with its column called something else, the rest kept.
    static func renaming(_ part: String, to name: String) -> String {
        let text = part.trimmingCharacters(in: .whitespaces)
        let head = text.prefix { $0 != "(" && $0 != " " }
        return name + text.dropFirst(head.count)
    }

    /// The columns as text, for the editor's field: name, title(20)
    var columnsText: String { columns.joined(separator: ", ") }

    /// The columns from the editor's field, split at commas outside parentheses.
    static func columns(from text: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The index as SQL, for CREATE TABLE or after ADD: UNIQUE INDEX `name` (`a`, `b`(20) DESC)
    var definition: String {
        let parts = columns.map { part -> String in
            let text = part.trimmingCharacters(in: .whitespaces)
            let head = text.prefix { $0 != "(" && $0 != " " }
            return Database.quote(Self.column(of: text)) + text.dropFirst(head.count)
        }
        return (kind == .index ? "INDEX" : "\(kind.rawValue) INDEX") + (name.isEmpty ? "" : " " + Database.quote(name))
            + " (" + parts.joined(separator: ", ") + ")"
    }
}

/// A foreign key as the table editor shows it: the table's columns and the columns of another
/// table (or this one) that their values have to be found in, with what happens to the rows
/// when that row is deleted or its key changed. `original` is its name in the table before
/// editing; nil for one being added. An empty name is left for the server to choose.
struct ForeignKeyDraft: Equatable {
    static let actions = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"]
    var name = ""
    var columns: [String] = []
    /// The table referred to, and its database when that isn't this one.
    var table = ""
    var schema: String?
    var referencedColumns: [String] = []
    var onDelete = "RESTRICT"
    var onUpdate = "RESTRICT"
    var original: String?

    /// As SQL, for CREATE TABLE or after ADD: CONSTRAINT `name` FOREIGN KEY (`a`) REFERENCES `t` (`id`) ON DELETE … ON UPDATE …
    var definition: String {
        func list(_ names: [String]) -> String { "(" + names.map(Database.quote).joined(separator: ", ") + ")" }
        let target = (schema.map { Database.quote($0) + "." } ?? "") + Database.quote(table)
        return (name.isEmpty ? "" : "CONSTRAINT \(Database.quote(name)) ") + "FOREIGN KEY \(list(columns)) REFERENCES \(target) \(list(referencedColumns))"
            + " ON DELETE \(onDelete) ON UPDATE \(onUpdate)"
    }
}

/// A table as it was when editing began: what changing it needs to know, read once so that
/// remaking the SQL as the user types doesn't ask the server each time.
struct TableSnapshot {
    let name: String
    let columns: [ColumnDraft]
    /// The single-column unique indexes (not the primary key), by column, with the index's name.
    let uniqueIndexes: [String: String]
    /// The other indexes, which the editor lists: neither the primary key nor those unique ones.
    var indexes: [IndexDraft] = []
    var foreignKeys: [ForeignKeyDraft] = []
    /// The table's collation, which a column without one of its own has.
    var collation: String?
}

/// Makes the SQL that creates a table, or changes one to match its edited columns. MySQL changes
/// a table in place, so an edit is one ALTER TABLE: columns dropped, changed, added and moved,
/// the key and unique indexes, and the name, all in one statement that applies whole or not at all.
enum TableDesign {
    /// The types the editor offers, without their lengths, which go in a field of their own.
    static let types = ["INT", "BIGINT", "TINYINT", "SMALLINT", "MEDIUMINT", "DECIMAL", "DOUBLE", "FLOAT",
                        "VARCHAR", "CHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR",
                        "BOOLEAN", "JSON", "BLOB", "MEDIUMBLOB", "LONGBLOB", "BINARY", "VARBINARY", "ENUM", "SET", "BIT"]

    /// Number types, which may be UNSIGNED and ZEROFILL.
    static let numeric: Set<String> = ["INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "DECIMAL", "NUMERIC", "DEC",
                                       "FIXED", "DOUBLE", "FLOAT", "REAL"]

    /// Text types, which have a collation and so may be binary.
    static let textual: Set<String> = ["CHAR", "VARCHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET"]

    /// A type's first word in capitals, which says what kind it is: `int(10) unsigned` is INT.
    static func kind(of type: String) -> String {
        type.trimmingCharacters(in: .whitespaces).prefix { $0 != "(" && $0 != " " }.uppercased()
    }

    /// The type's name without UNSIGNED and ZEROFILL, which have boxes of their own.
    static func bareType(_ base: String) -> String {
        base.split(separator: " ").filter { !["UNSIGNED", "ZEROFILL", "SIGNED"].contains($0.uppercased()) }.joined(separator: " ")
    }

    /// Whether the type says UNSIGNED or ZEROFILL.
    static func has(_ word: String, in type: String) -> Bool {
        split(type).base.split(separator: " ").contains { $0.uppercased() == word }
    }

    /// The type with UNSIGNED or ZEROFILL said or left out, the rest as it was written.
    /// ZEROFILL makes a number UNSIGNED too, so ticking one ticks the other, and the reverse.
    static func setting(_ word: String, _ on: Bool, in type: String) -> String {
        let parts = split(type)
        var words = parts.base.split(separator: " ").map(String.init)
        func set(_ word: String, _ on: Bool) {
            let present = words.contains { $0.uppercased() == word }
            if !on { words.removeAll { $0.uppercased() == word } }
            else if !present {
                // UNSIGNED goes before ZEROFILL.
                if word == "UNSIGNED", let at = words.firstIndex(where: { $0.uppercased() == "ZEROFILL" }) { words.insert(word, at: at) }
                else { words.append(word) }
            }
        }
        set(word, on)
        if word == "ZEROFILL", on { set("UNSIGNED", true) }
        if word == "UNSIGNED", !on { set("ZEROFILL", false) }
        return join(words.joined(separator: " "), parts.length)
    }

    /// The type with its name changed as typed or chosen, keeping UNSIGNED and ZEROFILL when
    /// it's still a number, and with `length` for its length.
    static func retype(_ type: String, to base: String, length: String) -> String {
        var new = join(bareType(base), length)
        guard numeric.contains(kind(of: base)) else { return new }
        for word in ["UNSIGNED", "ZEROFILL"] where has(word, in: type) || has(word, in: base) { new = setting(word, true, in: new) }
        return new
    }

    /// Whether the column sorts and compares its text as bytes: a `_bin` collation, its own or the table's.
    static func isBinary(_ column: ColumnDraft, tableCollation: String?) -> Bool {
        (column.collation ?? tableCollation ?? "").lowercased().hasSuffix("_bin")
    }

    /// The collation for the Binary box: the `_bin` one of the column's character set, or when
    /// it's cleared, the table's (nil) or the set's general one if the table's is binary too.
    static func collation(binary: Bool, for column: ColumnDraft, tableCollation: String?) -> String? {
        let current = column.collation ?? tableCollation ?? "utf8mb4_general_ci"
        let charset = String(current.prefix { $0 != "_" })
        if binary {
            let bin = charset + "_bin"
            return bin.lowercased() == tableCollation?.lowercased() ? nil : bin
        }
        if let table = tableCollation, table.hasPrefix(charset + "_"), !table.lowercased().hasSuffix("_bin") { return nil }
        return charset + "_general_ci"
    }

    /// What a type's length starts as when it's chosen: the size, the digits and decimals, or the values.
    static let defaultLengths = ["VARCHAR": "255", "CHAR": "10", "VARBINARY": "255", "BINARY": "16", "DECIMAL": "10,2",
                                 "ENUM": "'a','b'", "SET": "'a','b'", "BIT": "1"]

    /// Types that take no length at all.
    static let lengthless: Set<String> = ["TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
                                          "JSON", "DATE", "BOOLEAN", "BOOL", "GEOMETRY", "POINT", "LINESTRING", "POLYGON"]

    /// Types whose "length" isn't a size: DECIMAL's digits and decimals, ENUM's and SET's values.
    private static let otherLengths: Set<String> = ["DECIMAL", "NUMERIC", "ENUM", "SET"]

    /// A type split for the editor: its name with any words after the parentheses (UNSIGNED,
    /// ZEROFILL), and what's in them. `int(10) unsigned` is ("int unsigned", "10").
    static func split(_ type: String) -> (base: String, length: String) {
        let text = type.trimmingCharacters(in: .whitespaces)
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return (text, "") }
        let base = text[..<open].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? base : base + " " + rest, String(text[text.index(after: open)..<close]))
    }

    /// The type as SQL from the editor's two fields: the length goes after the type's first word.
    static func join(_ base: String, _ length: String) -> String {
        let base = base.trimmingCharacters(in: .whitespaces), length = length.trimmingCharacters(in: .whitespaces)
        let words = base.split(separator: " ", maxSplits: 1)
        guard let first = words.first, !length.isEmpty else { return base }
        return first + "(" + length + ")" + (words.count > 1 ? " " + words[1] : "")
    }

    /// The length a column gets when its type is changed from `old` to `new`: none for a type
    /// that takes none, the usual one when there was none or its meaning changes (a size to
    /// DECIMAL's digits, say), and otherwise the one it had.
    static func length(changingType old: String, to new: String, from length: String) -> String {
        func key(_ base: String) -> String { base.split(separator: " ").first.map { $0.uppercased() } ?? "" }
        let from = key(old), to = key(new)
        if lengthless.contains(to) { return "" }
        if length.isEmpty || otherLengths.contains(from) != otherLengths.contains(to) || (otherLengths.contains(to) && from != to) {
            return defaultLengths[to] ?? ""
        }
        return length
    }

    /// What the length field suggests for a type, when it's empty.
    static func lengthHint(for base: String) -> String {
        let key = base.split(separator: " ").first.map { $0.uppercased() } ?? ""
        if lengthless.contains(key) { return "" }
        switch key {
        case "DECIMAL", "NUMERIC": return "10,2"
        case "ENUM", "SET": return "'a','b'"
        case "DATETIME", "TIMESTAMP", "TIME": return tr("小數秒", "fsp")
        default: return defaultLengths[key] ?? tr("長度", "length")
        }
    }

    static func snapshot(of table: String, in database: MySQLDatabase) throws -> TableSnapshot {
        let collation = try database.run("SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?",
                                         [.text(table)]).rows.first.flatMap { $0[0] == .null ? nil : $0[0].display }
        let indexes = try database.indexes(of: table)
        var unique: [String: String] = [:]
        for index in indexes where index.unique && index.name != "PRIMARY" && index.columns.count == 1 {
            if unique[index.columns[0]] == nil { unique[index.columns[0]] = index.name }
        }
        let columns = try database.columns(of: table).map { column in
            ColumnDraft(name: column.name, type: column.type, primaryKey: column.primaryKey > 0, notNull: column.notNull,
                        unique: unique[column.name] != nil && column.primaryKey == 0, defaultValue: column.defaultValue ?? "",
                        autoincrement: column.autoIncrement, comment: column.comment, expression: column.generationExpression,
                        stored: column.stored, collation: column.collation, onUpdate: column.onUpdate, original: column.name)
        }
        return TableSnapshot(name: table, columns: columns, uniqueIndexes: unique,
                             indexes: try indexDrafts(of: table, in: database, leavingOut: Set(unique.values)),
                             foreignKeys: try foreignKeys(of: table, in: database), collation: collation)
    }

    /// The table's foreign keys, a column at a time put together by name.
    static func foreignKeys(of table: String, in database: MySQLDatabase) throws -> [ForeignKeyDraft] {
        let rows = try database.run("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
                   r.DELETE_RULE, r.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = DATABASE() AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """, [.text(table)]).rows
        let current = database.current
        var keys: [ForeignKeyDraft] = []
        for row in rows {
            let name = row[0].display
            if keys.last?.original == name {
                keys[keys.count - 1].columns.append(row[1].display)
                keys[keys.count - 1].referencedColumns.append(row[4].display)
            } else {
                keys.append(ForeignKeyDraft(name: name, columns: [row[1].display], table: row[3].display,
                                            schema: row[2].display == current ? nil : row[2].display, referencedColumns: [row[4].display],
                                            onDelete: row[5].display, onUpdate: row[6].display, original: name))
            }
        }
        return keys
    }

    /// The table's indexes as drafts, with their kind, prefix lengths and orders. Indexes on an
    /// expression (MySQL 8) have no column to show, so they're left out, and so left as they are.
    private static func indexDrafts(of table: String, in database: MySQLDatabase, leavingOut skip: Set<String>) throws -> [IndexDraft] {
        let rows = try database.run("""
            SELECT INDEX_NAME, NON_UNIQUE, INDEX_TYPE, COLUMN_NAME, SUB_PART, COLLATION FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME <> 'PRIMARY'
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
            """, [.text(table)]).rows
        var drafts: [IndexDraft] = [], expressions: Set<String> = []
        for row in rows {
            let name = row[0].display
            guard !skip.contains(name) else { continue }
            guard row[3] != .null else { expressions.insert(name); continue }
            var part = row[3].display
            if row[4] != .null { part += "(\(row[4].display))" }
            if row[5].display == "D" { part += " DESC" }
            if drafts.last?.original == name {
                drafts[drafts.count - 1].columns.append(part)
            } else {
                let type = row[2].display.uppercased()
                let kind: IndexDraft.Kind = type == "FULLTEXT" ? .fulltext : type == "SPATIAL" ? .spatial : row[1].display == "0" ? .unique : .index
                drafts.append(IndexDraft(name: name, kind: kind, columns: [part], original: name))
            }
        }
        return drafts.filter { !expressions.contains($0.name) }
    }

    /// What's wrong with the draft, for the editor to show; nil when it can be saved.
    static func problem(name: String, columns: [ColumnDraft], indexes: [IndexDraft] = [], foreignKeys: [ForeignKeyDraft] = []) -> String? {
        if let problem = indexProblem(columns: columns, indexes: indexes) { return problem }
        if let problem = foreignKeyProblem(columns: columns, keys: foreignKeys) { return problem }
        return columnProblem(name: name, columns: columns)
    }

    private static func foreignKeyProblem(columns: [ColumnDraft], keys: [ForeignKeyDraft]) -> String? {
        let names = Set(columns.map { $0.name.lowercased() })
        let named = keys.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if Set(named).count != named.count { return tr("外鍵名稱不能重複。", "Foreign key names must be different.") }
        for key in keys {
            let label = key.name.isEmpty ? tr("新外鍵", "A new foreign key") : tr("外鍵「\(key.name)」", "The foreign key “\(key.name)”")
            if key.columns.isEmpty { return tr("\(label)至少要有一個欄位。", "\(label) needs at least one column.") }
            if let missing = key.columns.first(where: { !names.contains($0.lowercased()) }) {
                return tr("\(label)用到的欄位「\(missing)」不在資料表裡。", "\(label) uses “\(missing)”, which isn’t a column of the table.")
            }
            if key.table.isEmpty { return tr("\(label)要選擇參照的資料表。", "\(label) needs a table to refer to.") }
            if key.referencedColumns.count != key.columns.count {
                return tr("\(label)參照的欄位數要和它的欄位數一樣。", "\(label) needs as many referenced columns as columns.")
            }
        }
        return nil
    }

    private static func indexProblem(columns: [ColumnDraft], indexes: [IndexDraft]) -> String? {
        let names = Set(columns.map { $0.name.lowercased() })
        let named = indexes.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if Set(named).count != named.count { return tr("索引名稱不能重複。", "Index names must be different.") }
        if named.contains("primary") { return tr("索引不能命名為 PRIMARY，主鍵請用欄位的「主鍵」勾選。", "An index can’t be called PRIMARY; tick Key on the columns instead.") }
        for index in indexes {
            let label = index.name.isEmpty ? tr("新索引", "A new index") : tr("索引「\(index.name)」", "The index “\(index.name)”")
            if index.columns.isEmpty { return tr("\(label)至少要有一個欄位。", "\(label) needs at least one column.") }
            if let missing = index.columns.map(IndexDraft.column(of:)).first(where: { !names.contains($0.lowercased()) }) {
                return tr("\(label)用到的欄位「\(missing)」不在資料表裡。", "\(label) uses “\(missing)”, which isn’t a column of the table.")
            }
        }
        return nil
    }

    private static func columnProblem(name: String, columns: [ColumnDraft]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return tr("請輸入資料表名稱。", "Enter a name for the table.") }
        if columns.isEmpty { return tr("資料表至少要有一個欄位。", "A table needs at least one column.") }
        let names = columns.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("") { return tr("每個欄位都要有名稱。", "Every column needs a name.") }
        if Set(names).count != names.count { return tr("欄位名稱不能重複。", "Column names must be different.") }
        if columns.contains(where: { $0.type.trimmingCharacters(in: .whitespaces).isEmpty }) { return tr("每個欄位都要有類型。", "Every column needs a type.") }
        if let column = columns.first(where: { $0.expression?.trimmingCharacters(in: .whitespaces).isEmpty == true }) {
            return tr("生成欄位「\(column.name)」要有運算式。", "The generated column “\(column.name)” needs an expression.")
        }
        let automatic = columns.filter(\.autoincrement)
        if automatic.count > 1 { return tr("只能有一個自動遞增的欄位。", "Only one column can be AUTO_INCREMENT.") }
        if let column = automatic.first, !column.primaryKey, !column.unique {
            return tr("自動遞增的欄位要是主鍵或唯一。", "An AUTO_INCREMENT column has to be the key or unique.")
        }
        return nil
    }

    // MARK: Creating

    static func createSQL(name: String, columns: [ColumnDraft], indexes: [IndexDraft] = [], foreignKeys: [ForeignKeyDraft] = []) -> String {
        var lines = columns.map(definition)
        let keys = columns.filter(\.primaryKey)
        if !keys.isEmpty { lines.append("PRIMARY KEY (" + keys.map { Database.quote($0.name) }.joined(separator: ", ") + ")") }
        for column in columns where column.unique && !column.primaryKey {
            lines.append("UNIQUE KEY (\(Database.quote(column.name)))")
        }
        lines += indexes.map(\.definition)
        lines += foreignKeys.map(\.definition)
        return "CREATE TABLE \(Database.quote(name)) (\n    " + lines.joined(separator: ",\n    ") + "\n);"
    }

    /// One column's definition, without its place in the table or its keys.
    private static func definition(_ column: ColumnDraft) -> String {
        var parts = [Database.quote(column.name), column.type.trimmingCharacters(in: .whitespaces)]
        if let collation = column.collation { parts.append("COLLATE \(collation)") }
        if let expression = column.expression {
            parts.append("GENERATED ALWAYS AS (\(expression.trimmingCharacters(in: .whitespaces))) " + (column.stored ? "STORED" : "VIRTUAL"))
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
    static func alterSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft], indexes: [IndexDraft]? = nil,
                         foreignKeys: [ForeignKeyDraft]? = nil) -> (sql: String, warnings: [String]) {
        var clauses: [String] = [], warnings: [String] = []
        // Foreign keys taken out or changed go first, before the columns they hold are changed or
        // dropped; the new ones come last, once their columns are there.
        let keys = foreignKeyClauses(table, columns: columns, keys: foreignKeys ?? table.foreignKeys, indexes: indexes ?? table.indexes)
        clauses += keys.drops
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
        // A column whose generation changes (none, VIRTUAL, STORED) can't be changed in place, so
        // it's dropped and added again: a generated column's values are worked out again anyway,
        // but one made ordinary starts empty. Its indexes go with it and are made again below.
        func generation(_ column: ColumnDraft) -> Int { column.expression == nil ? 0 : column.stored ? 2 : 1 }
        var rebuilt: Set<String> = []
        for (i, column) in columns.enumerated() {
            let place = i == 0 ? " FIRST" : " AFTER \(Database.quote(columns[i - 1].name))"
            if let original = column.original, let old = before.first(where: { $0.name == original }),
               generation(old) != generation(column), generation(old) + generation(column) > 0 {
                rebuilt.insert(original)
                clauses.append("DROP COLUMN \(Database.quote(original))")
                clauses.append("ADD COLUMN \(definition(column))\(place)")
                if column.expression == nil {
                    warnings.append(tr("欄位 \(column.name) 會重新建立（生成方式不能直接變更），原本算出的值不會保留。",
                                       "The column \(column.name) is made again (its generation can’t be changed in place), without the values it had."))
                }
            } else if let original = column.original, let old = before.first(where: { $0.name == original }) {
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
            let index = column.original.flatMap { rebuilt.contains($0) ? nil : table.uniqueIndexes[$0] }
            let wanted = column.unique && !column.primaryKey
            if let index, !wanted {
                clauses.append("DROP INDEX \(Database.quote(index))")
            } else if index == nil, wanted {
                clauses.append("ADD UNIQUE (\(Database.quote(column.name)))")
            }
        }

        clauses += indexClauses(table, columns: columns.filter { !rebuilt.contains($0.original ?? "") }, indexes: indexes ?? table.indexes)
        clauses += keys.adds

        if newName != table.name { clauses.append("RENAME TO \(Database.quote(newName))") }
        guard !clauses.isEmpty || !keys.readds.isEmpty else { return ("", []) }
        var sql = clauses.isEmpty ? "" : "ALTER TABLE \(Database.quote(table.name))\n  " + clauses.joined(separator: ",\n  ") + ";"
        if !keys.readds.isEmpty {
            sql += (sql.isEmpty ? "" : "\n") + "ALTER TABLE \(Database.quote(newName))\n  " + keys.readds.joined(separator: ",\n  ") + ";"
        }
        return (sql, warnings)
    }

    /// Dropping the indexes taken out or changed, and adding the changed and new ones. An index is
    /// compared with the table's as its columns now stand: MySQL renames an index's columns with
    /// them and drops a dropped column from its indexes itself, so those need nothing here.
    private static func indexClauses(_ table: TableSnapshot, columns: [ColumnDraft], indexes: [IndexDraft]) -> [String] {
        let renames = Dictionary(columns.compactMap { c in c.original.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        var drops: [String] = [], adds: [String] = []
        for old in table.indexes {
            var now = old
            now.columns = old.columns.compactMap { part in renames[IndexDraft.column(of: part)].map { IndexDraft.renaming(part, to: $0) } }
            if let edited = indexes.first(where: { $0.original == old.name }) {
                guard edited != now else { continue }
                if !now.columns.isEmpty { drops.append("DROP INDEX \(Database.quote(old.name))") }
                adds.append("ADD " + edited.definition)
            } else if !now.columns.isEmpty {
                drops.append("DROP INDEX \(Database.quote(old.name))")
            }
        }
        adds += indexes.filter { $0.original == nil }.map { "ADD " + $0.definition }
        return drops + adds
    }

    /// Like the indexes, compared with the table's as its columns now stand: renaming a column
    /// renames it in the foreign keys, its own and (referring to this table) the referenced ones.
    /// A changed key is dropped and added again; MySQL won't add one by the name of a key dropped
    /// in the same ALTER TABLE, so one keeping its name is added in a second statement (`readds`).
    /// The index MySQL made for a key is named after it and stays when the key is dropped; one
    /// moved to other columns would clash with it, so that index goes too, if it's left as it was.
    private static func foreignKeyClauses(_ table: TableSnapshot, columns: [ColumnDraft], keys: [ForeignKeyDraft],
                                          indexes: [IndexDraft]) -> (drops: [String], adds: [String], readds: [String]) {
        let renames = Dictionary(columns.compactMap { c in c.original.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        var drops: [String] = [], adds: [String] = [], readds: [String] = []
        for old in table.foreignKeys {
            var now = old
            now.columns = old.columns.map { renames[$0] ?? $0 }
            if old.schema == nil, old.table == table.name { now.referencedColumns = old.referencedColumns.map { renames[$0] ?? $0 } }
            if let edited = keys.first(where: { $0.original == old.name }) {
                guard edited != now else { continue }
                drops.append("DROP FOREIGN KEY \(Database.quote(old.name))")
                guard edited.name.lowercased() == old.name.lowercased() else { adds.append("ADD " + edited.definition); continue }
                readds.append("ADD " + edited.definition)
                if edited.columns != now.columns, let index = table.indexes.first(where: { $0.name.lowercased() == old.name.lowercased() }),
                   indexes.contains(where: { $0.original == index.name && $0.name == index.name }) {
                    drops.append("DROP INDEX \(Database.quote(index.name))")
                }
            } else {
                drops.append("DROP FOREIGN KEY \(Database.quote(old.name))")
            }
        }
        adds += keys.filter { $0.original == nil }.map { "ADD " + $0.definition }
        return (drops, adds, readds)
    }

    /// Runs a change.
    static func apply(_ sql: String, to database: MySQLDatabase) throws {
        try database.run(sql)
    }
}
