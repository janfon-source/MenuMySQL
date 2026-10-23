import Foundation

/// The structure of a whole database, every table and view, written out as a Markdown document:
/// columns, keys, indexes, foreign keys, triggers and the CREATE statements.
enum SchemaDocument {
    static func markdown(for database: MySQLDatabase, date: Date = Date()) throws -> String {
        let objects = try database.objects()
        let tables = objects.filter { $0.kind == .table }
        let views = objects.filter { $0.kind == .view }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var out: [String] = []
        out.append("# " + tr("資料庫結構：\(database.name)", "Database Structure: \(database.name)"))
        out.append("")
        out.append("- " + tr("位置", "Location") + tr("：", ": ") + "`\(database.location)`")
        out.append("- " + tr("伺服器", "Server") + tr("：", ": ") + (database.isMariaDB ? "MariaDB " : "MySQL ") + database.version)
        out.append("- " + tr("產生時間", "Generated") + tr("：", ": ") + formatter.string(from: date))
        out.append("- " + tr("資料表 \(tables.count) 個，視圖 \(views.count) 個", "\(tables.count) table\(tables.count == 1 ? "" : "s"), \(views.count) view\(views.count == 1 ? "" : "s")"))

        if !objects.isEmpty {
            out.append("")
            out.append("## " + tr("目錄", "Contents"))
            out.append("")
            for object in tables { out.append("- " + tr("資料表", "Table") + " `\(object.name)`") }
            for object in views { out.append("- " + tr("視圖", "View") + " `\(object.name)`") }
        }

        if !tables.isEmpty {
            out.append("")
            out.append("## " + tr("資料表", "Tables"))
            for table in tables { out += try section(table, in: database) }
        }
        if !views.isEmpty {
            out.append("")
            out.append("## " + tr("視圖", "Views"))
            for view in views { out += try section(view, in: database) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func section(_ object: DatabaseObject, in database: MySQLDatabase) throws -> [String] {
        var out = ["", "### \(object.name)", ""]
        if object.kind == .table {
            out.append(tr("資料列：", "Rows: ") + String(try database.rowCount(of: object.name)))
            out.append("")
        }

        // A view over a table that's gone can't list its columns; say so and carry on.
        let columns: [Column]
        do {
            columns = try database.columns(of: object.name)
        } catch {
            out += ["> ⚠️ " + tr("無法讀取欄位：", "Couldn’t read the columns: ") + error.localizedDescription]
            if let sql = try? database.createStatement(of: object) {
                out += ["", "**" + tr("建立語句", "CREATE Statement") + "**", "", "```sql", sql, "```"]
            }
            return out
        }
        let unique = object.kind == .table ? Set(try database.indexes(of: object.name)
            .filter { $0.unique && $0.columns.count == 1 }.compactMap(\.columns.first)) : []
        if object.kind == .table {
            out += table(["#", tr("欄位", "Column"), tr("類型", "Type"), tr("非空", "Not Null"),
                          tr("唯一", "Unique"), tr("預設值", "Default"), tr("主鍵", "Key"), tr("其他", "Extra"), tr("註解", "Comment")], "rllccLcll",
                         columns.enumerated().map { i, column in [String(i + 1), "`\(column.name)`", column.type, column.notNull ? "✓" : "",
                                unique.contains(column.name) && column.primaryKey == 0 ? "✓" : "", column.defaultValue.map { "`\($0)`" } ?? "",
                                column.primaryKey > 0 ? String(column.primaryKey) : "",
                                [column.autoIncrement ? "AUTO_INCREMENT" : nil, column.onUpdate, column.generated].compactMap { $0 }.joined(separator: " "),
                                column.comment] })
        } else {
            out += table(["#", tr("欄位", "Column"), tr("類型", "Type")], "rll",
                         columns.enumerated().map { i, column in [String(i + 1), "`\(column.name)`", column.type] })
        }

        if object.kind == .table {
            let keys = try database.run("""
                SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
                FROM information_schema.KEY_COLUMN_USAGE k
                JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
                WHERE k.TABLE_SCHEMA = DATABASE() AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
                """, [.text(object.name)]).rows
            if !keys.isEmpty {
                out += ["", "**" + tr("外鍵", "Foreign Keys") + "**", ""]
                // One row per column; a key over several columns shares its name.
                out += table([tr("名稱", "Name"), tr("欄位", "Column"), tr("參照", "References"), "ON UPDATE", "ON DELETE"], "lllll",
                             keys.map { key in
                                 ["`\(key[0].display)`", "`\(key[1].display)`", "`\(key[2].display)`(`\(key[3].display)`)", key[4].display, key[5].display] })
            }

            let indexes = try database.indexes(of: object.name)
            if !indexes.isEmpty {
                out += ["", "**" + tr("索引", "Indexes") + "**", ""]
                out += table([tr("名稱", "Name"), tr("唯一", "Unique"), tr("欄位", "Columns")], "lcl",
                             indexes.map { index in ["`\(index.name)`", index.unique ? "✓" : "",
                                                     index.columns.map { "`\($0)`" }.joined(separator: ", ")] })
            }
        }

        let triggers = try database.run("""
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = ? ORDER BY TRIGGER_NAME
            """, [.text(object.name)]).rows
        if !triggers.isEmpty {
            out += ["", "**" + tr("觸發程序", "Triggers") + "**"]
            for trigger in triggers {
                let sql = "CREATE TRIGGER \(Database.quote(trigger[0].display)) \(trigger[1].display) \(trigger[2].display)"
                    + " ON \(Database.quote(object.name)) FOR EACH ROW\n" + trigger[3].display
                out += ["", "- `\(trigger[0].display)`", "", "```sql", sql, "```"]
            }
        }

        if let sql = try database.createStatement(of: object) {
            out += ["", "**" + tr("建立語句", "CREATE Statement") + "**", "", "```sql", sql, "```"]
        }
        return out
    }

    /// A Markdown table padded so its columns line up in plain text too, counting CJK characters
    /// as two columns wide. `align` has a letter per column: l, c or r (L is left too).
    private static func table(_ header: [String], _ align: String, _ rows: [[String]]) -> [String] {
        let cells = ([header] + rows).map { $0.map {
            $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        } }
        let alignments = Array(align)
        let widths = header.indices.map { i in max(3, cells.map { width($0[i]) }.max() ?? 0) }
        func line(_ row: [String]) -> String {
            "| " + row.enumerated().map { i, cell in
                let pad = String(repeating: " ", count: widths[i] - width(cell))
                switch alignments[i] {
                case "r": return pad + cell
                case "c": return String(pad.prefix(pad.count / 2)) + cell + String(pad.dropFirst(pad.count / 2))
                default: return cell + pad
                }
            }.joined(separator: " | ") + " |"
        }
        let rule = "|" + widths.enumerated().map { i, w in
            switch alignments[i] {
            case "r": return String(repeating: "-", count: w + 1) + ":"
            case "c": return ":" + String(repeating: "-", count: w) + ":"
            default: return String(repeating: "-", count: w + 2)
            }
        }.joined(separator: "|") + "|"
        return [line(cells[0]), rule] + cells.dropFirst().map(line)
    }

    /// How many columns the text takes in a monospaced font: East Asian characters take two.
    private static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
            return sum + (wide ? 2 : 1)
        }
    }
}
