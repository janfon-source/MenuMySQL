import AppKit

/// The fields for connecting to a server: where it is, the account and password, the database
/// to open, TLS, and optionally an SSH tunnel. The SSH server field lists the Hosts in
/// ~/.ssh/config; picking one fills in its port and key from the config.
final class ConnectionForm: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
    let view: NSGridView
    private let host: NSTextField
    private let port: NSTextField
    private let user: NSTextField
    private let password = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let database: NSTextField
    private let tls = NSPopUpButton()
    private let useSSH = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sshHost = NSComboBox()
    private let sshPort: NSTextField
    private let sshKey: NSTextField
    private let resolved = NSTextField(labelWithString: "")
    private let hosts: [SSHHost]
    private var sshRows: [NSGridRow] = []

    var firstField: NSView { host.stringValue.isEmpty ? host : password.stringValue.isEmpty ? password : database }

    init(start: ServerLocation?, password saved: String?, hosts: [SSHHost] = SSHConfig.hosts()) {
        self.hosts = hosts
        func field(_ value: String, _ placeholder: String, width: CGFloat = 300) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
        let start = start ?? ServerLocation()
        host = field(start.host, "127.0.0.1")
        port = field(start.port == 3306 ? "" : String(start.port), "3306")
        user = field(start.user, "root")
        database = field(start.database ?? "", tr("選填，之後也可以在左上角切換", "Optional; switch at the top left later"))
        sshPort = field(start.sshPort.map(String.init) ?? "", tr("22（選填）", "22 (optional)"))
        sshKey = field(start.sshIdentity ?? "", tr("~/.ssh/id_ed25519（選填）", "~/.ssh/id_ed25519 (optional)"))
        password.stringValue = saved ?? ""
        password.placeholderString = tr("密碼", "Password")
        password.widthAnchor.constraint(equalToConstant: 300).isActive = true
        remember.title = tr("把密碼存在鑰匙圈", "Save the password in the keychain")
        remember.state = .on
        tls.addItems(withTitles: [tr("伺服器支援就使用（建議）", "When the server offers it (recommended)"),
                                  tr("一定要使用", "Required"), tr("不使用", "Off")])
        tls.selectItem(at: MySQLWire.TLSMode.allCases.firstIndex(of: start.tls) ?? 0)
        useSSH.title = tr("透過 SSH 通道連線（伺服器只接受本機連線時使用）", "Connect through an SSH tunnel (for a server that only takes local connections)")
        useSSH.state = start.usesSSH ? .on : .off
        resolved.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resolved.textColor = .secondaryLabelColor
        let hostHint = NSTextField(labelWithString: tr("使用 SSH 通道時，這是從 SSH 主機看到的位址，通常是 127.0.0.1",
                                                      "With an SSH tunnel, the address as the SSH server sees it: usually 127.0.0.1"))
        hostHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostHint.textColor = .secondaryLabelColor
        view = NSGridView(views: [
            [NSTextField(labelWithString: tr("主機", "Host")), host],
            [NSTextField(labelWithString: tr("連接埠", "Port")), port],
            [NSTextField(labelWithString: tr("帳號", "User")), user],
            [NSTextField(labelWithString: tr("密碼", "Password")), password],
            [NSGridCell.emptyContentView, remember],
            [NSTextField(labelWithString: tr("資料庫", "Database")), database],
            [NSTextField(labelWithString: "SSL/TLS"), tls],
            [NSGridCell.emptyContentView, useSSH],
            [NSTextField(labelWithString: tr("SSH 主機", "SSH Server")), sshHost],
            [NSGridCell.emptyContentView, resolved],
            [NSTextField(labelWithString: tr("SSH 連接埠", "SSH Port")), sshPort],
            [NSTextField(labelWithString: tr("私鑰", "Private Key")), sshKey],
            [NSGridCell.emptyContentView, hostHint],
        ])
        super.init()

        sshHost.stringValue = start.sshDestination ?? ""
        sshHost.placeholderString = hosts.isEmpty ? "user@example.com" : tr("從 ~/.ssh/config 選擇，或輸入 user@host", "Pick from ~/.ssh/config, or type user@host")
        sshHost.addItems(withObjectValues: hosts.map(\.alias))
        sshHost.numberOfVisibleItems = 12
        sshHost.completes = true
        sshHost.delegate = self
        sshHost.widthAnchor.constraint(equalToConstant: 300).isActive = true
        useSSH.target = self
        useSSH.action = #selector(sshToggled(_:))
        view.column(at: 0).xPlacement = .trailing
        view.rowAlignment = .firstBaseline
        view.row(at: 4).topPadding = -2
        view.row(at: 7).topPadding = 6
        view.row(at: 9).topPadding = -4
        sshRows = (8...12).map { view.row(at: $0) }
        showResolved()
        sshToggled(nil)
    }

    /// What was entered, or nil if the host or account is missing.
    var location: ServerLocation? {
        func value(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespaces) }
        guard !value(host).isEmpty, !value(user).isEmpty else { return nil }
        var location = ServerLocation()
        location.host = value(host)
        location.port = Int(value(port)) ?? 3306
        location.user = value(user)
        location.database = value(database).isEmpty ? nil : value(database)
        location.tls = MySQLWire.TLSMode.allCases[max(0, tls.indexOfSelectedItem)]
        if useSSH.state == .on {
            guard !value(sshHost).isEmpty else { return nil }
            location.sshDestination = value(sshHost)
            location.sshPort = Int(value(sshPort))
            location.sshIdentity = value(sshKey).isEmpty ? nil : value(sshKey)
        }
        return location
    }

    var enteredPassword: String { password.stringValue }
    var savesPassword: Bool { remember.state == .on }

    /// The SSH fields show only while the tunnel is on.
    @objc private func sshToggled(_ sender: Any?) {
        for row in sshRows { row.isHidden = useSSH.state != .on }
        if let window = view.window {
            view.frame.size = view.fittingSize
            window.layoutIfNeeded()
        } else {
            view.frame.size = view.fittingSize
        }
        if sender != nil, useSSH.state == .on { view.window?.makeFirstResponder(sshHost) }
    }

    // MARK: Filling in from the config

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard sshHost.indexOfSelectedItem >= 0 else { return }
        fill(from: hosts[sshHost.indexOfSelectedItem])
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as AnyObject === sshHost else { return }
        if let match = hosts.first(where: { $0.alias == sshHost.stringValue }) { fill(from: match) } else { showResolved() }
    }

    func controlTextDidChange(_ obj: Notification) {
        showResolved()
    }

    private func fill(from config: SSHHost) {
        sshHost.stringValue = config.alias
        sshPort.stringValue = config.port.map(String.init) ?? ""
        sshKey.stringValue = config.identityFile ?? ""
        showResolved()
    }

    private func showResolved() {
        resolved.stringValue = hosts.first { $0.alias == sshHost.stringValue }.map { "→ " + $0.summary } ?? " "
    }
}
