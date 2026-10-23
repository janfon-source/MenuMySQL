// Checks the database layer against live servers. Run from MenuMySQLMac/:
//   tests/run.sh            (MySQL on 127.0.0.1:23306 and MariaDB on 127.0.0.1:13306, user tester)
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if !ok { failures += 1; print("  ✗ \(what) (line \(line))") }
}
func expect<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    if a != b { failures += 1; print("  ✗ \(what): got \(a), expected \(b) (line \(line))") }
}

let password = "p@ss 中文"
let ports = CommandLine.arguments.dropFirst().compactMap { Int($0) }

for port in ports.isEmpty ? [23306, 13306] : ports {
    // Without TLS first: with nothing cached yet, caching_sha2_password sends the password
    // encrypted with the server's RSA key.
    for tls in [MySQLWire.TLSMode.disabled, .preferred, .required] {
        var location = ServerLocation()
        location.port = port
        location.user = "tester"
        location.tls = tls
        do {
            let db = try MySQLDatabase(location, password: password)
            print("\(port) \(tls): \(db.isMariaDB ? "MariaDB" : "MySQL") \(db.version) TLS=\(db.usesTLS)")
            expect(db.usesTLS, tls != .disabled, "TLS in use")
            db.close()
        } catch {
            failures += 1
            print("  ✗ \(port) \(tls): \(error.localizedDescription)")
        }
    }
    // A wrong password is refused with the server's words.
    var wrong = ServerLocation()
    wrong.port = port
    wrong.user = "tester"
    do { _ = try MySQLDatabase(wrong, password: "nope"); check(false, "wrong password accepted") }
    catch { check(error.localizedDescription.contains("1045"), "wrong password error: \(error.localizedDescription)") }

    var location = ServerLocation()
    location.port = port
    location.user = "tester"
    location.tls = .disabled   // the full caching_sha2 exchange without TLS, over RSA
    let db: MySQLDatabase
    do { db = try MySQLDatabase(location, password: password) } catch { print("  ✗ connect: \(error)"); failures += 1; continue }
    do {
        try db.run("DROP DATABASE IF EXISTS menumysql_test")
        try db.run("CREATE DATABASE menumysql_test CHARACTER SET utf8mb4")
        try db.use("menumysql_test")
        expect(db.current, "menumysql_test", "current database")
        check(try db.databases().contains("menumysql_test"), "SHOW DATABASES lists it")

        // Creating a table from the designer's SQL.
        let draft = [ColumnDraft(name: "id", type: "INT UNSIGNED", primaryKey: true, notNull: true, autoincrement: true),
                     ColumnDraft(name: "名稱", type: "VARCHAR(100)", notNull: true, defaultValue: "無名"),
                     ColumnDraft(name: "price", type: "DECIMAL(10,2)", defaultValue: "0"),
                     ColumnDraft(name: "code", type: "VARCHAR(20)", unique: true),
                     ColumnDraft(name: "made", type: "TIMESTAMP", defaultValue: "CURRENT_TIMESTAMP", comment: "建立時間"),
                     ColumnDraft(name: "data", type: "BLOB")]
        try TableDesign.apply(TableDesign.createSQL(name: "items", columns: draft), to: db)
        expect(try db.objects(), [DatabaseObject(name: "items", kind: .table)], "objects")
        let columns = try db.columns(of: "items")
        expect(columns.map(\.name), ["id", "名稱", "price", "code", "made", "data"], "column names")
        expect(columns[0].primaryKey, 1, "id is the key")
        check(columns[0].autoIncrement, "id auto_increment")
        expect(columns[1].defaultValue, "'無名'", "text default read back quoted")
        expect(columns[2].defaultValue, "0.00", "decimal default")
        check(columns[4].defaultValue?.uppercased().hasPrefix("CURRENT_TIMESTAMP") == true, "timestamp default: \(columns[4].defaultValue ?? "nil")")
        expect(columns[4].comment, "建立時間", "comment")
        expect(try db.primaryKey(of: "items"), ["id"], "primary key")

        // Rows: inserting, binding odd text, reading types back.
        let id = try db.insertRow(into: "items")
        expect(id, 1, "insert id")
        let tricky = "it's \\ a \"test\" ? 中文 😀"
        try db.run("INSERT INTO items (`名稱`, price, code, data) VALUES (?, ?, ?, ?)",
                   [.text(tricky), .real(12.5), .text("A?"), .blob(Data([0, 1, 2, 255]))])
        let page = try db.rows(of: DatabaseObject(name: "items", kind: .table), orderBy: "id", ascending: true, limit: 10, offset: 0, keys: ["id"])
        expect(page.columns.first, MySQLDatabase.keyAlias(0), "key column first")
        expect(page.rows.count, 2, "two rows")
        expect(page.rows[1][0], .integer(2), "key value")
        expect(page.rows[1][2], .text(tricky), "text round trip")
        expect(page.rows[1][3], .text("12.50"), "decimal as text")
        expect(page.rows[1][6], .blob(Data([0, 1, 2, 255])), "blob round trip")
        expect(page.rows[0][4], .null, "NULL")

        // Editing by key, and filtering.
        try db.update("items", column: "名稱", to: .text("改過 'x'"), keys: ["id"], key: [.integer(1)])
        expect(try db.run("SELECT `名稱` FROM items WHERE id = 1").rows.first?.first, .text("改過 'x'"), "update by key")
        expect(try db.rowCount(of: "items", filter: ("`名稱` LIKE ?", [.text("%中文%")])), 1, "filtered count")
        try db.deleteRows(from: "items", keys: ["id"], rows: [[.integer(1)]])
        expect(try db.rowCount(of: "items"), 1, "delete by key")

        // Several statements at once: the last result, and the rows they changed.
        let multi = try db.run("INSERT INTO items (code) VALUES ('b'), ('c'); UPDATE items SET price = 1; SELECT COUNT(*) AS n FROM items")
        expect(multi.columns, ["n"], "multi columns")
        expect(multi.rows.first?.first, .integer(3), "multi rows")
        expect(multi.changes, 5, "multi changes")
        // An error in the middle stops there.
        do { try db.run("SELECT 1; SELECT * FROM nowhere; SELECT 2"); check(false, "error swallowed") }
        catch { check(error.localizedDescription.contains("nowhere"), "error text: \(error.localizedDescription)") }
        expect(try db.run("SELECT 7").rows.first?.first, .integer(7), "usable after an error")

        // Changing the table: rename a column, add one in the middle, reorder, drop one, unique off.
        let snapshot = try TableDesign.snapshot(of: "items", in: db)
        var edited = snapshot.columns
        edited[1].name = "title"
        edited[3].unique = false
        edited.remove(at: 5)   // data
        edited.insert(ColumnDraft(name: "qty", type: "INT", notNull: true, defaultValue: "1"), at: 2)
        edited.swapAt(3, 4)    // price after code
        let change = TableDesign.alterSQL(snapshot, newName: "goods", columns: edited)
        check(!change.warnings.isEmpty, "dropping warns")
        try TableDesign.apply(change.sql, to: db)
        expect(try db.columns(of: "goods").map(\.name), ["id", "title", "qty", "code", "price", "made"], "columns after ALTER")
        expect(try db.indexes(of: "goods").map(\.name), ["PRIMARY"], "unique index dropped")
        expect(try db.run("SELECT title FROM goods WHERE id = 2").rows.first?.first, .text(tricky), "data follows rename")
        let unchanged = try TableDesign.snapshot(of: "goods", in: db)
        expect(TableDesign.alterSQL(unchanged, newName: "goods", columns: unchanged.columns).sql, "", "no change, no SQL")
        // Key change: a two-column key.
        var keyed = unchanged.columns
        keyed[0].autoincrement = false
        keyed[3].primaryKey = true
        keyed[3].notNull = true
        try db.run("UPDATE goods SET code = CONCAT('c', id)")
        try TableDesign.apply(TableDesign.alterSQL(unchanged, newName: "goods", columns: keyed).sql, to: db)
        expect(try db.primaryKey(of: "goods"), ["id", "code"], "two-column key")

        // Views.
        try db.run(ViewDesign.sql(name: "cheap", columns: "", select: "SELECT id, title FROM goods WHERE price < 5;"))
        let view = DatabaseObject(name: "cheap", kind: .view)
        let parts = ViewDesign.parts(of: try db.createStatement(of: view) ?? "")
        check(parts.select.lowercased().hasPrefix("select"), "view's select: \(parts.select)")
        try db.run(ViewDesign.sql(name: "cheap2", columns: "a, b", select: parts.select, replacing: "cheap"))
        expect(try db.objects().map(\.name), ["goods", "cheap2"], "renamed view")
        expect(try ViewDesign.preview("SELECT * FROM cheap2", in: db).columns, ["a", "b"], "view preview")

        // Structure document runs through everything.
        try db.run("CREATE TABLE child (id INT PRIMARY KEY, gid INT UNSIGNED, gcode VARCHAR(20), CONSTRAINT fk_g FOREIGN KEY (gid, gcode) REFERENCES goods(id, code) ON DELETE CASCADE)")
        try db.run("CREATE TRIGGER t_child BEFORE INSERT ON child FOR EACH ROW SET NEW.gid = NEW.gid")
        let doc = try SchemaDocument.markdown(for: db)
        check(doc.contains("fk_g") && doc.contains("CASCADE") && doc.contains("t_child"), "document has keys and triggers")

        // CSV import statements.
        var plan = CSVImport(table: "child", columns: try db.columns(of: "child"), sources: [0, 1, nil], rows: (10..<1210).map { ["\($0)", "2"] })
        plan.replace = true
        for statement in plan.statements { try db.run(statement) }
        expect(try db.rowCount(of: "child"), 1200, "imported rows")

        // A connection the server drops fails once, and is made again for the next statement,
        // in the same database.
        let before = try db.run("SELECT CONNECTION_ID()").rows.first?.first
        _ = try? db.run("KILL CONNECTION_ID()")
        _ = try? db.run("SELECT 1")
        let after = try db.run("SELECT CONNECTION_ID(), DATABASE()").rows.first
        check(after?.first != before, "a new connection")
        expect(after?.last, .text("menumysql_test"), "same database after reconnecting")
    } catch {
        failures += 1
        print("  ✗ \(port): \(error.localizedDescription)")
    }
    _ = try? db.run("DROP DATABASE IF EXISTS menumysql_test")
}

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
