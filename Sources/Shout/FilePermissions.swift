//
//  FilePermissions.swift
//  Shout
//
//  Created by Brandon Evans on 1/25/19.
//

import Foundation
import CSSH

public struct Permissions: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
    public static let read = Permissions(rawValue: 1 << 1)
    public static let write = Permissions(rawValue: 1 << 2)
    public static let execute = Permissions(rawValue: 1 << 3)
}

public struct FilePermissions: RawRepresentable {
    public var owner: Permissions
    public var group: Permissions
    public var others: Permissions

    public init(owner: Permissions, group: Permissions, others: Permissions) {
        self.owner = owner
        self.group = group
        self.others = others
    }

    public init(rawValue: Int32) {
        var owner: Permissions = []
        var group: Permissions = []
        var others: Permissions = []

        if (rawValue & LIBSSH2_SFTP_S_IRUSR == LIBSSH2_SFTP_S_IRUSR) { owner.insert(.read) }
        if (rawValue & LIBSSH2_SFTP_S_IWUSR == LIBSSH2_SFTP_S_IWUSR) { owner.insert(.write) }
        if (rawValue & LIBSSH2_SFTP_S_IXUSR == LIBSSH2_SFTP_S_IXUSR) { owner.insert(.execute) }
        if (rawValue & LIBSSH2_SFTP_S_IRGRP == LIBSSH2_SFTP_S_IRGRP) { group.insert(.read) }
        if (rawValue & LIBSSH2_SFTP_S_IWGRP == LIBSSH2_SFTP_S_IWGRP) { group.insert(.write) }
        if (rawValue & LIBSSH2_SFTP_S_IXGRP == LIBSSH2_SFTP_S_IXGRP) { group.insert(.execute) }
        if (rawValue & LIBSSH2_SFTP_S_IROTH == LIBSSH2_SFTP_S_IROTH) { others.insert(.read) }
        if (rawValue & LIBSSH2_SFTP_S_IWOTH == LIBSSH2_SFTP_S_IWOTH) { others.insert(.write) }
        if (rawValue & LIBSSH2_SFTP_S_IXOTH == LIBSSH2_SFTP_S_IXOTH) { others.insert(.execute) }

        self.init(owner: owner, group: group, others: others)
    }

    public var rawValue: Int32 {
        var flag: Int32 = 0

        if owner.contains(.read) { flag |= LIBSSH2_SFTP_S_IRUSR }
        if owner.contains(.write) { flag |= LIBSSH2_SFTP_S_IWUSR }
        if owner.contains(.execute) { flag |= LIBSSH2_SFTP_S_IXUSR }
        
        if group.contains(.read) { flag |= LIBSSH2_SFTP_S_IRGRP }
        if group.contains(.write) { flag |= LIBSSH2_SFTP_S_IWGRP }
        if group.contains(.execute) { flag |= LIBSSH2_SFTP_S_IXGRP }
        
        if others.contains(.read) { flag |= LIBSSH2_SFTP_S_IROTH }
        if others.contains(.write) { flag |= LIBSSH2_SFTP_S_IWOTH }
        if others.contains(.execute) { flag |= LIBSSH2_SFTP_S_IXOTH }
        
        return flag
    }

    public static let `default` = FilePermissions(owner: [.read, .write], group: [.read], others: [.read])

}
