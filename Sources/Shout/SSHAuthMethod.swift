//
//  SSHAuthMethod.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import Foundation

public protocol SSHAuthMethod {
    func authenticate(ssh: SSH, username: String) throws
}

/// Password-based authentication method
public struct SSHPassword: SSHAuthMethod {
    
    let password: String
    
    /// Creates a new password-based authentication using the given password
    ///
    /// - Parameter password: the password to authenticate with
    public init(_ password: String) {
        self.password = password
    }
    
    public func authenticate(ssh: SSH, username: String) throws {
        try ssh.session.authenticate(username: username, password: password)
    }
    
}

/// Agent-based authentication method
public struct SSHAgent: SSHAuthMethod {
    
    /// Creates a new agent-based authentication
    public init() {}
    
    public func authenticate(ssh: SSH, username: String) throws {
        let agent = try ssh.session.openAgent()
        try agent.connect()
        try agent.listIdentities()
        
        var last: Agent.PublicKey? = nil
        var success: Bool = false
        while let identity = try agent.getIdentity(last: last) {
            if agent.authenticate(username: username, key: identity) {
                success = true
                break
            }
            last = identity
        }
        guard success else {
            throw SSHError.genericError("failed to authenticate using the agent")
        }
    }
    
}

/// Key-based authentication method
public struct SSHKey: SSHAuthMethod {
    
    public let privateKey: String
    public let publicKey: String
    public let passphrase: String?
    
    /// Creates a new key-based authentication
    ///
    /// - Parameters:
    ///   - privateKey: the path to the private key
    ///   - publicKey: the path to the public key; defaults to private key path + ".pub"
    ///   - passphrase: the passphrase encrypting the key; defaults to nil
    public init(privateKey: String, publicKey: String? = nil, passphrase: String? = nil) {
        self.privateKey = NSString(string: privateKey).expandingTildeInPath
        if let publicKey = publicKey {
            self.publicKey = NSString(string: publicKey).expandingTildeInPath
        } else {
            self.publicKey = self.privateKey + ".pub"
        }
        self.passphrase = passphrase
    }
    
    public func authenticate(ssh: SSH, username: String) throws {
        // Never prompt interactively: Sift runs headless in CI, where a getpass()
        // prompt hangs the run forever. A passphrase-protected key without a
        // passphrase is a configuration error, not a prompt opportunity.
        do {
            try ssh.session.authenticate(username: username,
                                         privateKey: privateKey,
                                         publicKey: publicKey,
                                         passphrase: passphrase)
        } catch {
            throw SSHError.genericError(
                "key authentication failed for \(username) with key \(privateKey)" +
                (passphrase == nil ? " (no passphrase given — if the key is encrypted, provide 'passphrase' in the node config or use ssh-agent)" : "") +
                ": \(error)"
            )
        }
    }
    
}

