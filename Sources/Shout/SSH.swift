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
    ///   - timeout: timeout to use (in msec); default 0
    /// - Throws: SSHError if the SSH session couldn't be created
    public init(host: String, port: Int32 = 22, timeout: UInt = 0) throws {
        self.sock = try Socket.create()
        self.session = try Session()

        session.blocking = 1
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
    /// - Returns: a tuple with the exit code and the combined stdout+stderr output
    public func capture(_ command: String) throws -> (status: Int32, output: String) {
        let channel = try session.openCommandChannel()

        if let ptyType = ptyType {
            try channel.requestPty(type: ptyType.rawValue)
        }

        try channel.exec(command: command)

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOpen = true
        var stderrOpen = true

        while stdoutOpen || stderrOpen {
            if stdoutOpen {
                switch channel.readData(stream: 0) {
                case .data(let data): stdoutData.append(data)
                case .done: stdoutOpen = false
                case .eagain: break
                case .error(let error): throw error
                }
            }
            if stderrOpen {
                switch channel.readData(stream: SSH_EXTENDED_DATA_STDERR) {
                case .data(let data): stderrData.append(data)
                case .done: stderrOpen = false
                case .eagain: break
                case .error(let error): throw error
                }
            }
        }

        try channel.close()
        try? channel.waitClosed()

        var output = String(decoding: stdoutData, as: UTF8.self)
        let stderrString = String(decoding: stderrData, as: UTF8.self)
        if !stderrString.isEmpty {
            output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + stderrString
        }

        if let signal = channel.exitSignal() {
            // A signal-killed command has no meaningful exit status; report failure.
            return (128 + 1, output + "\n[terminated by signal \(signal)]")
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

private let SSH_EXTENDED_DATA_STDERR: Int32 = 1
