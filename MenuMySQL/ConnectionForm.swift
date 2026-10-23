import AppKit

/// The fields for connecting to a server, directly or through SSH. Through SSH, the SSH server
/// comes first (picked from ~/.ssh/config, which fills in its port and key), then the database
/// server as that machine sees it, usually 127.0.0.1; then the account, password, database and
/// TLS. Every field is always there, the SSH ones greyed out for a direct connection, so the
/// alert holding the form keeps its size when the choice changes.
final class ConnectionForm: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
    let view: NSGridView
    private let mode = NSSegmentedControl()
    private let sshHost = NSComboBox()
    private let sshPort: NSTextField
    private let sshKey: NSTextField
    /// Picks the private key in a file panel, to fill in its path.
    private let chooseKey = NSButton()
    private let resolved = NSTextField(labelWithString: "")
    private let host: NSTextField
    private let hostHint = NSTextField(wrappingLabelWithString: "")
    private let port: NSTextField
    private let user: NSTextField
    private let password = NSSecureTextField()
    /// The password in plain text, in the same place, while the eye button shows it.
    private let plainPassword = NSTextField()
    private let revealButton = NSButton()
    private var revealed = false
    private let remember = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let database: NSTextField
    private let tls = NSPopUpButton()
    private let hosts: [SSHHost]
    private var sshLabels: [NSTextField] = []
    /// The favorite's name, when the form edits one.
    private var nameField: NSTextField?
    /// The account the password in the field belongs to. Another server or user empties it, so
    /// a password saved for one account is never sent to another (or typed onto the end of).
    private var passwordAccount: String?

    private var viaSSH: Bool { mode.selectedSegment == 1 }

    var firstField: NSView {
        if let nameField, nameField.stringValue.isEmpty { return nameField }
        if viaSSH, sshHost.stringValue.isEmpty { return sshHost }
        return host.stringValue.isEmpty ? host : passwordText.isEmpty ? (revealed ? plainPassword : password) : database
    }

    /// `ssh` starts the form on the SSH choice, whatever `start` used. With `name`, the form
    /// starts with a field for a favorite's name.
    init(start: ServerLocation?, password saved: String?, ssh: Bool? = nil, name: String? = nil,
         hosts: [SSHHost] = SSHConfig.hosts()) {
        self.hosts = hosts
        func field(_ value: String, _ placeholder: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return field
        }
        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
        func note(_ field: NSTextField) {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        // A new connection starts empty, the usual values only as hints; a favorite being
        // edited starts from what it has.
        let blank = start == nil
        let start = start ?? ServerLocation()
        sshPort = field(start.sshPort.map(String.init) ?? "", tr("22（選填）", "22 (optional)"))
        sshKey = field(start.sshIdentity ?? "", tr("~/.ssh/id_ed25519（選填）", "~/.ssh/id_ed25519 (optional)"))
        host = field(blank ? "" : start.host, "127.0.0.1")
        port = field(start.port == 3306 ? "" : String(start.port), "3306")
        user = field(blank ? "" : start.user, tr("帳號，例如 root", "Account, e.g. root"))
        database = field(start.database ?? "", tr("選填，之後也可以在左上角切換", "Optional; switch at the top left later"))
        password.stringValue = saved ?? ""
        passwordAccount = saved == nil ? nil : start.account
        password.placeholderString = tr("密碼", "Password")
        plainPassword.placeholderString = password.placeholderString
        plainPassword.isHidden = true
        // The two fields lie one on the other, the eye button beside them.
        let fields = NSView()
        for field in [password, plainPassword] {
            field.translatesAutoresizingMaskIntoConstraints = false
            fields.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
                field.topAnchor.constraint(equalTo: fields.topAnchor),
                field.bottomAnchor.constraint(equalTo: fields.bottomAnchor),
            ])
        }
        revealButton.isBordered = false
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        let passwordRow = NSStackView(views: [fields, revealButton])
        passwordRow.spacing = 4
        passwordRow.widthAnchor.constraint(equalToConstant: 300).isActive = true
        remember.title = tr("記住密碼", "Remember the password")
        remember.state = .on
        tls.addItems(withTitles: [tr("伺服器支援就使用（建議）", "When the server offers it (recommended)"),
                                  tr("一定要使用", "Required"), tr("不使用", "Off")])
        tls.selectItem(at: MySQLWire.TLSMode.allCases.firstIndex(of: start.tls) ?? 0)
        mode.segmentCount = 2
        mode.setLabel(tr("直接連線", "Direct"), forSegment: 0)
        mode.setLabel(tr("透過 SSH", "Through SSH"), forSegment: 1)
        mode.selectedSegment = (ssh ?? start.usesSSH) ? 1 : 0
        note(resolved)
        note(hostHint)
        hostHint.preferredMaxLayoutWidth = 300

        let sshTitle = label(tr("SSH 主機", "SSH Server")), sshPortTitle = label(tr("SSH 連接埠", "SSH Port")),
            keyTitle = label(tr("私鑰", "Private Key"))
        sshLabels = [sshTitle, sshPortTitle, keyTitle]
        // The key's field makes room for its Choose button, the two as wide as the other fields.
        chooseKey.title = tr("選擇…", "Choose…")
        chooseKey.bezelStyle = .rounded
        chooseKey.controlSize = .small
        chooseKey.setContentHuggingPriority(.required, for: .horizontal)
        sshKey.constraints.first { $0.firstAttribute == .width }?.isActive = false
        let keyRow = NSStackView(views: [sshKey, chooseKey])
        keyRow.spacing = 6
        keyRow.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let line = NSBox()
        line.boxType = .separator
        view = NSGridView(views: [
            [label(tr("連線方式", "Connect")), mode],
            [sshTitle, sshHost],
            [NSGridCell.emptyContentView, resolved],
            [sshPortTitle, sshPort],
            [keyTitle, keyRow],
            [line],
            [label(tr("資料庫主機", "Database Host")), host],
            [NSGridCell.emptyContentView, hostHint],
            [label(tr("連接埠", "Port")), port],
            [label(tr("帳號", "User")), user],
            [label(tr("密碼", "Password")), passwordRow],
            [NSGridCell.emptyContentView, remember],
            [label(tr("資料庫", "Database")), database],
            [label("SSL/TLS"), tls],
        ])
        super.init()

        sshHost.stringValue = start.sshDestination ?? ""
        sshHost.placeholderString = hosts.isEmpty ? "user@example.com" : tr("從 ~/.ssh/config 選擇，或輸入 user@host", "Pick from ~/.ssh/config, or type user@host")
        sshHost.addItems(withObjectValues: hosts.map(\.alias))
        sshHost.numberOfVisibleItems = 12
        sshHost.completes = true
        sshHost.delegate = self
        for field in [host, port, user, sshPort] { field.delegate = self }
        revealButton.target = self
        revealButton.action = #selector(toggleReveal(_:))
        chooseKey.target = self
        chooseKey.action = #selector(chooseKeyFile(_:))
        updateRevealButton()
        sshHost.widthAnchor.constraint(equalToConstant: 300).isActive = true
        mode.target = self
        mode.action = #selector(modeChanged(_:))
        view.column(at: 0).xPlacement = .trailing
        view.rowAlignment = .firstBaseline
        view.row(at: 0).bottomPadding = 4
        view.row(at: 2).topPadding = -4
        view.row(at: 5).mergeCells(in: NSRange(location: 0, length: 2))
        view.row(at: 5).topPadding = 4
        view.row(at: 5).bottomPadding = 4
        view.row(at: 7).topPadding = -4
        view.row(at: 11).topPadding = -2
        if let name {
            let field = NSTextField(string: name)
            field.placeholderString = tr("例如：正式機的訂單資料庫", "e.g. Orders on production")
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            nameField = field
            view.insertRow(at: 0, with: [NSTextField(labelWithString: tr("名稱", "Name")), field])
            view.row(at: 0).bottomPadding = 8
        }
        showResolved()
        applyMode()
        view.frame.size = view.fittingSize
    }

    /// The favorite's name as entered.
    var enteredName: String { nameField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "" }

    /// What was entered, or why it can't be used yet.
    var location: Result<ServerLocation, DatabaseError> {
        func value(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespaces) }
        if viaSSH, value(sshHost).isEmpty {
            return .failure(DatabaseError(message: tr("請輸入 SSH 主機。", "Enter the SSH server.")))
        }
        guard !value(user).isEmpty else { return .failure(DatabaseError(message: tr("請輸入帳號。", "Enter the account name."))) }
        var location = ServerLocation()
        location.host = value(host).isEmpty ? "127.0.0.1" : value(host)
        location.port = Int(value(port)) ?? 3306
        location.user = value(user)
        location.database = value(database).isEmpty ? nil : value(database)
        location.tls = MySQLWire.TLSMode.allCases[max(0, tls.indexOfSelectedItem)]
        if viaSSH {
            location.sshDestination = value(sshHost)
            location.sshPort = Int(value(sshPort))
            location.sshIdentity = value(sshKey).isEmpty ? nil : value(sshKey)
        }
        return .success(location)
    }

    var enteredPassword: String { passwordText }

    /// The password, from whichever field is showing; set, it goes in both.
    private var passwordText: String {
        get { revealed ? plainPassword.stringValue : password.stringValue }
        set {
            password.stringValue = newValue
            plainPassword.stringValue = newValue
        }
    }

    /// Shows the password as typed, or hides it again, keeping what's in it and the typing place.
    @objc private func toggleReveal(_ sender: Any?) {
        let text = passwordText
        revealed.toggle()
        passwordText = text
        password.isHidden = revealed
        plainPassword.isHidden = !revealed
        updateRevealButton()
        let field = revealed ? plainPassword : password
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    private func updateRevealButton() {
        let symbol = revealed ? "eye.slash" : "eye"
        revealButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        revealButton.contentTintColor = .secondaryLabelColor
        revealButton.toolTip = revealed ? tr("隱藏密碼", "Hide the Password") : tr("顯示密碼", "Show the Password")
        revealButton.setAccessibilityLabel(revealButton.toolTip)
    }
    var savesPassword: Bool { remember.state == .on }

    @objc private func modeChanged(_ sender: Any?) {
        applyMode()
        fillSavedPassword()   // through SSH or not is another account
        view.window?.makeFirstResponder(firstField)
    }

    /// The SSH fields take part only through SSH, and the database host's hint says how it's seen.
    private func applyMode() {
        for control in [sshHost, sshPort, sshKey, chooseKey] as [NSControl] { control.isEnabled = viaSSH }
        for label in sshLabels { label.textColor = viaSSH ? .labelColor : .tertiaryLabelColor }
        resolved.isHidden = !viaSSH
        hostHint.stringValue = viaSSH
            ? tr("從 SSH 主機看到的位址，同一台機器就是 127.0.0.1", "As the SSH server sees it: 127.0.0.1 when it’s the same machine")
            : tr("伺服器的名稱或 IP 位址", "The server’s name or IP address")
    }

    /// A file panel for the private key, opening in ~/.ssh (hidden, like the keys usually are),
    /// as a sheet on the connection alert. The path goes in with ~ for the home folder.
    @objc private func chooseKeyFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = tr("選擇 SSH 私鑰檔（例如 id_ed25519 或 id_rsa，不是 .pub 公鑰）",
                           "Choose the SSH private key (id_ed25519 or id_rsa, say; not the .pub public key)")
        panel.prompt = tr("選擇", "Choose")
        let current = (sshKey.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.directoryURL = current.isEmpty ? ssh : URL(fileURLWithPath: current).deletingLastPathComponent()
        let fill: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.sshKey.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self.showResolved()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: fill) } else { fill(panel.runModal()) }
    }

    // MARK: Filling in from the config

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard sshHost.indexOfSelectedItem >= 0 else { return }
        fill(from: hosts[sshHost.indexOfSelectedItem])
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as AnyObject === sshHost {
            if let match = hosts.first(where: { $0.alias == sshHost.stringValue }) { fill(from: match) } else { showResolved() }
        }
        fillSavedPassword()
    }

    func controlTextDidChange(_ obj: Notification) {
        showResolved()
        if obj.object as AnyObject !== password { forgetPasswordOfAnotherAccount() }
    }

    /// The account the fields name now: user@host:port, through the SSH server if there is one.
    private var account: String? {
        guard case .success(let location) = location else { return nil }
        return location.account
    }

    /// Empties the password once the fields name another account than the one it was for.
    private func forgetPasswordOfAnotherAccount() {
        guard let saved = passwordAccount, saved != account else { return }
        passwordText = ""
        passwordAccount = nil
    }

    /// Fills in the password saved for the account the fields name, while none is typed.
    private func fillSavedPassword() {
        forgetPasswordOfAnotherAccount()
        guard passwordText.isEmpty, let account, let saved = Passwords.password(for: account) else { return }
        passwordText = saved
        passwordAccount = account
    }

    private func fill(from config: SSHHost) {
        sshHost.stringValue = config.alias
        sshPort.stringValue = config.port.map(String.init) ?? ""
        sshKey.stringValue = config.identityFile ?? ""
        showResolved()
    }

    /// Under the SSH server field: where a Host from the config connects, to check it's the right
    /// one. The line stays, blank, for other servers, so the form keeps its size.
    private func showResolved() {
        resolved.stringValue = hosts.first { $0.alias == sshHost.stringValue }.map { "→ " + $0.summary } ?? " "
    }
}
