//
//  Session.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import Foundation
import CSSH
import Socket

/// Direct bindings to libssh2_session
class Session {

    private static let initResult = libssh2_init(0)

    private let cSession: OpaquePointer
    private var agent: Agent?

    var blocking: Int32 {
        get {
            return libssh2_session_get_blocking(cSession)
        }
        set(newValue) {
            libssh2_session_set_blocking(cSession, newValue)
        }
    }

    /// Per-operation timeout for blocking libssh2 calls, in milliseconds (0 = forever).
    var operationTimeoutMsec: Int {
        get { libssh2_session_get_timeout(cSession) }
        set { libssh2_session_set_timeout(cSession, newValue) }
    }

    init() throws {
        guard Session.initResult == 0 else {
            throw SSHError.genericError("libssh2_init failed")
        }

        guard let cSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.genericError("libssh2_session_init failed")
        }

        self.cSession = cSession
    }

    func handshake(over socket: Socket) throws {
        let code = libssh2_session_handshake(cSession, socket.socketfd)
        try SSHError.check(code: code, session: cSession)
    }

    func authenticate(username: String, privateKey: String, publicKey: String?, passphrase: String?) throws {
        // publicKey nil: libssh2 derives it from the private key.
        let code = libssh2_userauth_publickey_fromfile_ex(cSession,
                                                          username,
                                                          UInt32(username.utf8.count),
                                                          publicKey,
                                                          privateKey,
                                                          passphrase)
        try SSHError.check(code: code, session: cSession)
    }

    func authenticate(username: String, password: String) throws {
        let code = libssh2_userauth_password_ex(cSession,
                                                username,
                                                UInt32(username.utf8.count),
                                                password,
                                                UInt32(password.utf8.count),
                                                nil)
        try SSHError.check(code: code, session: cSession)
    }

    func openSftp() throws -> SFTP  {
        return try SFTP(session: self, cSession: cSession)
    }

    func openCommandChannel() throws -> Channel {
        return try Channel.createForCommand(session: self, cSession: cSession)
    }

    func openAgent() throws -> Agent {
        if let agent = agent {
            return agent
        }
        let newAgent = try Agent(cSession: cSession)
        agent = newAgent
        return newAgent
    }

    // MARK: - Host key verification

    enum HostKeyCheckResult {
        case match
        case mismatch
        case notFound
        case failure
    }

    /// Checks this session's host key against an OpenSSH-format known_hosts file.
    /// When `addUnknown` is true, an unknown host is recorded in the file (trust on
    /// first use) and treated as a match.
    func verifyHostKey(host: String, port: Int32, addUnknown: Bool, knownHostsPath: String) throws {
        var keyLength = 0
        var keyType: Int32 = 0
        guard let keyPointer = libssh2_session_hostkey(cSession, &keyLength, &keyType) else {
            throw SSHError.genericError("host key verification failed: server offered no host key")
        }

        let keyTypeMask: Int32
        switch keyType {
        case LIBSSH2_HOSTKEY_TYPE_RSA: keyTypeMask = LIBSSH2_KNOWNHOST_KEY_SSHRSA
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: keyTypeMask = LIBSSH2_KNOWNHOST_KEY_ECDSA_256
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: keyTypeMask = LIBSSH2_KNOWNHOST_KEY_ECDSA_384
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: keyTypeMask = LIBSSH2_KNOWNHOST_KEY_ECDSA_521
        case LIBSSH2_HOSTKEY_TYPE_ED25519: keyTypeMask = LIBSSH2_KNOWNHOST_KEY_ED25519
        default:
            throw SSHError.genericError("host key verification failed: unsupported host key type \(keyType)")
        }

        guard let knownHosts = libssh2_knownhost_init(cSession) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_knownhost_init failed")
        }
        defer { libssh2_knownhost_free(knownHosts) }

        // A MISSING file means no host is known yet; an unreadable/corrupt file must
        // NOT silently degrade to "empty" (that would re-TOFU every host).
        let readCount = libssh2_knownhost_readfile(knownHosts, knownHostsPath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
        if readCount < 0, FileManager.default.fileExists(atPath: knownHostsPath) {
            throw SSHError.genericError(
                "known_hosts file \(knownHostsPath) exists but could not be parsed (libssh2 code \(readCount)) — " +
                "fix or remove it before connecting"
            )
        }

        let typeMask = Int32(LIBSSH2_KNOWNHOST_TYPE_PLAIN) | Int32(LIBSSH2_KNOWNHOST_KEYENC_RAW) | keyTypeMask
        let checkResult = libssh2_knownhost_checkp(knownHosts, host, Int32(port), keyPointer, keyLength, typeMask, nil)

        switch checkResult {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH:
            return
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH:
            throw SSHError.genericError(
                "HOST KEY MISMATCH for \(host):\(port) — the server's key does not match \(knownHostsPath). " +
                "This may indicate a man-in-the-middle attack. If the host key legitimately changed, " +
                "remove the stale entry from \(knownHostsPath)."
            )
        case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND:
            guard addUnknown else {
                throw SSHError.genericError(
                    "unknown host key for \(host):\(port) (strict verification). " +
                    "Connect once with hostKeyVerification=acceptNew or add the key to \(knownHostsPath)."
                )
            }
            // OpenSSH port encoding: a non-default port is trusted only for that
            // port ("[host]:port"), never leaked to other ports on the same host.
            let storedHost = port == 22 ? host : "[\(host)]:\(port)"
            let addCode = libssh2_knownhost_addc(knownHosts, storedHost, nil, keyPointer, keyLength, nil, 0, typeMask, nil)
            try SSHError.check(code: addCode, session: cSession)
            // Owner-only atomic replace: write to a temp path, then rename over —
            // a concurrent writer can never leave a truncated file behind.
            let temporaryPath = knownHostsPath + ".tmp-\(UUID().uuidString)"
            let writeCode = libssh2_knownhost_writefile(knownHosts, temporaryPath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
            try SSHError.check(code: writeCode, session: cSession)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPath)
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: knownHostsPath),
                    withItemAt: URL(fileURLWithPath: temporaryPath)
                )
                // replaceItemAt can retain the ORIGINAL file's mode — enforce owner-only
                // on the final path too.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsPath)
            } catch {
                try? FileManager.default.removeItem(atPath: temporaryPath)
                throw SSHError.genericError("cannot update \(knownHostsPath): \(error)")
            }
            return
        default:
            throw SSHError.genericError("host key verification failed for \(host):\(port)")
        }
    }

    deinit {
        // The agent belongs to this session: disconnect and release it before the
        // session itself is freed (reverse order avoids a use-after-free).
        agent = nil
        libssh2_session_disconnect_ex(cSession, SSH_DISCONNECT_BY_APPLICATION, "disconnect", "")
        libssh2_session_free(cSession)
    }

}
