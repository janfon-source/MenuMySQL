import AppKit

/// A window for designing a new table, or the Edit tab's editor for changing one: its name, a row per column with type,
/// length, key, NOT NULL, UNIQUE, BINARY, UNSIGNED, ZEROFILL, AUTO_INCREMENT, generated, default and comment (dragged by
/// the handle at the left to reorder), a row per index with its kind and columns, and a row per foreign key. Any warning,
/// such as a column's data being deleted, shows below, and the SQL it will run behind a button there.
final class TableEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate, NSWindowDelegate {
    /// The window of a new table's editor; nil for one in the Edit tab.
    private let panel: NSPanel?
    /// Everything the editor shows: the window's content, or the Edit tab's.
    let view = NSView()
    /// For an editor in the Edit tab: Save hands it the SQL and the name, and Cancel becomes Revert.
    private let onSave: ((_ sql: String, _ name: String) -> Void)?
    private let snapshot: TableSnapshot?
    private var columns: [ColumnDraft]
    private var indexes: [IndexDraft]
    private var foreignKeys: [ForeignKeyDraft]
    /// The collation a column without one of its own has: the table's, or the database's for a new table.
    private let tableCollation: String?
    /// The tables a foreign key can refer to, and how to read one's columns (kept once read).
    private let tables: [String]
    private let columnsOf: ((String) -> [Column])?
    private var columnCache: [String: [Column]] = [:]
    private let nameField = NSTextField()
    private let table = NSTableView()
    private let indexTable = NSTableView()
    private let keyTable = NSTableView()
    private var removeIndexButton: NSButton!
    private var removeKeyButton: NSButton!
    private let message = NSTextField(wrappingLabelWithString: "")
    /// The SQL to run, shown in a popover from the button beside Save.
    private let preview = NSTextView.scrollableTextView()
    private var previewText: NSTextView { preview.documentView as! NSTextView }
    private var sqlButton: NSButton!
    private var saveButton: NSButton!
    private var cancelButton: NSButton!
    /// In the Edit tab: whether the design differs from the table as it is.
    private(set) var hasChanges = false
    private var removeButton: NSButton!
    private var upButton: NSButton!
    private var downButton: NSButton!
    private var fieldsButton: NSButton!

    /// The grid's columns left out (its fields: type, length, key…), kept between editors. The
    /// widths are kept by the grid itself.
    private static let hiddenKey = "menumysql.tableEditor.hidden"
    /// Named anew when the fields change, so their order isn't the one kept for the old ones.
    private static let columnsKey = "menumysql.tableEditor.columns.2"

    /// The SQL to run, once the window closes with Save.
    private(set) var sql: String?
    /// The table's name as entered, to select it once it's made.
    var tableName: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    private enum Field: String, CaseIterable {
        case handle, name, type, length, primaryKey, notNull, unique, binary, unsigned, zerofill, autoincrement, generated, defaultValue, comment
        var title: String {
            switch self {
            case .handle: return ""
            case .name: return tr("名稱", "Name")
            case .type: return tr("類型", "Type")
            case .length: return tr("長度", "Length")
            case .primaryKey: return tr("主鍵", "Key")
            case .notNull: return tr("非空", "Not Null")
            case .unique: return tr("唯一", "Unique")
            case .binary: return tr("二進位", "Binary")
            case .unsigned: return tr("無符號", "Unsigned")
            case .zerofill: return tr("補零", "Zero Fill")
            case .autoincrement: return tr("自動遞增", "Auto Inc.")
            case .generated: return tr("生成", "Generated")
            case .defaultValue: return tr("預設值／運算式", "Default / Expression")
            case .comment: return tr("註解", "Comment")
            }
        }
        var help: String? {
            switch self {
            case .binary: return tr("B（Binary）：以二進位排序和比較文字，會區分大小寫（_bin 定序）",
                                    "B (Binary): sorts and compares the text as bytes, so case matters (a _bin collation)")
            case .unsigned: return tr("UN（Unsigned）：無符號數值，只能是正數和 0", "UN (Unsigned): no sign, so only zero and up")
            case .zerofill: return tr("ZF（Zero Fill）：位數不足時前面補 0，也會設為無符號",
                                      "ZF (Zero Fill): pads with zeros in front to the width; makes it unsigned too")
            case .autoincrement: return tr("AI（Auto Increment）：自動遞增流水號", "AI (Auto Increment): numbered for you")
            case .generated: return tr("G（Generated Column）：生成欄位（計算欄位），值由右邊的運算式算出；VIRTUAL 讀取時才計算，STORED（MariaDB 稱 PERSISTENT）存起來",
                                       "G (Generated Column): its value is worked out from the expression to the right; VIRTUAL when read, STORED (MariaDB’s PERSISTENT) kept with the row")
            case .defaultValue: return tr("一般欄位的預設值；生成欄位的運算式", "An ordinary column’s default; a generated column’s expression")
            default: return nil
            }
        }
        /// Every field but the handle and the name can be left out of the grid.
        var hideable: Bool { self != .handle && self != .name }
        var width: CGFloat {
            switch self {
            case .handle: return 22
            case .name: return 120
            case .type: return 130
            case .length: return 80
            case .primaryKey, .notNull, .unique, .zerofill: return 44
            case .binary, .unsigned, .autoincrement: return 56
            case .generated: return 92
            case .defaultValue: return 120
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

    private enum KeyField: String, CaseIterable {
        case keyName, keyColumns, keyTable, keyReferenced, onDelete, onUpdate
        var title: String {
            switch self {
            case .keyName: return tr("外鍵名稱", "Foreign Key")
            case .keyColumns: return tr("欄位", "Columns")
            case .keyTable: return tr("參照資料表", "References")
            case .keyReferenced: return tr("參照欄位", "Referenced Columns")
            case .onDelete: return "ON DELETE"
            case .onUpdate: return "ON UPDATE"
            }
        }
        var width: CGFloat {
            switch self {
            case .keyName: return 150
            case .keyColumns, .keyReferenced: return 150
            case .keyTable: return 140
            case .onDelete, .onUpdate: return 110
            }
        }
    }

    /// For a new table, `snapshot` is nil and `collation` the database's. With `onSave`, the
    /// editor goes in the Edit tab rather than a window of its own. `tables` and `columnsOf`
    /// are for the foreign keys: the tables they can refer to and those tables' columns.
    init(snapshot: TableSnapshot?, collation: String? = nil, tables: [String] = [], columnsOf: ((String) -> [Column])? = nil,
         onSave: ((_ sql: String, _ name: String) -> Void)? = nil) {
        self.snapshot = snapshot
        self.onSave = onSave
        self.tables = tables
        self.columnsOf = columnsOf
        tableCollation = snapshot?.collation ?? collation
        columns = snapshot?.columns ?? [ColumnDraft(name: "id", type: "INT UNSIGNED", primaryKey: true, notNull: true, autoincrement: true)]
        indexes = snapshot?.indexes ?? []
        foreignKeys = snapshot?.foreignKeys ?? []
        panel = onSave != nil ? nil : NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        if let panel {
            panel.delegate = self
            panel.title = snapshot == nil ? tr("新增資料表", "New Table") : tr("編輯資料表「\(snapshot!.name)」", "Edit Table “\(snapshot!.name)”")
            panel.minSize = NSSize(width: 760, height: 600)
            panel.contentView = view
        }
        build()
        update()
    }

    /// Shows the window until it's closed; true if Save was clicked.
    func run() -> Bool {
        guard let panel else { return false }
        panel.center()
        panel.makeFirstResponder(snapshot == nil ? nameField : table)
        return NSApp.runModal(for: panel) == .OK
    }

    // MARK: Layout

    private func build() {
        nameField.stringValue = snapshot?.name ?? ""
        nameField.placeholderString = tr("資料表名稱", "Table name")
        nameField.delegate = self
        // A table's name is short: the field leaves the rest of the row to the column buttons in the Edit tab.
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let nameSpacer = NSView()
        nameSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let nameRow = NSStackView(views: [NSTextField(labelWithString: tr("名稱", "Name")), nameField, nameSpacer])

        for field in Field.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = field.width * 0.6
            column.resizingMask = .userResizingMask   // dragged wider or narrower at the header
            column.headerToolTip = field.help
            if field == .handle {
                column.minWidth = field.width
                column.maxWidth = field.width
                column.resizingMask = []
                column.headerToolTip = tr("拖曳這裡可以調整欄位順序", "Drag here to reorder the columns")
            }
            table.addTableColumn(column)
        }
        table.allowsColumnReordering = false
        // The widths dragged are kept for the next editor; then the fields left out.
        table.autosaveName = Self.columnsKey
        table.autosaveTableColumns = true
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        for column in table.tableColumns {
            column.isHidden = Field(rawValue: column.identifier.rawValue).map { $0.hideable && hidden.contains($0.rawValue) } ?? false
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
        tableScroll.hasHorizontalScroller = true   // once the columns are dragged wider than the grid
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder

        // Plain icons like the window's toolbar: the column buttons as large as its own, those
        // beside the index and foreign key headings smaller.
        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector, small: Bool = false) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!
                .withSymbolConfiguration(.init(pointSize: small ? 12 : 15, weight: .regular))!
            let button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tr(zh, en)
            button.widthAnchor.constraint(equalToConstant: small ? 24 : 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: small ? 22 : 26).isActive = true
            return button
        }
        removeButton = button("minus", "刪除欄位", "Remove Column", #selector(removeColumn(_:)))
        upButton = button("arrow.up", "上移", "Move Up", #selector(moveUp(_:)))
        downButton = button("arrow.down", "下移", "Move Down", #selector(moveDown(_:)))
        fieldsButton = button("checklist", "選擇要顯示的欄位", "Choose the Fields to Show", #selector(showFieldsMenu(_:)))
        let addButton = button("plus", "新增欄位", "Add Column", #selector(addColumn(_:)))
        let columnButtons = NSStackView(views: panel == nil ? [addButton, removeButton, upButton, downButton, fieldsButton]
                                                            : [addButton, removeButton, upButton, downButton, NSView(), fieldsButton])
        columnButtons.spacing = 2
        // In the Edit tab, the column buttons (add, remove, move, fields to show) go at the right of the
        // name's row rather than under the grid.
        if panel == nil { nameRow.addArrangedSubview(columnButtons) }

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
        // Smaller in the Edit tab, which has less room than a window and scrolls when short of it.
        let inTab = panel == nil
        indexScroll.heightAnchor.constraint(equalToConstant: inTab ? 90 : 120).isActive = true
        let indexTitle = NSTextField(labelWithString: tr("索引", "Indexes"))
        indexTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let indexHint = NSTextField(labelWithString: tr("主鍵和單一欄位的唯一索引，用上方欄位的「主鍵」「唯一」勾選。",
                                                        "The key and single-column unique indexes are the Key and Unique boxes above."))
        indexHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        indexHint.textColor = .secondaryLabelColor
        indexHint.lineBreakMode = .byTruncatingTail
        indexHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let indexHeader = NSStackView(views: [indexTitle, indexHint])
        indexHeader.alignment = .centerY
        removeIndexButton = button("minus", "刪除索引", "Remove Index", #selector(removeIndex(_:)), small: true)
        // Adding and removing at the right end of the heading.
        let indexButtons = NSStackView(views: [button("plus", "新增索引", "Add Index", #selector(addIndex(_:)), small: true), removeIndexButton])
        indexButtons.spacing = 0
        let indexSpacer = NSView()
        indexSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        indexHeader.addArrangedSubview(indexSpacer)
        indexHeader.addArrangedSubview(indexButtons)

        // The foreign keys.
        for field in KeyField.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = 90
            keyTable.addTableColumn(column)
        }
        keyTable.dataSource = self
        keyTable.delegate = self
        keyTable.rowHeight = 30
        keyTable.usesAlternatingRowBackgroundColors = true
        keyTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let keyScroll = NSScrollView()
        keyScroll.documentView = keyTable
        keyScroll.hasVerticalScroller = true
        keyScroll.hasHorizontalScroller = true
        keyScroll.autohidesScrollers = true
        keyScroll.borderType = .bezelBorder
        keyScroll.heightAnchor.constraint(equalToConstant: inTab ? 90 : 120).isActive = true
        let keyTitle = NSTextField(labelWithString: tr("外鍵", "Foreign Keys"))
        keyTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let keyHint = NSTextField(labelWithString: tr("欄位的值要能在參照資料表的欄位中找到；參照欄位通常是那個資料表的主鍵。",
                                                      "The columns’ values have to be found in the referenced columns, usually that table’s key."))
        keyHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyHint.textColor = .secondaryLabelColor
        keyHint.lineBreakMode = .byTruncatingTail
        keyHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keyHeader = NSStackView(views: [keyTitle, keyHint])
        keyHeader.alignment = .centerY
        removeKeyButton = button("minus", "刪除外鍵", "Remove Foreign Key", #selector(removeForeignKey(_:)), small: true)
        let keyButtons = NSStackView(views: [button("plus", "新增外鍵", "Add Foreign Key", #selector(addForeignKey(_:)), small: true), removeKeyButton])
        keyButtons.spacing = 0
        let keySpacer = NSView()
        keySpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        keyHeader.addArrangedSubview(keySpacer)
        keyHeader.addArrangedSubview(keyButtons)

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewText.isEditable = false
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        preview.hasVerticalScroller = true
        preview.frame = NSRect(x: 0, y: 0, width: 620, height: 260)

        saveButton = NSButton(title: snapshot == nil ? tr("建立", "Create") : tr("儲存", "Save"), target: self, action: #selector(save(_:)))
        cancelButton = NSButton(title: inTab ? tr("還原", "Revert") : tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        // Return and Esc belong to the window's own editor; in the tab, Esc hides the window.
        if !inTab {
            saveButton.keyEquivalent = "\r"
            cancelButton.keyEquivalent = "\u{1b}"
        }
        sqlButton = NSButton(title: tr("執行的 SQL", "SQL to Run"), target: self, action: #selector(showSQL(_:)))
        sqlButton.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        sqlButton.imagePosition = .imageLeading
        sqlButton.toolTip = tr("顯示儲存時將執行的 SQL", "Show the SQL that Save will run")
        let actions = NSStackView(views: [NSView(), sqlButton, cancelButton, saveButton])

        let stack = NSStackView(views: [nameRow, tableScroll] + (inTab ? [] : [columnButtons]) + [indexHeader, indexScroll,
                                        keyHeader, keyScroll, message, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        let inset: CGFloat = inTab ? 12 : 16
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        stack.setCustomSpacing(14, after: inTab ? tableScroll : columnButtons)
        stack.setCustomSpacing(14, after: indexScroll)
        for view in [nameRow, tableScroll] + (inTab ? [] : [columnButtons]) + [indexHeader, indexScroll, keyHeader, keyScroll, message, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true
        }
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: inTab ? 110 : 140).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: The column table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === indexTable ? indexes.count : tableView === keyTable ? foreignKeys.count : columns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === indexTable { return indexCell(tableColumn, row: row) }
        if tableView === keyTable { return keyCell(tableColumn, row: row) }
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
        case .primaryKey, .notNull, .unique, .binary, .unsigned, .zerofill, .autoincrement:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            let kind = TableDesign.kind(of: column.type)
            let on = [Field.primaryKey: column.primaryKey, .notNull: column.notNull || column.primaryKey, .unique: column.unique,
                      .binary: TableDesign.textual.contains(kind) && TableDesign.isBinary(column, tableCollation: tableCollation),
                      .unsigned: TableDesign.has("UNSIGNED", in: column.type), .zerofill: TableDesign.has("ZEROFILL", in: column.type),
                      .autoincrement: column.autoincrement][field] ?? false
            box.state = on ? .on : .off
            // A key can't be NULL, a generated column's value isn't set by these, only text is
            // binary and only numbers unsigned.
            switch field {
            case .notNull: box.isEnabled = !column.primaryKey && column.expression == nil
            case .autoincrement: box.isEnabled = column.expression == nil
            case .binary: box.isEnabled = TableDesign.textual.contains(kind)
            case .unsigned, .zerofill: box.isEnabled = TableDesign.numeric.contains(kind)
            default: box.isEnabled = true
            }
            box.toolTip = field.help
            return centered(box)
        case .generated:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.addItems(withTitles: ["—", "VIRTUAL", "STORED"])
            popUp.item(at: 2)?.toolTip = tr("MariaDB 稱為 PERSISTENT", "PERSISTENT in MariaDB")
            popUp.selectItem(at: column.expression == nil ? 0 : column.stored ? 2 : 1)
            popUp.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            popUp.toolTip = field.help
            popUp.target = self
            popUp.action = #selector(generationChanged(_:))
            return centered(popUp, fill: true)
        case .type:
            let combo = NSComboBox()
            combo.addItems(withObjectValues: TableDesign.types)
            combo.stringValue = TableDesign.bareType(TableDesign.split(column.type).base)
            combo.isBordered = false
            combo.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            combo.delegate = self
            return centered(combo, fill: true)
        case .name, .defaultValue, .comment:
            let text = NSTextField(string: field == .name ? column.name : field == .comment ? column.comment
                                   : column.expression ?? column.defaultValue)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = field != .defaultValue ? nil
                : column.expression != nil ? tr("運算式，例如 price * qty", "expression, e.g. price * qty") : tr("（無）", "(none)")
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
        case .binary: columns[row].collation = TableDesign.collation(binary: on, for: columns[row], tableCollation: tableCollation)
        case .unsigned: columns[row].type = TableDesign.setting("UNSIGNED", on, in: columns[row].type)
        case .zerofill: columns[row].type = TableDesign.setting("ZEROFILL", on, in: columns[row].type)
        default: break
        }
        if field == .primaryKey {
            columns[row].notNull = columns[row].notNull || on
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if field == .unsigned || field == .zerofill { reloadAttributes(of: row) }   // each may tick or clear the other
        update()
    }

    /// No generation, VIRTUAL or STORED. A generated column has an expression where the default
    /// was, and no AUTO_INCREMENT.
    @objc private func generationChanged(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard columns.indices.contains(row) else { return }
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
        if sender.indexOfSelectedItem == 0 {
            columns[row].expression = nil
            columns[row].stored = false
        } else {
            columns[row].expression = columns[row].expression ?? ""
            columns[row].stored = sender.indexOfSelectedItem == 2
            columns[row].autoincrement = false
        }
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        update()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField { return update() }
        if let keyField = field.identifier.flatMap({ KeyField(rawValue: $0.rawValue) }) {
            let row = keyTable.row(for: field)
            guard foreignKeys.indices.contains(row) else { return }
            switch keyField {
            case .keyName: foreignKeys[row].name = field.stringValue.trimmingCharacters(in: .whitespaces)
            case .keyColumns: foreignKeys[row].columns = IndexDraft.columns(from: field.stringValue).map(IndexDraft.column(of:))
            case .keyReferenced: foreignKeys[row].referencedColumns = IndexDraft.columns(from: field.stringValue).map(IndexDraft.column(of:))
            default: break
            }
            return update()
        }
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
            columns[row].type = TableDesign.retype(columns[row].type, to: field.stringValue, length: TableDesign.split(columns[row].type).length)
            dropCollationUnlessText(row)
            reloadAttributes(of: row)
        case Field.length.rawValue: columns[row].type = TableDesign.join(TableDesign.split(columns[row].type).base, field.stringValue)
        case Field.defaultValue.rawValue:
            if columns[row].expression != nil { columns[row].expression = field.stringValue } else { columns[row].defaultValue = field.stringValue }
        case Field.comment.rawValue: columns[row].comment = field.stringValue
        default: break
        }
        update()
    }

    /// A default typed as plain text gets its quotes once the field is left, as the SQL will
    /// have it; numbers, NULL, CURRENT_TIMESTAMP, expressions and quoted text stay as typed.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.identifier?.rawValue == Field.defaultValue.rawValue else { return }
        let row = table.row(for: field)
        guard columns.indices.contains(row), columns[row].expression == nil else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        let quoted = value.isEmpty ? "" : TableDesign.defaultSQL(value)
        guard quoted != field.stringValue else { return }
        field.stringValue = quoted
        columns[row].defaultValue = quoted
        update()
    }

    // MARK: Fields to show

    /// Ticks for the grid's fields, staying open while they're ticked; the name always shows.
    @objc private func showFieldsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let font = NSFont.menuFont(ofSize: 0)
        let fields = Field.allCases.filter { $0 != .handle }
        let width = max(160, (fields.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 60)
        for field in fields {
            let box = NSButton(checkboxWithTitle: field.title, target: self, action: #selector(toggleField(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            box.state = table.tableColumn(withIdentifier: box.identifier!)?.isHidden == true ? .off : .on
            box.isEnabled = field.hideable
            box.font = font
            box.frame = NSRect(x: 14, y: 2, width: width - 20, height: 20)
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            holder.addSubview(box)
            let item = NSMenuItem()
            item.view = holder
            menu.addItem(item)
        }
        menu.allowsContextMenuPlugIns = false
        // In the window, its right edge under the button's, so it opens into the editor rather than past it.
        menu.popUp(positioning: nil, at: NSPoint(x: panel == nil ? 0 : sender.bounds.width - width, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleField(_ sender: NSButton) {
        guard let id = sender.identifier, let column = table.tableColumn(withIdentifier: id) else { return }
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
        column.isHidden = sender.state == .off
        let hidden = table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue)
        UserDefaults.standard.set(hidden, forKey: Self.hiddenKey)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        let row = table.row(for: combo)
        guard columns.indices.contains(row) else { return }
        let old = TableDesign.split(columns[row].type), base = TableDesign.types[combo.indexOfSelectedItem]
        columns[row].type = TableDesign.retype(columns[row].type, to: base, length: TableDesign.length(changingType: old.base, to: base, from: old.length))
        dropCollationUnlessText(row)
        reloadAttributes(of: row)
        update()
    }

    /// Only text has a collation: a column changed to another type loses its own.
    private func dropCollationUnlessText(_ row: Int) {
        if !TableDesign.textual.contains(TableDesign.kind(of: columns[row].type)) { columns[row].collation = nil }
    }

    /// Shows the row's length and the boxes that go with its type again, after the type changed:
    /// a new length, or fields that are off.
    private func reloadAttributes(of row: Int) {
        let fields: [Field] = [.length, .binary, .unsigned, .zerofill]
        let shown = IndexSet(table.tableColumns.indices.filter { fields.map(\.rawValue).contains(table.tableColumns[$0].identifier.rawValue) })
        table.reloadData(forRowIndexes: [row], columnIndexes: shown)
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
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
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
        // A foreign key on it goes, since its columns and the referenced ones pair up.
        foreignKeys.removeAll { $0.columns.contains(removed) }
        keyTable.reloadData()
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
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
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
        changed = false
        let ownName = snapshot?.name ?? tableName
        for i in foreignKeys.indices {
            for j in foreignKeys[i].columns.indices where foreignKeys[i].columns[j] == old {
                foreignKeys[i].columns[j] = new
                changed = true
            }
            guard foreignKeys[i].schema == nil, foreignKeys[i].table == ownName else { continue }
            for j in foreignKeys[i].referencedColumns.indices where foreignKeys[i].referencedColumns[j] == old {
                foreignKeys[i].referencedColumns[j] = new
                changed = true
            }
        }
        if changed { keyTable.reloadData() }
    }

    // MARK: Foreign keys

    private func keyCell(_ tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let field = tableColumn.flatMap({ KeyField(rawValue: $0.identifier.rawValue) }) else { return nil }
        let key = foreignKeys[row]
        func popUp(_ titles: [String], selected: String, _ action: Selector) -> NSView {
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.addItems(withTitles: titles)
            popUp.selectItem(withTitle: selected)
            popUp.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            popUp.target = self
            popUp.action = action
            return centered(popUp, fill: true)
        }
        switch field {
        case .onDelete: return popUp(ForeignKeyDraft.actions, selected: key.onDelete, #selector(keyActionChanged(_:)))
        case .onUpdate: return popUp(ForeignKeyDraft.actions, selected: key.onUpdate, #selector(keyActionChanged(_:)))
        case .keyTable:
            var titles = referableTables
            let current = keyTableTitle(key)
            if !current.isEmpty, !titles.contains(current) { titles.append(current) }
            if current.isEmpty { titles.insert("", at: 0) }
            return popUp(titles, selected: current, #selector(keyTableChanged(_:)))
        case .keyName, .keyColumns, .keyReferenced:
            let text = NSTextField(string: field == .keyName ? key.name : field == .keyColumns ? key.columns.joined(separator: ", ")
                                   : key.referencedColumns.joined(separator: ", "))
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = field == .keyName ? tr("（自動命名）", "(named for you)") : tr("例如 user_id", "e.g. user_id")
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            guard field != .keyName else { return centered(text, fill: true) }
            let pick = NSButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: tr("選擇欄位", "Choose Columns"))!,
                                target: self, action: #selector(showKeyColumns(_:)))
            pick.isBordered = false
            pick.toolTip = tr("選擇欄位", "Choose Columns")
            pick.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            pick.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            return centered(NSStackView(views: [text, pick]), fill: true)
        }
    }

    /// The tables of the database, and this one (a key may refer to its own table).
    private var referableTables: [String] {
        let own = snapshot?.name ?? tableName
        return own.isEmpty || tables.contains(own) ? tables : tables + [own]
    }

    private func keyTableTitle(_ key: ForeignKeyDraft) -> String {
        key.schema.map { "\($0).\(key.table)" } ?? key.table
    }

    /// A table's columns: this table's as edited, another's as the server has them.
    private func columns(ofReferenced key: ForeignKeyDraft) -> [Column] {
        if key.schema == nil, key.table == (snapshot?.name ?? tableName) {
            let keys = columns.filter(\.primaryKey).map(\.name)
            return columns.map { Column(name: $0.name, type: $0.type, notNull: $0.notNull, defaultValue: nil,
                                        primaryKey: (keys.firstIndex(of: $0.name) ?? -1) + 1) }
        }
        guard key.schema == nil, !key.table.isEmpty, let columnsOf else { return [] }
        if let known = columnCache[key.table] { return known }
        let read = columnsOf(key.table)
        columnCache[key.table] = read
        return read
    }

    @objc private func keyActionChanged(_ sender: NSPopUpButton) {
        let row = keyTable.row(for: sender)
        guard foreignKeys.indices.contains(row), let action = sender.titleOfSelectedItem else { return }
        if sender.identifier?.rawValue == KeyField.onDelete.rawValue { foreignKeys[row].onDelete = action } else { foreignKeys[row].onUpdate = action }
        update()
    }

    /// Choosing the table to refer to fills in its key as the referenced columns.
    @objc private func keyTableChanged(_ sender: NSPopUpButton) {
        let row = keyTable.row(for: sender)
        guard foreignKeys.indices.contains(row), let title = sender.titleOfSelectedItem, title != keyTableTitle(foreignKeys[row]) else { return }
        view.window?.makeFirstResponder(nil)
        foreignKeys[row].table = title
        foreignKeys[row].schema = nil
        let key = columns(ofReferenced: foreignKeys[row]).filter { $0.primaryKey > 0 }.sorted { $0.primaryKey < $1.primaryKey }.map(\.name)
        foreignKeys[row].referencedColumns = key
        keyTable.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<keyTable.numberOfColumns))
        update()
    }

    /// A menu of the columns to tick in or out: this table's, or the referenced table's.
    @objc private func showKeyColumns(_ sender: NSButton) {
        let row = keyTable.row(for: sender)
        guard foreignKeys.indices.contains(row) else { return }
        keyTable.selectRowIndexes([row], byExtendingSelection: false)
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
        let referenced = sender.identifier?.rawValue == KeyField.keyReferenced.rawValue
        let names = referenced ? columns(ofReferenced: foreignKeys[row]).map(\.name) : columns.map(\.name).filter { !$0.isEmpty }
        let used = referenced ? foreignKeys[row].referencedColumns : foreignKeys[row].columns
        let menu = NSMenu()
        if names.isEmpty {
            menu.addItem(withTitle: tr("請先選擇參照資料表", "Choose the table to refer to first"), action: nil, keyEquivalent: "").isEnabled = false
        }
        for name in names {
            let item = menu.addItem(withTitle: name, action: #selector(toggleKeyColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = used.contains(name) ? .on : .off
            item.tag = row
            item.representedObject = referenced
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func toggleKeyColumn(_ sender: NSMenuItem) {
        let row = sender.tag
        guard foreignKeys.indices.contains(row) else { return }
        let referenced = sender.representedObject as? Bool == true
        var list = referenced ? foreignKeys[row].referencedColumns : foreignKeys[row].columns
        if sender.state == .on { list.removeAll { $0 == sender.title } } else { list.append(sender.title) }
        if referenced { foreignKeys[row].referencedColumns = list } else { foreignKeys[row].columns = list }
        keyTable.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<keyTable.numberOfColumns))
        update()
    }

    @objc private func addForeignKey(_ sender: Any?) {
        // Starting from the column selected above, if one is.
        let start = columns.indices.contains(table.selectedRow) ? [columns[table.selectedRow].name] : []
        foreignKeys.append(ForeignKeyDraft(columns: start))
        keyTable.reloadData()
        let row = foreignKeys.count - 1
        keyTable.selectRowIndexes([row], byExtendingSelection: false)
        keyTable.scrollRowToVisible(row)
        update()
    }

    @objc private func removeForeignKey(_ sender: Any?) {
        let row = keyTable.selectedRow
        guard foreignKeys.indices.contains(row) else { return }
        foreignKeys.remove(at: row)
        keyTable.reloadData()
        if !foreignKeys.isEmpty { keyTable.selectRowIndexes([min(row, foreignKeys.count - 1)], byExtendingSelection: false) }
        update()
    }

    private func updateButtons() {
        removeIndexButton?.isEnabled = indexes.indices.contains(indexTable.selectedRow)
        removeKeyButton?.isEnabled = foreignKeys.indices.contains(keyTable.selectedRow)
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
        if let problem = TableDesign.problem(name: name, columns: columns, indexes: indexes, foreignKeys: foreignKeys) {
            show(sql: "", message: problem, error: true)
            hasChanges = true
            if panel == nil { cancelButton.isEnabled = true }
            return
        }
        guard let snapshot else {
            show(sql: TableDesign.createSQL(name: name, columns: columns, indexes: indexes, foreignKeys: foreignKeys), message: "", error: false)
            return
        }
        let change = TableDesign.alterSQL(snapshot, newName: name, columns: columns, indexes: indexes, foreignKeys: foreignKeys)
        let unchanged = change.sql.isEmpty
        show(sql: unchanged ? "" : change.sql,
             message: unchanged ? tr("沒有變更。", "Nothing has changed.") : change.warnings.joined(separator: "\n"),
             error: false, canSave: !unchanged)
        hasChanges = !unchanged
        if panel == nil { cancelButton.isEnabled = !unchanged }
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
        sqlButton.isEnabled = !sql.isEmpty
        self.sql = sql.isEmpty ? nil : sql
    }

    /// The SQL Save will run, in a popover over the button, to read or copy.
    @objc private func showSQL(_ sender: NSButton) {
        view.window?.makeFirstResponder(nil)   // finish the cell being typed in
        update()
        guard sql != nil else { return NSSound.beep() }
        let controller = NSViewController()
        controller.view = preview
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = preview.frame.size
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func save(_ sender: Any?) {
        view.window?.makeFirstResponder(nil)   // finish the cell being typed in
        update()
        guard let sql, saveButton.isEnabled else { return NSSound.beep() }
        if let onSave { return onSave(sql, tableName) }
        NSApp.stopModal(withCode: .OK)
        panel?.orderOut(nil)
    }

    /// The title bar's close button: the same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    @objc private func cancel(_ sender: Any?) {
        guard let panel else { return revert() }
        sql = nil
        NSApp.stopModal(withCode: .cancel)
        panel.orderOut(nil)
    }

    /// In the Edit tab: back to the table as it is, dropping the changes.
    private func revert() {
        guard let snapshot else { return }
        view.window?.makeFirstResponder(nil)
        nameField.stringValue = snapshot.name
        columns = snapshot.columns
        indexes = snapshot.indexes
        foreignKeys = snapshot.foreignKeys
        table.reloadData()
        indexTable.reloadData()
        keyTable.reloadData()
        update()
    }
}
