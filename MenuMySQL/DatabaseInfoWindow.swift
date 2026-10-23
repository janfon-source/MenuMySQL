import AppKit

/// A window about the connection and the database in use: the server and its version, how it's
/// reached, the database's character set and size; with OPTIMIZE TABLE to give unused space back
/// and ANALYZE TABLE to bring the index statistics up to date.
final class DatabaseInfoWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let database: MySQLDatabase
    /// Called after the tables have been changed (OPTIMIZE rebuilds them), to refresh what shows.
    var onChange: (() -> Void)?

    private let grid = NSGridView()
    private let optimizeButton = NSButton()
    private let analyzeButton = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")

    init(database: MySQLDatabase) {
        self.database = database
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("資料庫資訊：\(database.name)", "Database Info: \(database.name)")
        panel.delegate = self
        build()
        reload()
    }

    var window: NSWindow { panel }

    /// Shows the window until it's closed.
    func run() {
        panel.center()
        NSApp.runModal(for: panel)
    }

    // MARK: Layout

    private func build() {
        grid.columnSpacing = 12
        grid.rowSpacing = 6

        let maintenance = NSTextField(labelWithString: tr("維護", "Maintenance"))
        maintenance.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        optimizeButton.title = tr("最佳化所有資料表（OPTIMIZE）", "Optimize All Tables (OPTIMIZE)")
        optimizeButton.bezelStyle = .rounded
        optimizeButton.target = self
        optimizeButton.action = #selector(optimize(_:))
        analyzeButton.title = tr("分析所有資料表（ANALYZE）", "Analyze All Tables (ANALYZE)")
        analyzeButton.bezelStyle = .rounded
        analyzeButton.target = self
        analyzeButton.action = #selector(analyze(_:))
        let hint = NSTextField(wrappingLabelWithString: tr(
            "OPTIMIZE 會重建每個資料表，把刪除資料後留下的空間還給系統並減少零碎（InnoDB 會改為重建再分析）；重建期間資料表可能暫時鎖住，大的資料庫要花一點時間。ANALYZE 只更新索引的統計資料，讓查詢計畫更準確，很快就好。",
            "OPTIMIZE rebuilds each table, giving back the space deleted rows left and undoing fragmentation (InnoDB recreates and analyzes instead); tables may be locked while it runs, and a large database takes a while. ANALYZE only updates the index statistics the query planner uses, and is quick."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let close = NSButton(title: tr("關閉", "Close"), target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\r"
        let closeRow = NSStackView(views: [NSView(), close])
        let actions = NSStackView(views: [optimizeButton, analyzeButton])

        let line = NSBox()
        line.boxType = .separator
        let stack = NSStackView(views: [grid, line, maintenance, actions, hint, message, closeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(14, after: line)
        stack.setCustomSpacing(14, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [grid, line, hint, message, closeRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            panel.contentView!.widthAnchor.constraint(equalToConstant: 520),
        ])
    }

    // MARK: Facts

    private struct Sizes {
        var tables = 0, views = 0, rows = 0, data = 0, index = 0, free = 0
    }

    /// What information_schema says of the database's tables. Its row counts are estimates for
    /// InnoDB, and its sizes are as of the last time the server looked.
    private func sizes() throws -> Sizes {
        let row = try database.run("""
            SELECT SUM(TABLE_TYPE <> 'VIEW'), SUM(TABLE_TYPE = 'VIEW'), SUM(TABLE_ROWS), SUM(DATA_LENGTH), SUM(INDEX_LENGTH), SUM(DATA_FREE)
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()
            """).rows.first ?? []
        func number(_ i: Int) -> Int {
            guard row.indices.contains(i) else { return 0 }
            switch row[i] {
            case .integer(let n): return Int(n)
            case .real(let d): return Int(d)
            case .text(let s): return Int(Double(s) ?? 0)
            default: return 0
            }
        }
        return Sizes(tables: number(0), views: number(1), rows: number(2), data: number(3), index: number(4), free: number(5))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return formatter
    }()

    private static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    private func reload() {
        // Removing a grid's rows leaves their views behind; take those out too.
        for view in grid.subviews { view.removeFromSuperview() }
        for _ in 0..<grid.numberOfRows { grid.removeRow(at: 0) }
        func row(_ title: String, _ value: String, selectable: Bool = false) {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(wrappingLabelWithString: value)
            field.isSelectable = selectable
            field.preferredMaxLayoutWidth = 370   // the window less its margins and the labels
            grid.addRow(with: [label, field])
        }
        let server = database.server
        row(tr("資料庫", "Database"), database.current ?? tr("（未選擇）", "(none chosen)"), selectable: true)
        row(tr("伺服器", "Server"), (database.isMariaDB ? "MariaDB " : "MySQL ") + database.version, selectable: true)
        row(tr("主機", "Host"), "\(server.host):\(server.port)", selectable: true)
        if server.usesSSH { row(tr("SSH 通道", "SSH Tunnel"), server.sshDestination ?? "", selectable: true) }
        row(tr("加密", "Encryption"), database.usesTLS ? "TLS" : server.usesSSH ? tr("SSH 通道", "SSH tunnel") : tr("無", "None"))
        do {
            let facts = try database.run("SELECT CURRENT_USER(), @@character_set_database, @@collation_database, @@hostname, @@time_zone, @@max_allowed_packet")
                .rows.first ?? []
            func fact(_ i: Int) -> String { facts.indices.contains(i) ? facts[i].display : "" }
            row(tr("登入帳號", "Signed In As"), fact(0), selectable: true)
            row(tr("伺服器名稱", "Server Name"), fact(3), selectable: true)
            if database.current != nil {
                row(tr("字元集", "Character Set"), "\(fact(1)) / \(fact(2))")
                let sizes = try sizes()
                row(tr("資料表", "Tables"), tr("\(sizes.tables) 個資料表，\(sizes.views) 個視圖，約 \(sizes.rows) 列",
                                                "\(sizes.tables) tables, \(sizes.views) views, about \(sizes.rows) rows"))
                row(tr("大小", "Size"), Self.bytes(sizes.data + sizes.index)
                    + tr("（資料 \(Self.bytes(sizes.data))，索引 \(Self.bytes(sizes.index))）", " (data \(Self.bytes(sizes.data)), indexes \(Self.bytes(sizes.index)))"))
                row(tr("未使用的空間", "Unused Space"), Self.bytes(sizes.free) + tr("（OPTIMIZE 可以回收一部分）", " (OPTIMIZE gives some of it back)"))
            }
            row(tr("時區", "Time Zone"), fact(4))
            row(tr("封包上限", "Max Packet"), Self.bytes(Int(fact(5)) ?? 0))
        } catch {
            row(tr("錯誤", "Error"), error.localizedDescription)
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 96
        optimizeButton.isEnabled = database.current != nil
        analyzeButton.isEnabled = database.current != nil
    }

    private func show(_ text: String, error: Bool) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: Actions

    @objc private func optimize(_ sender: Any?) {
        run("OPTIMIZE", working: tr("正在最佳化…", "Optimizing…"), done: tr("已最佳化", "Optimized"))
    }

    @objc private func analyze(_ sender: Any?) {
        run("ANALYZE", working: tr("正在分析…", "Analyzing…"), done: tr("已分析", "Analyzed"))
    }

    /// Runs OPTIMIZE or ANALYZE TABLE over every table, saying how the size changed and which
    /// tables the server had something to say about.
    private func run(_ verb: String, working: String, done: String) {
        let tables = ((try? database.objects()) ?? []).filter { $0.kind == .table }
        guard !tables.isEmpty else { return show(tr("沒有資料表。", "There are no tables."), error: false) }
        let before = (try? sizes()).map { $0.data + $0.index }
        show(working, error: false)
        optimizeButton.isEnabled = false
        analyzeButton.isEnabled = false
        panel.display()   // the statement holds this thread; show the message first
        do {
            let result = try database.run("\(verb) TABLE " + tables.map { Database.quote($0.name) }.joined(separator: ", "))
            // Each table says "status OK", or an error or warning, or that it was recreated instead.
            let problems = result.rows.filter { $0.count >= 4 && ["error", "warning"].contains($0[2].display.lowercased()) }
                .map { "\($0[0].display): \($0[3].display)" }
            reload()
            let after = (try? sizes()).map { $0.data + $0.index }
            var text = done
            if verb == "OPTIMIZE", let before, let after {
                text += tr("：\(Self.bytes(before)) → \(Self.bytes(after))", ": \(Self.bytes(before)) → \(Self.bytes(after))")
            }
            if !problems.isEmpty { text += "\n" + problems.joined(separator: "\n") }
            show(text, error: !problems.isEmpty)
            onChange?()
        } catch {
            reload()
            show(error.localizedDescription, error: true)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        panel.close()
    }

    /// Closed by its button or the title bar's: either way the modal session ends.
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
