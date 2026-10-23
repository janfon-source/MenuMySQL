import Foundation

/// One value from a cell, as the grid shows and edits it.
enum Value: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// How a grid cell shows it.
    var display: String {
        switch self {
        case .null: return "NULL"
        case .integer(let n): return String(n)
        case .real(let d): return String(d)
        case .text(let s): return s
        case .blob(let data): return tr("<BLOB \(data.count) 位元組>", "<BLOB \(data.count) bytes>")
        }
    }

    /// The value written as an SQL literal: values go into the SQL itself, as the mysql client
    /// does, since the text protocol has no placeholders.
    var sqlLiteral: String {
        switch self {
        case .null: return "NULL"
        case .integer(let n): return String(n)
        case .real(let d): return d.isFinite ? String(d) : "NULL"
        case .text(let s): return Database.stringLiteral(s)
        case .blob(let data): return data.isEmpty ? "''" : "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
        }
    }

    /// How CSV export writes it: NULL as an empty field, BLOBs as hex.
    var csv: String {
        switch self {
        case .null: return ""
        case .blob(let data): return data.map { String(format: "%02x", $0) }.joined()
        default: return display
        }
    }
}

/// What a statement returned: its columns and rows, and how many rows it changed.
struct ResultSet {
    var columns: [String] = []
    var rows: [[Value]] = []
    var changes = 0
}

/// A table or view in the database.
struct DatabaseObject: Equatable {
    enum Kind: String { case table, view }
    let name: String
    let kind: Kind
}

/// A column, from information_schema.COLUMNS.
struct Column {
    let name: String
    /// In full, as MySQL writes it: varchar(255), int(10) unsigned, enum('a','b').
    let type: String
    let notNull: Bool
    /// As SQL, ready to edit: 0, 'text', CURRENT_TIMESTAMP, (expression); nil for none.
    let defaultValue: String?
    let primaryKey: Int   // its place in the primary key, from 1; 0 if not part of it
    var autoIncrement = false
    /// What else EXTRA says that a definition has to keep: ON UPDATE CURRENT_TIMESTAMP.
    var onUpdate: String?
    /// A generated column's GENERATED ALWAYS AS (…) VIRTUAL or STORED.
    var generated: String?
    var collation: String?
    var comment = ""
}

/// An index, from information_schema.STATISTICS.
struct Index {
    let name: String
    let unique: Bool
    let columns: [String]
}

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Writing SQL for MySQL: quoting names and text, and putting values in place of `?`.
enum Database {
    /// Whether backslashes escape in strings, as they do unless sql_mode has NO_BACKSLASH_ESCAPES.
    static var backslashEscapes = true

    /// `name` as an SQL identifier, safe whatever characters it has.
    static func quote(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    static func stringLiteral(_ s: String) -> String {
        var body = s.replacingOccurrences(of: "'", with: "''")
        if backslashEscapes {
            body = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
                .replacingOccurrences(of: "\0", with: "\\0")
        }
        return "'" + body + "'"
    }

    /// Puts the values in place of the `?` placeholders as SQL literals. A `?` inside quotes or
    /// backquotes, as in a column named `price?`, is left alone.
    static func inline(_ values: [Value], into sql: String) -> String {
        var values = values[...]
        var quote: Character?
        var escaped = false
        return sql.reduce(into: "") { out, character in
            if let open = quote {
                if escaped { escaped = false }
                else if character == "\\", open != "`", backslashEscapes { escaped = true }
                else if character == open { quote = nil }   // '' and `` close and reopen, which comes out the same
                out.append(character)
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                out.append(character)
            } else if character == "?", let value = values.popFirst() {
                out += value.sqlLiteral
            } else {
                out.append(character)
            }
        }
    }
}

/// Where a server is and how to sign in to it: the host and port, the account, the database to
/// open first, TLS, and an SSH tunnel to go through when the server is only reachable from the
/// machine it's on.
struct ServerLocation: Equatable {
    var host = "127.0.0.1"
    var port = 3306
    var user = "root"
    var database: String?
    var tls = MySQLWire.TLSMode.preferred
    /// `user@host`, or a Host name from ~/.ssh/config; nil to connect directly.
    var sshDestination: String?
    var sshPort: Int?
    var sshIdentity: String?

    var usesSSH: Bool { !(sshDestination ?? "").isEmpty }

    /// How the recent list stores it: mysql://user@host:port?db=…&ssh=…, each part percent-encoded.
    var key: String {
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        var fields: [String] = []
        if let database, !database.isEmpty { fields.append("db=" + encode(database)) }
        if tls != .preferred { fields.append("tls=" + tls.rawValue) }
        if let sshDestination, !sshDestination.isEmpty { fields.append("ssh=" + encode(sshDestination)) }
        if let sshPort { fields.append("sshport=\(sshPort)") }
        if let sshIdentity, !sshIdentity.isEmpty { fields.append("identity=" + encode(sshIdentity)) }
        return "mysql://" + encode(user) + "@" + encode(host) + ":\(port)" + (fields.isEmpty ? "" : "?" + fields.joined(separator: "&"))
    }

    /// Whose password this is, for the password store: the account on the server, whichever database.
    var account: String {
        "\(user)@\(host):\(port)" + (usesSSH ? " via \(sshDestination!)" : "")
    }

    /// The server as people would say it: host:port, and the SSH host it's reached through.
    var serverName: String {
        (port == 3306 ? host : "\(host):\(port)") + (usesSSH ? tr("（經由 \(sshDestination!)）", " (via \(sshDestination!))") : "")
    }

    init() {}

    init?(key: String) {
        guard key.hasPrefix("mysql://") else { return nil }
        let rest = key.dropFirst(8)
        let address = rest.prefix { $0 != "?" }
        var fields: [String: String] = [:]
        for pair in rest.dropFirst(address.count + 1).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].removingPercentEncoding }
        }
        guard let at = address.lastIndex(of: "@"), let colon = address.lastIndex(of: ":"), at < colon,
              let user = address[..<at].removingPercentEncoding,
              let host = address[address.index(after: at)..<colon].removingPercentEncoding, !host.isEmpty,
              let port = Int(address[address.index(after: colon)...]) else { return nil }
        self.user = user
        self.host = host
        self.port = port
        database = fields["db"]
        tls = fields["tls"].flatMap(MySQLWire.TLSMode.init(rawValue:)) ?? .preferred
        sshDestination = fields["ssh"]
        sshPort = fields["sshport"].flatMap { Int($0) }
        sshIdentity = fields["identity"]
    }
}

/// A connection to a MySQL or MariaDB server, and the database in use on it. Runs SQL; reading
/// the schema and changing rows are built on that. A connection the server dropped while it sat
/// unused (wait_timeout) is made again before the next statement.
final class MySQLDatabase {
    private(set) var server: ServerLocation
    private let password: String
    private var wire: MySQLWire?
    private var tunnel: SSHTunnel?
    private var lastUsed = Date()
    private(set) var serverVersion = ""
    private(set) var usesTLS = false
    /// Whether this server's strings take backslash escapes; `Database.backslashEscapes` follows
    /// the connection in use, set when its tab is shown.
    private(set) var backslashEscapes = true
    /// Whether the account may change anything: false when it was granted SELECT alone, say.
    /// The server has the final say; this only greys out what would certainly fail.
    let readOnly = false

    var isMariaDB: Bool { serverVersion.localizedCaseInsensitiveContains("mariadb") }
    /// The version as people know it, without the "5.5.5-" MariaDB puts first for old clients.
    var version: String {
        serverVersion.hasPrefix("5.5.5-") ? String(serverVersion.dropFirst(6)) : serverVersion
    }

    /// The database in use, if one is.
    var current: String? { server.database }
    var name: String { server.database ?? server.host }
    var location: String { "\(server.user)@\(server.serverName)" + (current.map { " / \($0)" } ?? "") }
    var recentKey: String { server.key }

    /// Connects (through the SSH tunnel first, if there is one) and opens the database given.
    init(_ server: ServerLocation, password: String) throws {
        self.server = server
        self.password = password
        try connect()
    }

    deinit {
        wire?.quit()
        tunnel?.close()
    }

    func close() {
        wire?.quit()
        wire = nil
        tunnel?.close()
        tunnel = nil
    }

    private func connect() throws {
        wire?.close()
        wire = nil
        var host = server.host, port = server.port
        if server.usesSSH {
            if tunnel?.isRunning != true {
                tunnel?.close()
                tunnel = try SSHTunnel(server)
            }
            host = "127.0.0.1"
            port = tunnel!.localPort
        }
        let wire: MySQLWire
        do {
            wire = try MySQLWire(host: host, port: port, user: server.user, password: password,
                                 database: server.database, tls: server.usesSSH && server.tls == .preferred ? .disabled : server.tls)
        } catch {
            throw Self.translate(error, server: server)
        }
        self.wire = wire
        serverVersion = wire.serverVersion
        usesTLS = wire.usesTLS
        lastUsed = Date()
        _ = try execute("SET NAMES utf8mb4")
        let mode = try execute("SELECT @@SESSION.sql_mode").last?.rows.first?.first?.display ?? ""
        backslashEscapes = !mode.contains("NO_BACKSLASH_ESCAPES")
        Database.backslashEscapes = backslashEscapes
    }

    /// The connection, made again if it broke or the server may have dropped it while idle.
    private func ready() throws -> MySQLWire {
        if let wire, wire.isOpen {
            if Date().timeIntervalSince(lastUsed) < 30 { return wire }
            if (try? wire.ping()) != nil { return wire }
        }
        try connect()
        return wire!
    }

    private func execute(_ sql: String) throws -> [MySQLWire.Result] {
        let wire = try ready()
        defer { lastUsed = Date() }
        do {
            return try wire.query(sql)
        } catch {
            throw Self.translate(error, server: server)
        }
    }

    // MARK: Running SQL

    /// Runs every statement in `sql` in turn. Returns the rows of the last statement that
    /// returns any (a query after an update, say), and the rows all of them changed.
    /// `bindings` fill the `?` placeholders.
    @discardableResult
    func run(_ sql: String, _ bindings: [Value] = []) throws -> ResultSet {
        try runReturningID(sql, bindings).result
    }

    private func runReturningID(_ sql: String, _ bindings: [Value]) throws -> (result: ResultSet, lastInsertID: UInt64) {
        let results = try execute(bindings.isEmpty ? sql : Database.inline(bindings, into: sql))
        var set = ResultSet()
        var id: UInt64 = 0
        for result in results {
            set.changes += Int(clamping: result.affectedRows)
            if result.lastInsertID != 0 { id = result.lastInsertID }
            if !result.columns.isEmpty {
                set.columns = result.columns.map(\.name)
                set.rows = result.rows
            }
        }
        return (set, id)
    }

    /// Adds a row of default values; returns the AUTO_INCREMENT value it was given, or 0.
    func insertRow(into table: String) throws -> Int64 {
        Int64(clamping: try runReturningID("INSERT INTO \(Database.quote(table)) () VALUES ()", []).lastInsertID)
    }

    /// The databases on the server this account can see, by name.
    func databases() throws -> [String] {
        try run("SHOW DATABASES").rows.map { $0[0].display }
    }

    /// Makes `name` the database in use; nil for none (which only a new connection gives).
    func use(_ name: String?) throws {
        guard let name else {
            server.database = nil
            return try connect()
        }
        let wire = try ready()
        do {
            try wire.use(name)
        } catch {
            throw Self.translate(error, server: server)
        }
        server.database = name
        lastUsed = Date()
    }

    /// What went wrong, in words, with a hint for the common sign-in failures.
    private static func translate(_ error: Error, server: ServerLocation) -> Error {
        guard let failure = error as? MySQLWire.Failure else { return error }
        switch failure {
        case .connection(let message):
            return DatabaseError(message: message)
        case .server(let code, _, let message):
            var text = message + " (\(code))"
            if code == 1045 {
                text += "\n" + tr("請確認帳號和密碼。", "Check the account name and password.")
            } else if code == 1130 {
                text += "\n" + tr("伺服器不允許從這台電腦登入這個帳號；可以改用 SSH 通道，從伺服器本機連線。",
                                  "The server doesn’t let this account sign in from here; an SSH tunnel connects from the server itself.")
            } else if code == 2061 || message.contains("caching_sha2") {
                text += "\n" + tr("請改用 SSL/TLS 連線。", "Try connecting with SSL/TLS.")
            }
            return DatabaseError(message: text)
        }
    }

    // MARK: Schema

    /// Tables, then views, by name.
    func objects() throws -> [DatabaseObject] {
        guard current != nil else { return [] }
        return try run("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
            ORDER BY TABLE_TYPE = 'VIEW', TABLE_NAME
            """).rows.map { row in
            DatabaseObject(name: row[0].display, kind: row[1].display == "VIEW" ? .view : .table)
        }
    }

    func columns(of name: String) throws -> [Column] {
        let keys = try primaryKey(of: name)
        let rows = try run("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLLATION_NAME, COLUMN_COMMENT,
                   GENERATION_EXPRESSION, DATA_TYPE
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
            """, [.text(name)]).rows
        let tableCollation = try run("SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?",
                                     [.text(name)]).rows.first?.first
        return rows.map { row in
            let name = row[0].display, extra = row[4].display.lowercased()
            let rawDefault: String? = row[3] == .null ? nil : row[3].display
            var column = Column(name: name, type: row[1].display, notNull: row[2].display == "NO",
                                defaultValue: defaultSQL(rawDefault, extra: extra, dataType: row[8].display.lowercased()),
                                primaryKey: (keys.firstIndex(of: name) ?? -1) + 1)
            column.autoIncrement = extra.contains("auto_increment")
            if let range = extra.range(of: #"on update [a-z_]+(\(\d*\))?"#, options: .regularExpression) {
                column.onUpdate = extra[range].uppercased()
            }
            let expression = row[7] == .null ? "" : row[7].display
            if !expression.isEmpty {
                column.generated = "GENERATED ALWAYS AS (\(expression)) " + (extra.contains("stored") || extra.contains("persistent") ? "STORED" : "VIRTUAL")
            }
            if row[5] != .null, row[5] != tableCollation { column.collation = row[5].display }
            column.comment = row[6].display
            return column
        }
    }

    /// A column's default as SQL. MySQL gives literals bare (abc for 'abc') and marks expressions
    /// DEFAULT_GENERATED; MariaDB quotes literals and leaves expressions bare, and writes NULL
    /// for no default.
    private func defaultSQL(_ raw: String?, extra: String, dataType: String) -> String? {
        guard let raw else { return nil }
        let textual = ["char", "varchar", "text", "tinytext", "mediumtext", "longtext", "enum", "set", "binary", "varbinary",
                       "date", "datetime", "timestamp", "time", "year", "json", "blob"].contains(dataType)
        let upper = raw.uppercased()
        let timestamp = upper.hasPrefix("CURRENT_TIMESTAMP") || upper.hasPrefix("NOW(") || upper.hasPrefix("LOCALTIME")
            || upper == "CURRENT_DATE" || upper == "CURDATE()"
        if isMariaDB {
            if raw == "NULL" { return nil }
            if raw.hasPrefix("'") || Double(raw) != nil || timestamp || raw.hasPrefix("b'") { return raw }
            return "(\(raw))"
        }
        if timestamp || raw.hasPrefix("b'") { return raw }
        if extra.contains("default_generated") { return "(\(raw))" }
        if !textual, Double(raw) != nil { return raw }
        return Value.text(raw).sqlLiteral
    }

    /// The primary key's columns in order, or else those of the first unique index whose columns
    /// can't be NULL: what tells a row from the others, for changing it.
    func primaryKey(of table: String) throws -> [String] {
        let rows = try run("""
            SELECT s.INDEX_NAME, s.COLUMN_NAME, s.NULLABLE FROM information_schema.STATISTICS s
            WHERE s.TABLE_SCHEMA = DATABASE() AND s.TABLE_NAME = ? AND s.NON_UNIQUE = 0
            ORDER BY s.INDEX_NAME <> 'PRIMARY', s.INDEX_NAME, s.SEQ_IN_INDEX
            """, [.text(table)]).rows
        var groups: [(name: String, columns: [String], nullable: Bool)] = []
        for row in rows {
            let index = row[0].display
            if groups.last?.name != index { groups.append((index, [], false)) }
            groups[groups.count - 1].columns.append(row[1].display)
            if row[2].display == "YES" { groups[groups.count - 1].nullable = true }
        }
        return groups.first { !$0.nullable }?.columns ?? []
    }

    func indexes(of name: String) throws -> [Index] {
        let rows = try run("""
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ORDER BY INDEX_NAME <> 'PRIMARY', INDEX_NAME, SEQ_IN_INDEX
            """, [.text(name)]).rows
        var indexes: [Index] = []
        for row in rows {
            let name = row[0].display, column = row[2] == .null ? "(…)" : row[2].display
            if let last = indexes.last, last.name == name {
                indexes[indexes.count - 1] = Index(name: name, unique: last.unique, columns: last.columns + [column])
            } else {
                indexes.append(Index(name: name, unique: row[1].display == "0", columns: [column]))
            }
        }
        return indexes
    }

    /// The CREATE statement for a table or view, as SHOW CREATE gives it.
    func createStatement(of object: DatabaseObject) throws -> String? {
        let sql = object.kind == .view ? "SHOW CREATE VIEW " : "SHOW CREATE TABLE "
        let row = try run(sql + Database.quote(object.name)).rows.first
        guard let row, row.count > 1 else { return nil }
        return row[1].display
    }

    /// How many rows the table has, or how many of them match `filter`, a WHERE clause and its values.
    func rowCount(of name: String, filter: (sql: String, bindings: [Value])? = nil) throws -> Int {
        let sql = "SELECT COUNT(*) FROM \(Database.quote(name))" + (filter.map { " WHERE \($0.sql)" } ?? "")
        guard case .integer(let n)? = try run(sql, filter?.bindings ?? []).rows.first?.first else { return 0 }
        return Int(n)
    }

    // MARK: Rows

    /// The names the key columns go by at the front of a page, which no table's own column has.
    static func keyAlias(_ i: Int) -> String { "__menumysql_key\(i)" }

    /// A page of a table's rows, only those matching `filter` when there is one. With `keys`,
    /// those columns' values come first in each row, to find the row again when it's edited.
    /// An empty page still has the table's columns.
    func rows(of object: DatabaseObject, filter: (sql: String, bindings: [Value])? = nil,
              orderBy column: String?, ascending: Bool, limit: Int, offset: Int, keys: [String]) throws -> ResultSet {
        let select = keys.enumerated().map { "\(Database.quote($1)) AS \(Database.quote(Self.keyAlias($0)))" } + ["\(Database.quote(object.name)).*"]
        let condition = filter.map { " WHERE \($0.sql)" } ?? ""
        let order = column.map { " ORDER BY \(Database.quote($0)) \(ascending ? "ASC" : "DESC")" } ?? ""
        var page = try run("SELECT \(select.joined(separator: ", ")) FROM \(Database.quote(object.name))\(condition)\(order) LIMIT ? OFFSET ?",
                           (filter?.bindings ?? []) + [.integer(Int64(limit)), .integer(Int64(offset))])
        if page.columns.isEmpty {
            page.columns = keys.indices.map(Self.keyAlias) + (try columns(of: object.name)).map(\.name)
        }
        return page
    }

    /// WHERE terms that pick out one row by its key.
    private static func match(_ keys: [String], _ values: [Value]) -> String {
        zip(keys, values).map { $1 == .null ? "\(Database.quote($0)) IS NULL" : "\(Database.quote($0)) = \($1.sqlLiteral)" }
            .joined(separator: " AND ")
    }

    func update(_ table: String, column: String, to value: Value, keys: [String], key: [Value]) throws {
        try run("UPDATE \(Database.quote(table)) SET \(Database.quote(column)) = \(value.sqlLiteral) WHERE \(Self.match(keys, key)) LIMIT 1")
    }

    func deleteRows(from table: String, keys: [String], rows: [[Value]]) throws {
        guard !rows.isEmpty else { return }
        let terms = rows.map { "(" + Self.match(keys, $0) + ")" }.joined(separator: " OR ")
        try run("DELETE FROM \(Database.quote(table)) WHERE \(terms)")
    }
}
