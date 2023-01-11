//
//  Agent.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import CSSH

/// Direct bindings to libssh2_agent
class Agent {
    
    class PublicKey: CustomStringConvertible {
        
        fileprivate let cIdentity: UnsafeMutablePointer<libssh2_agent_publickey>
        
        var description: String {
            return "Public key: " + String(cString: cIdentity.pointee.comment)
        }
        
        init(cIdentity: UnsafeMutablePointer<libssh2_agent_publickey>) {
            self.cIdentity = cIdentity
        }
        
    }
    
    private let cSession: OpaquePointer
    private let cAgent: OpaquePointer
    
    init(cSession: OpaquePointer) throws {
        guard let cAgent = libssh2_agent_init(cSession) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_agent_init failed")
        }
        self.cSession = cSession
        self.cAgent = cAgent
    }
    
    func connect() throws {
        let code = libssh2_agent_connect(cAgent)
        try SSHError.check(code: code, session: cSession)
    }
    
    func listIdentities() throws {
        let code = libssh2_agent_list_identities(cAgent)
        try SSHError.check(code: code, session: cSession)
    }
    
    func getIdentity(last: PublicKey?) throws -> PublicKey? {
        var publicKeyOptional: UnsafeMutablePointer<libssh2_agent_publickey>? = nil
        let code = libssh2_agent_get_identity(cAgent, &publicKeyOptional, last?.cIdentity)
        
        if code == 1 { // No more identities
            return nil
        }
        
        try SSHError.check(code: code, session: cSession)
        
        guard let publicKey = publicKeyOptional else {
            throw SSHError.genericError("libssh2_agent_get_identity failed")
        }
        
        return PublicKey(cIdentity: publicKey)
    }
    
    func authenticate(username: String, key: PublicKey) -> Bool {
        let code = libssh2_agent_userauth(cAgent, username, key.cIdentity)
        return code == 0
    }
    
    deinit {
        libssh2_agent_disconnect(cAgent)
        libssh2_agent_free(cAgent)
    }
    
}
