import Foundation

/// A port on this Mac forwarded over SSH to the database server, for a server that only takes
/// connections from the machine it's on (or its private network). `ssh -N -L` keeps it open
/// until the database is closed.
final class SSHTunnel {
    let localPort: Int
    private let process = Process()
    private let errors: URL

    static var sshPath = "/usr/bin/ssh"

    var isRunning: Bool { process.isRunning }

    init(_ server: ServerLocation) throws {
        guard let destination = server.sshDestination, !destination.isEmpty else {
            throw DatabaseError(message: tr("沒有指定 SSH 主機。", "No SSH server was given."))
        }
        localPort = try Self.freePort()
        // The database's host as the SSH server sees it: localhost there is the server itself.
        let target = server.host.isEmpty ? "127.0.0.1" : server.host
        var arguments = [
            "-N",
            "-o", "BatchMode=yes",                  // never stop to ask for a password
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlPath=none",               // a tunnel of its own, not a shared connection
            "-L", "127.0.0.1:\(localPort):\(target.contains(":") ? "[\(target)]" : target):\(server.port)",
        ]
        if let port = server.sshPort { arguments += ["-p", String(port)] }
        if let identity = server.sshIdentity, !identity.isEmpty {
            arguments += ["-i", (identity as NSString).expandingTildeInPath]
        }
        arguments.append(destination)

        errors = FileManager.default.temporaryDirectory.appendingPathComponent("menumysql-ssh-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()

        // Ready once the local port takes connections; ssh quitting first means it failed.
        let deadline = Date().addingTimeInterval(15)
        while !Self.accepts(localPort) {
            if !process.isRunning {
                let message = Self.cleanError(String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self),
                                              status: process.terminationStatus)
                try? FileManager.default.removeItem(at: errors)
                throw DatabaseError(message: message)
            }
            if Date() > deadline {
                close()
                throw DatabaseError(message: tr("SSH 主機 \(destination) 沒有回應（超過 15 秒）。", "The SSH server \(destination) didn’t answer within 15 seconds."))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    deinit { close() }

    func close() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: errors)
    }

    /// A port nobody is listening on, from the system.
    private static func freePort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(s) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, length) == 0 && getsockname(s, $0, &length) == 0
            }
        }
        guard bound else { throw DatabaseError(message: tr("找不到可用的本機連接埠。", "No free port on this Mac.")) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func accepts(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(s) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// ssh's messages, without the ones that don't help.
    private static func cleanError(_ text: String, status: Int32) -> String {
        let lines = text.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("Warning: Permanently added") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard var message = lines.first else { return tr("SSH 連線失敗（代碼 \(status)）。", "The SSH connection failed (code \(status)).") }
        if message.contains("Permission denied") {
            message += "\n" + tr("隨手MySQL 用 SSH 金鑰或 ssh-agent 登入 SSH 主機，不會詢問密碼；請先設定好金鑰登入。",
                                 "MenuMySQL signs in to the SSH server with SSH keys or ssh-agent and never asks for a password; set up key login first.")
        }
        return message
    }
}
