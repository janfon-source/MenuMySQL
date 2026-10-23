import AppKit

/// A window for designing a new table or changing one: its name, a row per column with type,
/// length, key, NOT NULL, UNIQUE, AUTO_INCREMENT, default and comment (dragged by the handle at
/// the left to reorder), and a row per index with its kind and columns. The SQL it will run shows below as it's edited, with any warning, such as a
/// column's data being deleted.
final class TableEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let snapshot: TableSnapshot?
    private var columns: [ColumnDraft]
    private var indexes: [IndexDraft]
    private let nameField = NSTextField()
    private let table = NSTableView()
    private let indexTable = NSTableView()
    private var removeIndexButton: NSButton!
    private let message = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView.scrollableTextView()
    private var previewText: NSTextView { preview.documentView as! NSTextView }
    private var saveButton: NSButton!
    private var removeButton: NSButton!
    private var upButton: NSButton!
    private var downButton: NSButton!

    /// The SQL to run, once the window closes with Save.
    private(set) var sql: String?
    /// The table's name as entered, to select it once it's made.
    var tableName: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    private enum Field: String, CaseIterable {
        case handle, name, type, length, primaryKey, notNull, unique, autoincrement, defaultValue, comment
        var title: String {
            switch self {
            case .handle: return ""
            case .name: return tr("名稱", "Name")
            case .type: return tr("類型", "Type")
            case .length: return tr("長度", "Length")
            case .primaryKey: return tr("主鍵", "Key")
            case .notNull: return tr("非空", "Not Null")
            case .unique: return tr("唯一", "Unique")
            case .autoincrement: return tr("自動遞增", "Auto Inc.")
            case .defaultValue: return tr("預設值", "Default")
            case .comment: return tr("註解", "Comment")
            }
        }
        var width: CGFloat {
            switch self {
            case .handle: return 22
            case .name: return 120
            case .type: return 130
            case .length: return 80
            case .primaryKey, .notNull, .unique: return 44
            case .autoincrement: return 60
            case .defaultValue: return 100
            case .comment: return 130
            }
        }
    }

    private enum IndexField: String, CaseIterable {
        case indexName, kind, indexColumns
        var title: String {
            switch self {
            case .indexName: return tr("索引名稱", "Index Name")
            case .kind: return tr("類型", "Kind")
            case .indexColumns: return tr("欄位（可加長度或 DESC，例如 title(20), created DESC）", "Columns (with a length or DESC, e.g. title(20), created DESC)")
            }
        }
        var width: CGFloat {
            switch self {
            case .indexName: return 170
            case .kind: return 110
            case .indexColumns: return 460
            }
        }
    }

    /// For a new table, `snapshot` is nil.
    init(snapshot: TableSnapshot?) {
        self.snapshot = snapshot
        columns = snapshot?.columns ?? [ColumnDraft(name: "id", type: "INT UNSIGNED", primaryKey: true, notNull: true, autoincrement: true)]
        indexes = snapshot?.indexes ?? []
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = snapshot == nil ? tr("新增資料表", "New Table") : tr("編輯資料表「\(snapshot!.name)」", "Edit Table “\(snapshot!.name)”")
        panel.minSize = NSSize(width: 760, height: 600)
        build()
        update()
    }

    var window: NSWindow { panel }

    /// Shows the window until it's closed; true if Save was clicked.
    func run() -> Bool {
        panel.center()
        panel.makeFirstResponder(snapshot == nil ? nameField : table)
        return NSApp.runModal(for: panel) == .OK
    }

    // MARK: Layout

    private func build() {
        nameField.stringValue = snapshot?.name ?? ""
        nameField.placeholderString = tr("資料表名稱", "Table name")
        nameField.delegate = self
        let nameRow = NSStackView(views: [NSTextField(labelWithString: tr("名稱", "Name")), nameField])

        for field in Field.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = field.width * 0.6
            if field == .handle {
                column.minWidth = field.width
                column.maxWidth = field.width
                column.headerToolTip = tr("拖曳這裡可以調整欄位順序", "Drag here to reorder the columns")
            }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        // Rows are dragged by the handle (or anywhere not taken by a control) into a new order.
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!,
                                  target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tr(zh, en)
            return button
        }
        removeButton = button("minus", "刪除欄位", "Remove Column", #selector(removeColumn(_:)))
        upButton = button("arrow.up", "上移", "Move Up", #selector(moveUp(_:)))
        downButton = button("arrow.down", "下移", "Move Down", #selector(moveDown(_:)))
        let columnButtons = NSStackView(views: [button("plus", "新增欄位", "Add Column", #selector(addColumn(_:))),
                                                removeButton, upButton, downButton, NSView()])
        columnButtons.spacing = 4

        // The indexes: the key and single-column unique ones are the checkboxes above.
        for field in IndexField.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = field == .kind ? 100 : 120
            indexTable.addTableColumn(column)
        }
        indexTable.dataSource = self
        indexTable.delegate = self
        indexTable.rowHeight = 30
        indexTable.usesAlternatingRowBackgroundColors = true
        indexTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let indexScroll = NSScrollView()
        indexScroll.documentView = indexTable
        indexScroll.hasVerticalScroller = true
        indexScroll.borderType = .bezelBorder
        indexScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let indexTitle = NSTextField(labelWithString: tr("索引", "Indexes"))
        indexTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let indexHint = NSTextField(labelWithString: tr("主鍵和單一欄位的唯一索引，用上方欄位的「主鍵」「唯一」勾選。",
                                                        "The key and single-column unique indexes are the Key and Unique boxes above."))
        indexHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        indexHint.textColor = .secondaryLabelColor
        indexHint.lineBreakMode = .byTruncatingTail
        indexHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let indexHeader = NSStackView(views: [indexTitle, indexHint])
        indexHeader.alignment = .firstBaseline
        removeIndexButton = button("minus", "刪除索引", "Remove Index", #selector(removeIndex(_:)))
        let indexButtons = NSStackView(views: [button("plus", "新增索引", "Add Index", #selector(addIndex(_:))), removeIndexButton, NSView()])
        indexButtons.spacing = 4

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewText.isEditable = false
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        preview.borderType = .bezelBorder
        preview.hasVerticalScroller = true
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true

        saveButton = NSButton(title: snapshot == nil ? tr("建立", "Create") : tr("儲存", "Save"), target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, saveButton])

        let stack = NSStackView(views: [nameRow, tableScroll, columnButtons, indexHeader, indexScroll, indexButtons, message,
                                        NSTextField(labelWithString: tr("將執行的 SQL", "SQL to Run")), preview, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        stack.setCustomSpacing(14, after: columnButtons)
        for view in [nameRow, tableScroll, columnButtons, indexHeader, indexScroll, indexButtons, message, preview, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    // MARK: The column table

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === indexTable ? indexes.count : columns.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === indexTable { return indexCell(tableColumn, row: row) }
        guard let field = tableColumn.flatMap({ Field(rawValue: $0.identifier.rawValue) }) else { return nil }
        let column = columns[row]
        switch field {
        case .handle:
            let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal",
                                                  accessibilityDescription: tr("拖曳以調整順序", "Drag to reorder"))!)
            grip.contentTintColor = .tertiaryLabelColor
            grip.toolTip = tr("拖曳以調整順序", "Drag to reorder")
            return centered(grip)
        case .length:
            let parts = TableDesign.split(column.type)
            let text = NSTextField(string: parts.length)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = TableDesign.lengthHint(for: parts.base)
            text.isEditable = !TableDesign.lengthless.contains(parts.base.split(separator: " ").first.map { $0.uppercased() } ?? "")
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            return centered(text, fill: true)
        case .primaryKey, .notNull, .unique, .autoincrement:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            let on = [Field.primaryKey: column.primaryKey, .notNull: column.notNull || column.primaryKey,
                      .unique: column.unique, .autoincrement: column.autoincrement][field] ?? false
            box.state = on ? .on : .off
            // A key can't be NULL, and a generated column's value isn't set by these.
            box.isEnabled = !(field == .notNull && column.primaryKey) && (column.generated == nil || field == .primaryKey || field == .unique)
            return centered(box)
        case .type:
            let combo = NSComboBox()
            combo.addItems(withObjectValues: TableDesign.types)
            combo.stringValue = TableDesign.split(column.type).base
            combo.isBordered = false
            combo.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            combo.delegate = self
            return centered(combo, fill: true)
        case .name, .defaultValue, .comment:
            let text = NSTextField(string: field == .name ? column.name : field == .comment ? column.comment
                                   : column.generated.map { _ in tr("（產生的欄位）", "(generated)") } ?? column.defaultValue)
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = !(field == .defaultValue && column.generated != nil)
            text.placeholderString = field == .defaultValue ? tr("（無）", "(none)") : nil
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            return centered(text, fill: true)
        }
    }

    /// Centered in its cell, vertically and either horizontally (checkboxes) or across its width.
    private func centered(_ view: NSView, fill: Bool = false) -> NSView {
        let holder = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate(fill
            ? [view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
               view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
               view.centerYAnchor.constraint(equalTo: holder.centerYAnchor)]
            : [view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
               view.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
        return holder
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func toggled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard columns.indices.contains(row), let field = sender.identifier.flatMap({ Field(rawValue: $0.rawValue) }) else { return }
        let on = sender.state == .on
        switch field {
        case .primaryKey: columns[row].primaryKey = on
        case .notNull: columns[row].notNull = on
        case .unique: columns[row].unique = on
        case .autoincrement: columns[row].autoincrement = on
        default: break
        }
        if field == .primaryKey {
            columns[row].notNull = columns[row].notNull || on
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        update()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField { return update() }
        if let indexField = field.identifier.flatMap({ IndexField(rawValue: $0.rawValue) }) {
            let row = indexTable.row(for: field)
            guard indexes.indices.contains(row) else { return }
            if indexField == .indexName { indexes[row].name = field.stringValue.trimmingCharacters(in: .whitespaces) }
            else { indexes[row].columns = IndexDraft.columns(from: field.stringValue) }
            return update()
        }
        let row = table.row(for: field)
        guard columns.indices.contains(row) else { return }
        switch field.identifier?.rawValue {
        case Field.name.rawValue:
            renameInIndexes(columns[row].name, to: field.stringValue)
            columns[row].name = field.stringValue
        case Field.type.rawValue:
            columns[row].type = TableDesign.join(field.stringValue, TableDesign.split(columns[row].type).length)
            reloadLength(of: row)
        case Field.length.rawValue: columns[row].type = TableDesign.join(TableDesign.split(columns[row].type).base, field.stringValue)
        case Field.defaultValue.rawValue: columns[row].defaultValue = field.stringValue
        case Field.comment.rawValue: columns[row].comment = field.stringValue
        default: break
        }
        update()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        let row = table.row(for: combo)
        guard columns.indices.contains(row) else { return }
        let old = TableDesign.split(columns[row].type), base = TableDesign.types[combo.indexOfSelectedItem]
        columns[row].type = TableDesign.join(base, TableDesign.length(changingType: old.base, to: base, from: old.length))
        reloadLength(of: row)
        update()
    }

    /// Shows the row's length again, after its type changed: a new one, or a field that's off.
    private func reloadLength(of row: Int) {
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == Field.length.rawValue }) else { return }
        table.reloadData(forRowIndexes: [row], columnIndexes: [column])
    }

    // MARK: Dragging into order

    private static let rowType = NSPasteboard.PasteboardType("com.jeff.menumysql.column-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === table else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, info.draggingSource as? NSTableView === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)   // between rows, never onto one
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === table, let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(text) else { return false }
        return moveColumn(from: from, to: row)
    }

    /// Moves a column to before the row at `to` (or to the end); false if it stays where it was.
    @discardableResult
    func moveColumn(from: Int, to row: Int) -> Bool {
        guard columns.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        guard to != from, columns.indices.contains(to) else { return false }
        panel.makeFirstResponder(nil)   // the text typed so far counts
        columns.insert(columns.remove(at: from), at: to)
        table.reloadData()
        table.selectRowIndexes([to], byExtendingSelection: false)
        update()
        return true
    }

    // MARK: Adding and moving columns

    @objc private func addColumn(_ sender: Any?) {
        var name = tr("新欄位", "column"), n = 1
        while columns.contains(where: { $0.name == name }) { n += 1; name = tr("新欄位\(n)", "column\(n)") }
        columns.append(ColumnDraft(name: name, type: "VARCHAR(255)"))
        table.reloadData()
        let row = columns.count - 1
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(table.column(withIdentifier: NSUserInterfaceItemIdentifier(Field.name.rawValue)), row: row, with: nil, select: true)
        update()
    }

    @objc private func removeColumn(_ sender: Any?) {
        let row = table.selectedRow
        guard columns.indices.contains(row) else { return }
        // Its indexes lose it, as MySQL drops it from them; an index left with no column goes too.
        let removed = columns.remove(at: row).name
        for i in indexes.indices { indexes[i].columns.removeAll { IndexDraft.column(of: $0) == removed } }
        indexes.removeAll { $0.columns.isEmpty }
        indexTable.reloadData()
        table.reloadData()
        if !columns.isEmpty { table.selectRowIndexes([min(row, columns.count - 1)], byExtendingSelection: false) }
        update()
    }

    @objc private func moveUp(_ sender: Any?) { move(by: -1) }
    @objc private func moveDown(_ sender: Any?) { move(by: 1) }

    private func move(by step: Int) {
        let row = table.selectedRow, target = row + step
        guard columns.indices.contains(row), columns.indices.contains(target) else { return }
        columns.swapAt(row, target)
        table.reloadData()
        table.selectRowIndexes([target], byExtendingSelection: false)
        update()
    }

    // MARK: Indexes

    private func indexCell(_ tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let field = tableColumn.flatMap({ IndexField(rawValue: $0.identifier.rawValue) }) else { return nil }
        let index = indexes[row]
        switch field {
        case .kind:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.addItems(withTitles: IndexDraft.Kind.allCases.map(\.rawValue))
            popUp.selectItem(withTitle: index.kind.rawValue)
            popUp.target = self
            popUp.action = #selector(kindChanged(_:))
            return centered(popUp, fill: true)
        case .indexName, .indexColumns:
            let text = NSTextField(string: field == .indexName ? index.name : index.columnsText)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = field == .indexName ? tr("（自動命名）", "(named for you)") : tr("例如 name, created DESC", "e.g. name, created DESC")
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            guard field == .indexColumns else { return centered(text, fill: true) }
            // Beside the columns, a menu of the table's columns to tick in or out.
            let pick = NSButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: tr("選擇欄位", "Choose Columns"))!,
                                target: self, action: #selector(showIndexColumns(_:)))
            pick.isBordered = false
            pick.toolTip = tr("選擇欄位", "Choose Columns")
            pick.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            return centered(NSStackView(views: [text, pick]), fill: true)
        }
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        let row = indexTable.row(for: sender)
        guard indexes.indices.contains(row), let kind = sender.titleOfSelectedItem.flatMap(IndexDraft.Kind.init(rawValue:)) else { return }
        indexes[row].kind = kind
        update()
    }

    @objc private func showIndexColumns(_ sender: NSButton) {
        let row = indexTable.row(for: sender)
        guard indexes.indices.contains(row) else { return }
        indexTable.selectRowIndexes([row], byExtendingSelection: false)
        panel.makeFirstResponder(nil)   // the text typed so far counts
        let menu = NSMenu()
        let used = indexes[row].columns.map(IndexDraft.column(of:))
        for column in columns where !column.name.isEmpty {
            let item = menu.addItem(withTitle: column.name, action: #selector(toggleIndexColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = used.contains(column.name) ? .on : .off
            item.tag = row
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Adds the column at the end of the index, or takes it out.
    @objc private func toggleIndexColumn(_ sender: NSMenuItem) {
        let row = sender.tag
        guard indexes.indices.contains(row) else { return }
        if sender.state == .on {
            indexes[row].columns.removeAll { IndexDraft.column(of: $0) == sender.title }
        } else {
            indexes[row].columns.append(sender.title)
        }
        indexTable.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<indexTable.numberOfColumns))
        update()
    }

    @objc private func addIndex(_ sender: Any?) {
        var name = "idx", n = 1
        let taken = Set(indexes.map { $0.name.lowercased() } + (snapshot?.uniqueIndexes.values.map { $0.lowercased() } ?? []))
        while taken.contains(name) { n += 1; name = "idx\(n)" }
        // Starting from the column selected above, if one is.
        let start = columns.indices.contains(table.selectedRow) ? [columns[table.selectedRow].name] : []
        indexes.append(IndexDraft(name: name, columns: start))
        indexTable.reloadData()
        let row = indexes.count - 1
        indexTable.selectRowIndexes([row], byExtendingSelection: false)
        indexTable.scrollRowToVisible(row)
        indexTable.editColumn(0, row: row, with: nil, select: true)
        update()
    }

    @objc private func removeIndex(_ sender: Any?) {
        let row = indexTable.selectedRow
        guard indexes.indices.contains(row) else { return }
        indexes.remove(at: row)
        indexTable.reloadData()
        if !indexes.isEmpty { indexTable.selectRowIndexes([min(row, indexes.count - 1)], byExtendingSelection: false) }
        update()
    }

    /// A column renamed in the grid keeps its place in the indexes.
    private func renameInIndexes(_ old: String, to new: String) {
        guard old != new, !old.isEmpty else { return }
        var changed = false
        for i in indexes.indices {
            for j in indexes[i].columns.indices where IndexDraft.column(of: indexes[i].columns[j]) == old {
                indexes[i].columns[j] = IndexDraft.renaming(indexes[i].columns[j], to: new)
                changed = true
            }
        }
        if changed { indexTable.reloadData() }
    }

    private func updateButtons() {
        removeIndexButton?.isEnabled = indexes.indices.contains(indexTable.selectedRow)
        let row = table.selectedRow
        removeButton.isEnabled = row >= 0
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < columns.count - 1
    }

    // MARK: SQL

    /// Remakes the SQL preview and the message, and enables Save when there's something valid to do.
    private func update() {
        updateButtons()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if let problem = TableDesign.problem(name: name, columns: columns, indexes: indexes) {
            show(sql: "", message: problem, error: true)
            return
        }
        guard let snapshot else {
            show(sql: TableDesign.createSQL(name: name, columns: columns, indexes: indexes), message: "", error: false)
            return
        }
        let change = TableDesign.alterSQL(snapshot, newName: name, columns: columns, indexes: indexes)
        let unchanged = change.sql.isEmpty
        show(sql: unchanged ? "" : change.sql,
             message: unchanged ? tr("沒有變更。", "Nothing has changed.") : change.warnings.joined(separator: "\n"),
             error: false, canSave: !unchanged)
    }

    private func show(sql: String, message text: String, error: Bool, canSave: Bool? = nil) {
        let attributed = NSMutableAttributedString(string: sql, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor])
        SyntaxHighlighter.highlight(attributed, language: "sql")
        previewText.textStorage?.setAttributedString(attributed)
        message.stringValue = text
        message.textColor = error ? .systemRed : .systemOrange
        message.isHidden = text.isEmpty
        saveButton.isEnabled = canSave ?? !error
        self.sql = sql.isEmpty ? nil : sql
    }

    @objc private func save(_ sender: Any?) {
        panel.makeFirstResponder(nil)   // finish the cell being typed in
        update()
        guard sql != nil, saveButton.isEnabled else { return NSSound.beep() }
        NSApp.stopModal(withCode: .OK)
        panel.orderOut(nil)
    }

    /// The title bar's close button: the same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    @objc private func cancel(_ sender: Any?) {
        sql = nil
        NSApp.stopModal(withCode: .cancel)
        panel.orderOut(nil)
    }
}
