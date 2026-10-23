import CryptoKit
import Foundation
import Security

/// MySQL's client/server protocol, as MySQL and MariaDB both speak it: signing in (with
/// mysql_native_password, caching_sha2_password or sha256_password, over TLS when the server
/// offers it), and running text queries. One connection, used from one thread; every call
/// waits for its answer, as the rest of the app does.
final class MySQLWire {
    enum Failure: Error {
        /// The server refused the statement; the connection is still good.
        case server(code: Int, state: String, message: String)
        /// The connection broke or timed out, and can't be used again.
        case connection(String)
    }

    struct ColumnInfo {
        let name: String
        let type: UInt8
        let flags: UInt16
        let charset: UInt16
    }

    struct Result {
        var columns: [ColumnInfo] = []
        var rows: [[Value]] = []
        var affectedRows: UInt64 = 0
        var lastInsertID: UInt64 = 0
    }

    enum TLSMode: String, CaseIterable {
        /// When the server offers it, as the mysql client does by default.
        case preferred
        case required
        case disabled
    }

    private(set) var serverVersion = ""
    private(set) var connectionID: UInt32 = 0
    private(set) var usesTLS = false
    /// The server's capability flags, from its greeting.
    private var serverCapabilities: UInt32 = 0

    private var socket: Int32 = -1
    private var tls: SSLContext?
    private var sequence: UInt8 = 0
    private var buffer = [UInt8]()
    private var bufferStart = 0

    /// How long to wait for the server to connect, and then for each answer.
    static let connectTimeout: TimeInterval = 10
    static var readTimeout: TimeInterval = 60

    // Capability flags.
    private static let longPassword: UInt32 = 1
    private static let longFlag: UInt32 = 4
    private static let connectWithDB: UInt32 = 8
    private static let protocol41: UInt32 = 512
    private static let ssl: UInt32 = 2048
    private static let transactions: UInt32 = 8192
    private static let secureConnection: UInt32 = 32768
    private static let multiStatements: UInt32 = 1 << 16
    private static let multiResults: UInt32 = 1 << 17
    private static let pluginAuth: UInt32 = 1 << 19
    private static let pluginAuthLenencData: UInt32 = 1 << 21

    /// The server's status flag for another result following this one.
    private static let moreResultsExist: UInt16 = 0x0008

    /// utf8mb4_general_ci, which every server since MySQL 5.5 and MariaDB 5.5 knows.
    private static let utf8mb4: UInt8 = 45

    init(host: String, port: Int, user: String, password: String, database: String?, tls mode: TLSMode) throws {
        socket = try Self.open(host: host, port: port)
        do {
            try handshake(host: host, user: user, password: password, database: database, mode: mode)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard socket >= 0 else { return }
        if let tls { SSLClose(tls) }
        tls = nil
        Darwin.close(socket)
        socket = -1
    }

    var isOpen: Bool { socket >= 0 }

    // MARK: Commands

    /// Runs one or more statements (separated by semicolons); returns the result of each.
    func query(_ sql: String) throws -> [Result] {
        try command(0x03, Array(sql.utf8))
        var results: [Result] = []
        while true {
            let (result, more) = try readResult()
            results.append(result)
            if !more { return results }
        }
    }

    /// Makes `name` the current database.
    func use(_ name: String) throws {
        try command(0x02, Array(name.utf8))
        _ = try readOK()
    }

    func ping() throws {
        try command(0x0e, [])
        _ = try readOK()
    }

    /// Says goodbye, so the server doesn't log an aborted connection.
    func quit() {
        guard isOpen else { return }
        try? command(0x01, [])
        close()
    }

    private func command(_ code: UInt8, _ payload: [UInt8]) throws {
        guard isOpen else { throw Failure.connection(tr("連線已中斷。", "The connection was lost.")) }
        sequence = 0
        try writePacket([code] + payload)
    }

    /// One result: an OK packet, or columns and rows. Says whether another result follows.
    private func readResult() throws -> (Result, Bool) {
        var packet = try readPacket()
        switch packet.first {
        case 0x00:
            let ok = Reader(packet).okPacket()
            return (Result(affectedRows: ok.affected, lastInsertID: ok.insertID), ok.status & Self.moreResultsExist != 0)
        case 0xff:
            throw Self.error(from: packet)
        case 0xfb:
            // LOAD DATA LOCAL INFILE asks for a file from this Mac; none is sent.
            try writePacket([])
            packet = try readPacket()
            if packet.first == 0xff { throw Self.error(from: packet) }
            let ok = Reader(packet).okPacket()
            return (Result(affectedRows: ok.affected), ok.status & Self.moreResultsExist != 0)
        default:
            break
        }
        var reader = Reader(packet)
        let count = Int(reader.lenenc() ?? 0)
        var result = Result()
        for _ in 0..<count {
            var definition = Reader(try readPacket())
            _ = definition.lenencBytes()   // catalog
            _ = definition.lenencBytes()   // schema
            _ = definition.lenencBytes()   // table
            _ = definition.lenencBytes()   // original table
            let name = definition.lenencString()
            _ = definition.lenencBytes()   // original name
            _ = definition.lenenc()        // length of the fixed fields
            let charset = definition.u16()
            _ = definition.u32()           // column length
            let type = definition.u8()
            let flags = definition.u16()
            result.columns.append(ColumnInfo(name: name, type: type, flags: flags, charset: charset))
        }
        var status: UInt16 = 0
        let end = try readPacket()   // the EOF after the columns
        if end.first == 0xff { throw Self.error(from: end) }
        while true {
            let row = try readPacket()
            if row.first == 0xfe, row.count < 9 {
                var eof = Reader(row)
                _ = eof.u8()
                _ = eof.u16()   // warnings
                status = eof.u16()
                break
            }
            if row.first == 0xff { throw Self.error(from: row) }
            var fields = Reader(row)
            result.rows.append(result.columns.map { column in
                fields.peek() == 0xfb ? { fields.skip(1); return .null }() : Self.value(fields.lenencBytes() ?? [], column)
            })
        }
        return (result, status & Self.moreResultsExist != 0)
    }

    private func readOK() throws -> Reader.OK {
        let packet = try readPacket()
        if packet.first == 0xff { throw Self.error(from: packet) }
        return Reader(packet).okPacket()
    }

    /// A field as text comes in, read by its column's type: numbers as numbers, binary strings
    /// and BLOBs as bytes, and the rest (dates, DECIMALs, JSON) as the text the server wrote.
    private static func value(_ bytes: [UInt8], _ column: ColumnInfo) -> Value {
        switch column.type {
        case 1, 2, 3, 8, 9, 13:   // TINYINT, SMALLINT, INT, BIGINT, MEDIUMINT, YEAR
            let text = String(decoding: bytes, as: UTF8.self)
            return Int64(text).map(Value.integer) ?? .text(text)   // a BIGINT UNSIGNED past Int64 stays text
        case 4, 5:                // FLOAT, DOUBLE
            let text = String(decoding: bytes, as: UTF8.self)
            return Double(text).map(Value.real) ?? .text(text)
        case 16:                  // BIT, its bits as a number
            return .integer(bytes.suffix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) })
        case 15, 249, 250, 251, 252, 253, 254, 255:   // strings and BLOBs, GEOMETRY
            if column.charset == 63 || column.type == 255 { return .blob(Data(bytes)) }
            return .text(String(decoding: bytes, as: UTF8.self))
        default:
            return .text(String(decoding: bytes, as: UTF8.self))
        }
    }

    private static func error(from packet: [UInt8]) -> Failure {
        var reader = Reader(packet)
        _ = reader.u8()
        let code = Int(reader.u16())
        var state = ""
        if reader.peek() == UInt8(ascii: "#") {
            reader.skip(1)
            state = String(decoding: reader.bytes(5), as: UTF8.self)
        }
        return .server(code: code, state: state, message: String(decoding: reader.rest(), as: UTF8.self))
    }

    // MARK: Signing in

    private func handshake(host: String, user: String, password: String, database: String?, mode: TLSMode) throws {
        let greeting = try readPacket()
        if greeting.first == 0xff { throw Self.error(from: greeting) }
        var reader = Reader(greeting)
        guard reader.u8() == 10 else {
            throw Failure.connection(tr("這不是 MySQL 或 MariaDB 伺服器，或版本太舊。", "This isn’t a MySQL or MariaDB server, or it’s too old."))
        }
        serverVersion = reader.nulString()
        connectionID = reader.u32()
        var scramble = reader.bytes(8)
        reader.skip(1)
        serverCapabilities = UInt32(reader.u16())
        _ = reader.u8()    // the server's character set
        _ = reader.u16()   // status
        serverCapabilities |= UInt32(reader.u16()) << 16
        let scrambleLength = Int(reader.u8())
        reader.skip(10)
        if serverCapabilities & Self.secureConnection != 0 {
            scramble += reader.bytes(max(13, scrambleLength - 8)).prefix(12)
        }
        var plugin = serverCapabilities & Self.pluginAuth != 0 ? reader.nulString() : "mysql_native_password"
        if plugin.isEmpty { plugin = "mysql_native_password" }

        var capabilities = Self.longPassword | Self.longFlag | Self.protocol41 | Self.transactions | Self.secureConnection
            | Self.multiStatements | Self.multiResults | Self.pluginAuth | Self.pluginAuthLenencData
        if let database, !database.isEmpty { capabilities |= Self.connectWithDB }
        capabilities &= serverCapabilities | Self.connectWithDB

        let serverTLS = serverCapabilities & Self.ssl != 0
        if mode == .required, !serverTLS {
            throw Failure.connection(tr("伺服器不支援 SSL/TLS 加密連線。", "The server doesn’t offer SSL/TLS."))
        }
        if mode != .disabled, serverTLS {
            capabilities |= Self.ssl
            var request = Writer()
            request.u32(capabilities)
            request.u32(1 << 24)
            request.u8(Self.utf8mb4)
            request.zeros(23)
            try writePacket(request.bytes)
            try startTLS(host: host)
        }

        var response = Writer()
        response.u32(capabilities)
        response.u32(1 << 24)   // the largest packet this client takes
        response.u8(Self.utf8mb4)
        response.zeros(23)
        response.nulString(user)
        let auth = Self.authResponse(plugin: plugin, password: password, scramble: scramble, tls: usesTLS)
        if capabilities & Self.pluginAuthLenencData != 0 {
            response.lenenc(UInt64(auth.count))
            response.append(auth)
        } else {
            response.u8(UInt8(auth.count))
            response.append(auth)
        }
        if capabilities & Self.connectWithDB != 0 { response.nulString(database ?? "") }
        if capabilities & Self.pluginAuth != 0 { response.nulString(plugin) }
        try writePacket(response.bytes)
        try finishAuthentication(plugin: plugin, password: password, scramble: scramble)
    }

    /// Answers the server until it says OK: switching to another plugin, or (for the SHA-256
    /// plugins) sending the password itself, in the clear over TLS or else encrypted with the
    /// server's RSA key.
    private func finishAuthentication(plugin: String, password: String, scramble: [UInt8]) throws {
        var plugin = plugin, scramble = scramble
        while true {
            let packet = try readPacket()
            switch packet.first {
            case 0x00:
                return
            case 0xff:
                throw Self.error(from: packet)
            case 0xfe:
                var reader = Reader(packet)
                reader.skip(1)
                plugin = reader.nulString()
                var data = reader.rest()
                if data.last == 0 { data.removeLast() }
                scramble = data
                try writePacket(Self.authResponse(plugin: plugin, password: password, scramble: scramble, tls: usesTLS))
            case 0x01:
                let data = Array(packet.dropFirst())
                if data == [3] { continue }   // caching_sha2_password: the server had it cached; OK follows
                if data == [4] || plugin == "sha256_password" && data.count <= 1 {
                    // The full exchange: the password itself.
                    if usesTLS {
                        try writePacket(Array(password.utf8) + [0])
                    } else {
                        try writePacket([plugin == "caching_sha2_password" ? 2 : 1])   // ask for the public key
                    }
                } else {
                    // The server's public key, in PEM.
                    try writePacket(try Self.encrypt(password, scramble: scramble, pem: String(decoding: data, as: UTF8.self)))
                }
            default:
                throw Failure.connection(tr("伺服器的登入回應無法辨識。", "The server’s sign-in reply wasn’t understood."))
            }
        }
    }

    private static func authResponse(plugin: String, password: String, scramble: [UInt8], tls: Bool) -> [UInt8] {
        let secret = Array(password.utf8)
        switch plugin {
        case "mysql_native_password":
            guard !secret.isEmpty else { return [] }
            // SHA1(password) XOR SHA1(scramble + SHA1(SHA1(password)))
            let hash = Array(Insecure.SHA1.hash(data: secret))
            let double = Array(Insecure.SHA1.hash(data: hash))
            let salted = Array(Insecure.SHA1.hash(data: scramble + double))
            return zip(hash, salted).map { $0 ^ $1 }
        case "caching_sha2_password":
            guard !secret.isEmpty else { return [] }
            // SHA256(password) XOR SHA256(SHA256(SHA256(password)) + scramble)
            let hash = Array(SHA256.hash(data: secret))
            let double = Array(SHA256.hash(data: hash))
            let salted = Array(SHA256.hash(data: double + scramble))
            return zip(hash, salted).map { $0 ^ $1 }
        case "sha256_password":
            if secret.isEmpty { return [0] }
            return tls ? secret + [0] : [1]   // [1]: send the public key
        case "mysql_clear_password":
            return secret + [0]
        default:
            return []
        }
    }

    /// The password for the full SHA-256 exchange without TLS: XORed with the scramble and
    /// encrypted with the server's RSA public key (OAEP padding).
    private static func encrypt(_ password: String, scramble: [UInt8], pem: String) throws -> [UInt8] {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard var der = Data(base64Encoded: body), !scramble.isEmpty else {
            throw Failure.connection(tr("無法讀取伺服器的公開金鑰。", "Couldn’t read the server’s public key."))
        }
        if !pem.contains("BEGIN RSA PUBLIC KEY"), let inner = rsaKey(inSubjectPublicKeyInfo: [UInt8](der)) { der = Data(inner) }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
            throw Failure.connection(tr("無法讀取伺服器的公開金鑰。", "Couldn’t read the server’s public key."))
        }
        let plain = (Array(password.utf8) + [0]).enumerated().map { $1 ^ scramble[$0 % scramble.count] }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plain) as CFData, nil) else {
            throw Failure.connection(tr("無法加密密碼。", "Couldn’t encrypt the password."))
        }
        return [UInt8](encrypted as Data)
    }

    /// The RSAPublicKey inside a SubjectPublicKeyInfo, which is what Security reads:
    /// SEQUENCE { SEQUENCE { algorithm }, BIT STRING { 0, RSAPublicKey } }.
    private static func rsaKey(inSubjectPublicKeyInfo der: [UInt8]) -> [UInt8]? {
        var i = 0
        func header(_ tag: UInt8) -> Int? {
            guard i < der.count, der[i] == tag else { return nil }
            i += 1
            guard i < der.count else { return nil }
            var length = Int(der[i]); i += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count <= 4, i + count <= der.count else { return nil }
                length = der[i..<i + count].reduce(0) { $0 << 8 | Int($1) }
                i += count
            }
            return length
        }
        guard header(0x30) != nil, let algorithm = header(0x30) else { return nil }
        i += algorithm
        guard let bits = header(0x03), bits > 1, i + bits <= der.count else { return nil }
        return Array(der[(i + 1)..<(i + bits)])
    }

    // MARK: TLS

    /// Turns the connection into a TLS one, as the server expects after the SSL request. The
    /// server's certificate isn't checked, as the mysql client doesn't by default: servers mostly
    /// make their own.
    private func startTLS(host: String) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw Failure.connection(tr("無法建立 TLS 連線。", "Couldn’t start TLS."))
        }
        SSLSetIOFuncs(context, { connection, data, length in
            let socket = Int32(Int(bitPattern: connection) - 1)
            let wanted = length.pointee
            var done = 0
            while done < wanted {
                let n = recv(socket, data.advanced(by: done), wanted - done, 0)
                if n > 0 { done += n; continue }
                length.pointee = done
                if n == 0 { return errSSLClosedGraceful }
                if errno == EINTR { continue }
                return errno == EAGAIN ? errSSLWouldBlock : errSSLClosedAbort
            }
            return noErr
        }, { connection, data, length in
            let socket = Int32(Int(bitPattern: connection) - 1)
            let wanted = length.pointee
            var done = 0
            while done < wanted {
                let n = send(socket, data.advanced(by: done), wanted - done, 0)
                if n > 0 { done += n; continue }
                if n < 0, errno == EINTR { continue }
                length.pointee = done
                return n < 0 && errno == EAGAIN ? errSSLWouldBlock : errSSLClosedAbort
            }
            return noErr
        })
        SSLSetConnection(context, UnsafeRawPointer(bitPattern: Int(socket) + 1))
        SSLSetPeerDomainName(context, host, host.utf8.count)
        SSLSetSessionOption(context, .breakOnServerAuth, true)
        SSLSetProtocolVersionMin(context, .tlsProtocol12)
        while true {
            let status = SSLHandshake(context)
            if status == errSSLPeerAuthCompleted { continue }   // where the certificate would be checked
            guard status == noErr else {
                throw Failure.connection(tr("TLS 交握失敗（\(status)）。", "The TLS handshake failed (\(status))."))
            }
            break
        }
        tls = context
        usesTLS = true
    }

    // MARK: Packets

    /// A packet's payload: a 3-byte length and a sequence number come first, and a payload of
    /// 16 MB or more goes on in the packets after.
    private func readPacket() throws -> [UInt8] {
        var payload = [UInt8]()
        while true {
            let header = try read(4)
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            sequence = header[3] &+ 1
            payload += try read(length)
            if length < 0xffffff { return payload }
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var offset = 0
        while true {
            let length = min(payload.count - offset, 0xffffff)
            var packet = [UInt8(length & 0xff), UInt8(length >> 8 & 0xff), UInt8(length >> 16 & 0xff), sequence]
            sequence &+= 1
            packet += payload[offset..<offset + length]
            try write(packet)
            offset += length
            if length < 0xffffff { return }
        }
    }

    private func read(_ count: Int) throws -> [UInt8] {
        while buffer.count - bufferStart < count {
            if bufferStart > 0 {
                buffer.removeFirst(bufferStart)
                bufferStart = 0
            }
            var chunk = [UInt8](repeating: 0, count: max(65536, count - buffer.count))
            let n = try receive(&chunk)
            buffer += chunk.prefix(n)
        }
        let bytes = Array(buffer[bufferStart..<bufferStart + count])
        bufferStart += count
        return bytes
    }

    private func receive(_ chunk: inout [UInt8]) throws -> Int {
        guard isOpen else { throw Failure.connection(tr("連線已中斷。", "The connection was lost.")) }
        let capacity = chunk.count
        if let tls {
            var processed = 0
            let status = chunk.withUnsafeMutableBytes { SSLRead(tls, $0.baseAddress!, capacity, &processed) }
            if processed > 0 { return processed }
            close()
            throw Failure.connection(status == errSSLWouldBlock ? Self.timeoutMessage : tr("伺服器關閉了連線。", "The server closed the connection."))
        }
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, capacity, 0) }
            if n > 0 { return n }
            if n < 0, errno == EINTR { continue }
            let timedOut = n < 0 && errno == EAGAIN
            close()
            throw Failure.connection(timedOut ? Self.timeoutMessage : tr("伺服器關閉了連線。", "The server closed the connection."))
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw Failure.connection(tr("連線已中斷。", "The connection was lost.")) }
        if let tls {
            var processed = 0
            let status = bytes.withUnsafeBytes { SSLWrite(tls, $0.baseAddress!, bytes.count, &processed) }
            guard status == noErr, processed == bytes.count else {
                close()
                throw Failure.connection(tr("無法傳送到伺服器。", "Couldn’t send to the server."))
            }
            return
        }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { send(socket, $0.baseAddress!.advanced(by: done), bytes.count - done, 0) }
            if n > 0 { done += n; continue }
            if n < 0, errno == EINTR { continue }
            close()
            throw Failure.connection(tr("無法傳送到伺服器。", "Couldn’t send to the server."))
        }
    }

    private static var timeoutMessage: String {
        tr("伺服器沒有回應（超過 \(Int(readTimeout)) 秒），連線已中斷。", "The server didn’t answer within \(Int(readTimeout)) seconds, so the connection was dropped.")
    }

    // MARK: Socket

    /// Connects to the server, trying each address the name has, within the connect timeout.
    private static func open(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0 else {
            throw Failure.connection(tr("找不到主機「\(host)」。", "The server “\(host)” can’t be found.")
                                     + " (\(String(cString: gai_strerror(status))))")
        }
        defer { freeaddrinfo(list) }
        var failure = ECONNREFUSED
        var address = list
        while let info = address?.pointee {
            address = info.ai_next
            let s = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard s >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(s, F_GETFL)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            var result = connect(s, info.ai_addr, info.ai_addrlen)
            if result != 0, errno == EINPROGRESS {
                var poller = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, Int32(connectTimeout * 1000)) == 1 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &length)
                    result = error == 0 ? 0 : -1
                    errno = error
                } else {
                    result = -1
                    errno = ETIMEDOUT
                }
            }
            if result == 0 {
                _ = fcntl(s, F_SETFL, flags)
                var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                return s
            }
            failure = errno
            Darwin.close(s)
        }
        switch failure {
        case ETIMEDOUT:
            throw Failure.connection(tr("連不上 \(host):\(port)（逾時）。", "Couldn’t reach \(host):\(port) (timed out)."))
        case ECONNREFUSED:
            throw Failure.connection(tr("\(host):\(port) 拒絕連線，請確認伺服器有在執行、連接埠正確。",
                                        "\(host):\(port) refused the connection. Check that the server is running and the port is right."))
        default:
            throw Failure.connection(tr("連不上 \(host):\(port)：", "Couldn’t reach \(host):\(port): ") + String(cString: strerror(failure)))
        }
    }
}

// MARK: - Reading and writing protocol fields

private struct Reader {
    private let data: [UInt8]
    private var i = 0

    init(_ data: [UInt8]) { self.data = data }

    func peek() -> UInt8? { i < data.count ? data[i] : nil }
    mutating func skip(_ n: Int) { i = min(data.count, i + n) }

    mutating func u8() -> UInt8 {
        guard i < data.count else { return 0 }
        defer { i += 1 }
        return data[i]
    }

    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }

    mutating func bytes(_ n: Int) -> [UInt8] {
        let end = min(data.count, i + n)
        defer { i = end }
        return Array(data[i..<end])
    }

    mutating func rest() -> [UInt8] { bytes(data.count - i) }

    /// A length-encoded integer; nil for 0xfb, which stands for NULL.
    mutating func lenenc() -> UInt64? {
        let first = u8()
        switch first {
        case 0xfb: return nil
        case 0xfc: return UInt64(u16())
        case 0xfd: return UInt64(u16()) | UInt64(u8()) << 16
        case 0xfe: return UInt64(u32()) | UInt64(u32()) << 32
        default: return UInt64(first)
        }
    }

    mutating func lenencBytes() -> [UInt8]? {
        guard let length = lenenc() else { return nil }
        return bytes(Int(clamping: length))
    }

    mutating func lenencString() -> String { String(decoding: lenencBytes() ?? [], as: UTF8.self) }

    mutating func nulString() -> String {
        let end = data[i...].firstIndex(of: 0) ?? data.count
        defer { i = min(data.count, end + 1) }
        return String(decoding: data[i..<end], as: UTF8.self)
    }

    struct OK {
        var affected: UInt64 = 0
        var insertID: UInt64 = 0
        var status: UInt16 = 0
    }

    func okPacket() -> OK {
        var reader = self
        _ = reader.u8()
        return OK(affected: reader.lenenc() ?? 0, insertID: reader.lenenc() ?? 0, status: reader.u16())
    }
}

private struct Writer {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(v >> UInt32(shift) & 0xff)) } }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
    mutating func append(_ data: [UInt8]) { bytes += data }
    mutating func nulString(_ s: String) { bytes += Array(s.utf8) + [0] }
    mutating func lenenc(_ v: UInt64) {
        switch v {
        case ..<0xfb: bytes.append(UInt8(v))
        case ..<0x10000: bytes += [0xfc, UInt8(v & 0xff), UInt8(v >> 8)]
        case ..<0x1000000: bytes += [0xfd, UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16)]
        default: bytes.append(0xfe); for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(v >> UInt64(shift) & 0xff)) }
        }
    }
}
