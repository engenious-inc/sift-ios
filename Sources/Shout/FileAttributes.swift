//
//  FileAttributes.swift
//  
//
//  Created by Kyle Ishie on 12/10/19.
//

import Foundation
import CSSH

public struct FileAttributes {

    public let fileType: FileType?

    public let size: UInt64?

    public let userId: UInt?

    public let groupId: UInt?

    public let permissions: FilePermissions?

    public let lastAccessed: Date?

    public let lastModified: Date?

    /// Fields are populated only when the server's validity flags say they are
    /// present — an absent field must not masquerade as a real zero value.
    init(attributes: LIBSSH2_SFTP_ATTRIBUTES) {
        // Test the bits on the UNSIGNED value: LIBSSH2_SFTP_ATTR_EXTENDED is
        // 0x80000000, so a spec-legal flag word exceeds Int32.max and a signed
        // narrowing would trap on the first server that sets it.
        let flags = attributes.flags
        func has(_ bit: Int32) -> Bool { flags & UInt(UInt32(bitPattern: bit)) != 0 }
        if has(LIBSSH2_SFTP_ATTR_PERMISSIONS), attributes.permissions <= UInt(Int32.max) {
            fileType = FileType(rawValue: Int32(attributes.permissions))
            permissions = FilePermissions(rawValue: Int32(attributes.permissions))
        } else {
            fileType = nil
            permissions = nil
        }
        size = has(LIBSSH2_SFTP_ATTR_SIZE) ? attributes.filesize : nil
        if has(LIBSSH2_SFTP_ATTR_UIDGID) {
            userId = attributes.uid
            groupId = attributes.gid
        } else {
            userId = nil
            groupId = nil
        }
        if has(LIBSSH2_SFTP_ATTR_ACMODTIME) {
            lastAccessed = Date(timeIntervalSince1970: Double(attributes.atime))
            lastModified = Date(timeIntervalSince1970: Double(attributes.mtime))
        } else {
            lastAccessed = nil
            lastModified = nil
        }
    }

}

