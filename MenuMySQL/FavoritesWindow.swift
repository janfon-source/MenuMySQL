import AppKit

/// A window listing the favorite databases, to add, copy, edit and delete them, put them in order
/// by dragging, and connect to one (with Connect, or a double-click).
final class FavoritesWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private var favorites = Favorites.all
    private let table = NSTableView()
    private var copyButton: NSButton!
    private var editButton: NSButton!
    private var removeButton: NSButton!
    private var connectButton: NSButton!

    /// The favorite to connect to, once the window closes with Connect.
    private(set) var chosen: Favorite?

    var window: NSWindow { panel }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("常用資料庫", "Favorite Databases")
        panel.minSize = NSSize(width: 480, height: 280)
        panel.delegate = self
        build()
        updateButtons()
    }

    /// Shows the window until it's closed.
    func run() {
        panel.center()
        panel.makeFirstResponder(table)
        if !favorites.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        NSApp.runModal(for: panel)
    }

    // MARK: Layout

    private enum Field: String, CaseIterable {
        case name, server, database
        var title: String {
            switch self {
            case .name: return tr("名稱", "Name")
            case .server: return tr("伺服器", "Server")
            case .database: return tr("資料庫", "Database")
            }
        }
        var width: CGFloat { self == .server ? 240 : 160 }
    }

    private func build() {
        for field in Field.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(connect(_:))
        // Rows are dragged into the order the connection dialog lists them in.
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!,
                                  target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tr(zh, en)
            return button
        }
        copyButton = button("plus.square.on.square", "複製", "Duplicate", #selector(duplicate(_:)))
        editButton = button("pencil", "編輯", "Edit", #selector(edit(_:)))
        removeButton = button("minus", "刪除", "Delete", #selector(remove(_:)))
        let listButtons = NSStackView(views: [button("plus", "新增", "Add", #selector(add(_:))), removeButton,
                                              copyButton, editButton, NSView()])
        listButtons.spacing = 4

        let close = NSButton(title: tr("關閉", "Close"), target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: tr("連線", "Connect"), target: self, action: #selector(connect(_:)))
        connectButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), close, connectButton])

        let stack = NSStackView(views: [scroll, listButtons, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [scroll, listButtons, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let favorite = favorites[row], location = favorite.location
        switch tableColumn.flatMap({ Field(rawValue: $0.identifier.rawValue) }) {
        case .name: return favorite.name
        case .server: return "\(location.user)@\(location.serverName)"
        case .database: return location.database ?? tr("（未指定）", "(none)")
        case nil: return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    // MARK: Dragging into order

    private static let rowType = NSPasteboard.PasteboardType("com.jeff.menumysql.favorite-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)   // between rows, never onto one
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(text), favorites.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        guard to != from else { return false }
        favorites.insert(favorites.remove(at: from), at: to)
        save(selecting: to)
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selected: Int? { favorites.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    private func updateButtons() {
        for button in [copyButton, editButton, removeButton, connectButton] { button?.isEnabled = selected != nil }
    }

    /// Saves the list and shows it, with `row` selected.
    private func save(selecting row: Int?) {
        Favorites.all = favorites
        table.reloadData()
        if let row, favorites.indices.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateButtons()
    }

    // MARK: Actions

    @objc private func add(_ sender: Any?) {
        guard let favorite = Self.edit(nil) else { return }
        favorites.append(favorite)
        save(selecting: favorites.count - 1)
    }

    @objc private func duplicate(_ sender: Any?) {
        guard let row = selected else { return NSSound.beep() }
        var copy = favorites[row]
        copy.id = UUID()
        copy.name += tr(" 副本", " copy")
        favorites.insert(copy, at: row + 1)
        save(selecting: row + 1)
    }

    @objc private func edit(_ sender: Any?) {
        guard let row = selected, let favorite = Self.edit(favorites[row]) else { return }
        favorites[row] = favorite
        save(selecting: row)
    }

    @objc private func remove(_ sender: Any?) {
        guard let row = selected else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = tr("要刪除常用資料庫「\(favorites[row].name)」嗎？", "Delete the favorite “\(favorites[row].name)”?")
        alert.informativeText = tr("只從清單移除，伺服器上的資料庫不受影響。", "It only leaves this list; the database on the server is untouched.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        favorites.remove(at: row)
        save(selecting: min(row, favorites.count - 1))
    }

    @objc private func connect(_ sender: Any?) {
        guard let row = selected else { return }
        chosen = favorites[row]
        panel.close()
    }

    @objc private func closeWindow(_ sender: Any?) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    // MARK: Editing one

    /// Asks for a favorite's name and connection, starting from `favorite` (nil for a new one,
    /// which starts from the last connection). The password, if given and kept, goes to the
    /// app's password store. Nil if cancelled.
    static func edit(_ favorite: Favorite?, start: ServerLocation? = nil) -> Favorite? {
        let location = favorite?.location ?? start
        let form = ConnectionForm(start: location, password: location.flatMap { Passwords.password(for: $0.account) }, name: favorite?.name ?? "")
        let alert = NSAlert()
        alert.messageText = favorite == nil ? tr("新增常用資料庫", "New Favorite Database") : tr("編輯常用資料庫", "Edit Favorite Database")
        alert.informativeText = tr("名稱留空時，以資料庫和主機命名。", "Left empty, the name is the database and host.")
        alert.accessoryView = form.view
        alert.addButton(withTitle: tr("儲存", "Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = form.firstField
        while alert.runModal() == .alertFirstButtonReturn {
            switch form.location {
            case .success(let location):
                if form.savesPassword, !form.enteredPassword.isEmpty { Passwords.save(form.enteredPassword, for: location.account) }
                let name = form.enteredName.isEmpty ? Favorites.suggestedName(for: location) : form.enteredName
                return Favorite(id: favorite?.id ?? UUID(), name: name, location: location)
            case .failure(let problem):
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = problem.message
                warning.runModal()
            }
        }
        return nil
    }
}
