//
//  SSH.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import Foundation
import Socket

/// Manages an SSH session.
///
/// Not thread-safe: all calls on one instance must be serialized by the caller
/// (SiftLib confines each instance to a serial DispatchQueue).
public class SSH {

    public enum PtyType: String {
        case vanilla
        case vt100
        case vt102
        case vt220
        case ansi
        case xterm
    }

    let session: Session
    private let sock: Socket

    public var ptyType: PtyType? = nil

    /// Creates a new SSH session
    ///
    /// - Parameters:
    ///   - host: the host to connect to
    ///   - port: the port to connect to; default 22
    ///   - timeout: TCP connect timeout in msec; default 0 (none). Also installed
    ///     as the initial libssh2 operation timeout BEFORE the handshake, so a
    ///     server that accepts TCP but never completes the SSH handshake cannot
    ///     hang the caller forever.
    /// - Throws: SSHError if the SSH session couldn't be created
    public init(host: String, port: Int32 = 22, timeout: UInt = 0) throws {
        self.sock = try Socket.create()
        self.session = try Session()

        session.blocking = 1
        if timeout > 0 {
            session.operationTimeoutMsec = Int(timeout)
        }
        try sock.connect(to: host, port: port, timeout: timeout)
        try session.handshake(over: sock)
    }

    /// Caps how long any single blocking libssh2 operation may take (0 = no limit).
    /// Without this, a black-holed connection blocks its caller forever.
    public func setOperationTimeout(msec: Int) {
        session.operationTimeoutMsec = msec
    }

    /// Verifies the server's host key against an OpenSSH-format known_hosts file.
    /// Call after init (handshake) and before any authenticate call.
    ///
    /// - Parameters:
    ///   - host: hostname used to connect (as recorded in known_hosts)
    ///   - port: port used to connect
    ///   - addUnknown: when true, an unknown host is recorded and accepted (TOFU);
    ///                 when false, an unknown host is an error
    ///   - knownHostsPath: path to the known_hosts file (created when adding)
    public func verifyHostKey(host: String, port: Int32, addUnknown: Bool, knownHostsPath: String) throws {
        try session.verifyHostKey(host: host, port: port, addUnknown: addUnknown, knownHostsPath: knownHostsPath)
    }

    /// Authenticate the session using a public/private key pair
    public func authenticate(username: String, privateKey: String, publicKey: String? = nil, passphrase: String? = nil) throws {
        let key = SSHKey(privateKey: privateKey, publicKey: publicKey, passphrase: passphrase)
        try authenticate(username: username, authMethod: key)
    }

    /// Authenticate the session using a password
    public func authenticate(username: String, password: String) throws {
        try authenticate(username: username, authMethod: SSHPassword(password))
    }

    /// Authenticate the session using the SSH agent
    public func authenticateByAgent(username: String) throws {
        try authenticate(username: username, authMethod: SSHAgent())
    }

    /// Authenticate the session using the given authentication method
    public func authenticate(username: String, authMethod: SSHAuthMethod) throws {
        try authMethod.authenticate(ssh: self, username: username)
    }

    /// Execute a command on the remote server and print its output
    @discardableResult
    public func execute(_ command: String, silent: Bool = false) throws -> Int32 {
        let result = try capture(command)
        if !silent {
            print(result.output, terminator: "")
            fflush(stdout)
        }
        return result.status
    }

    /// Execute a command on the remote server and capture the output.
    ///
    /// Drains both stdout and stderr until EOF (a command that fills the stderr
    /// window would otherwise deadlock), decodes each stream's bytes once at the
    /// end (a multibyte character straddling a read boundary would otherwise fail),
    /// and reports signal-terminated commands as failures even though libssh2
    /// returns exit status 0 for them.
    ///
    /// - Parameter outputTailLimit: when set, only the LAST `outputTailLimit` bytes
    ///   are retained in memory — a runaway remote command cannot balloon the
    ///   controller's memory. The stream is always drained fully either way.
    /// - Returns: a tuple with the exit code and the combined stdout+stderr output
    public func capture(_ command: String, outputTailLimit: Int? = nil) throws -> (status: Int32, output: String) {
        let channel = try session.openCommandChannel()

        if let ptyType = ptyType {
            try channel.requestPty(type: ptyType.rawValue)
        }

        try channel.exec(command: command)

        // stderr is merged into stream 0 at exec time (see Channel.exec), so a
        // single drain loop covers both without any window-fill deadlock.
        var outputData = Data()
        var streamOpen = true
        while streamOpen {
            switch channel.readData(stream: 0) {
            case .data(let data):
                outputData.append(data)
                // Amortized trim: cut back to the tail once we exceed twice the limit.
                if let limit = outputTailLimit, outputData.count > limit * 2 {
                    outputData.removeFirst(outputData.count - limit)
                }
            case .done: streamOpen = false
            case .eagain: break
            case .error(let error): throw error
            }
        }
        if let limit = outputTailLimit, outputData.count > limit {
            outputData.removeFirst(outputData.count - limit)
        }

        try channel.close()
        try? channel.waitClosed()

        let output = String(decoding: outputData, as: UTF8.self)

        if let signal = channel.exitSignal() {
            // Map to the shell convention (128 + signum) so callers can classify —
            // e.g. TERM-killed commands report 143, matching local semantics.
            let signalNumbers: [String: Int32] = [
                "HUP": 1, "INT": 2, "QUIT": 3, "ABRT": 6, "KILL": 9,
                "BUS": 10, "SEGV": 11, "PIPE": 13, "ALRM": 14, "TERM": 15,
            ]
            let number = signalNumbers[signal.uppercased()] ?? 15
            return (128 + number, output + "\n[terminated by signal \(signal)]")
        }
        return (channel.exitStatus(), output)
    }

    /// Execute a command on the remote server, discarding output.
    @discardableResult
    public func executeSilent(_ command: String) throws -> Int32 {
        return try capture(command).status
    }

    /// Open an SFTP session with the remote server
    public func openSftp() throws -> SFTP {
        return try session.openSftp()
    }

}

