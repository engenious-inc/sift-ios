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
        let flags = Int32(attributes.flags)
        if flags & LIBSSH2_SFTP_ATTR_PERMISSIONS != 0, attributes.permissions <= UInt(Int32.max) {
            fileType = FileType(rawValue: Int32(attributes.permissions))
            permissions = FilePermissions(rawValue: Int32(attributes.permissions))
        } else {
            fileType = nil
            permissions = nil
        }
        size = flags & LIBSSH2_SFTP_ATTR_SIZE != 0 ? attributes.filesize : nil
        if flags & LIBSSH2_SFTP_ATTR_UIDGID != 0 {
            userId = attributes.uid
            groupId = attributes.gid
        } else {
            userId = nil
            groupId = nil
        }
        if flags & LIBSSH2_SFTP_ATTR_ACMODTIME != 0 {
            lastAccessed = Date(timeIntervalSince1970: Double(attributes.atime))
            lastModified = Date(timeIntervalSince1970: Double(attributes.mtime))
        } else {
            lastAccessed = nil
            lastModified = nil
        }
    }

}

