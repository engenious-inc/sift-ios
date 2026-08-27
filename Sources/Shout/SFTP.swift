//
//  SFTP.swift
//  Shout
//
//  Created by Vladislav Alexeev on 6/20/18.
//

import Foundation
import CSSH

/// Manages an SFTP session
public class SFTP {
    
    /// Direct bindings to libssh2_sftp
    private class SFTPHandle {
        
        // Recommended buffer size accordingly to the docs:
        // https://www.libssh2.org/libssh2_sftp_write.html
        fileprivate static let bufferSize = 32768
        
        private let cSession: OpaquePointer
        private let sftpHandle: OpaquePointer
        private var buffer = [Int8](repeating: 0, count: SFTPHandle.bufferSize)
        
        init(cSession: OpaquePointer, sftpSession: OpaquePointer, remotePath: String, flags: Int32, mode: Int32, openType: Int32 = LIBSSH2_SFTP_OPENFILE) throws {
            guard let sftpHandle = libssh2_sftp_open_ex(
                sftpSession,
                remotePath,
                UInt32(remotePath.utf8.count),
                UInt(flags),
                Int(mode),
                openType) else {
                    throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_sftp_open_ex failed")
            }
            self.cSession = cSession
            self.sftpHandle = sftpHandle
        }
        
        func read() -> ReadWriteProcessor.ReadResult {
            let result = libssh2_sftp_read(sftpHandle, &buffer, SFTPHandle.bufferSize)
            return ReadWriteProcessor.processRead(result: result, buffer: &buffer, session: cSession)
        }
        
        func write(_ data: Data) -> ReadWriteProcessor.WriteResult {
            let result: Result<Int, SSHError> = data.withUnsafeBytes {
                guard let unsafePointer = $0.bindMemory(to: Int8.self).baseAddress else {
                    return .failure(SSHError.genericError("SFTP write failed to bind memory"))
                }
                return .success(libssh2_sftp_write(sftpHandle, unsafePointer, data.count))
            }
            switch result {
            case .failure(let error):
                return .error(error)
            case .success(let value):
                return ReadWriteProcessor.processWrite(result: value, session: cSession)
            }
        }
        
        func readDir(_ attrs: inout LIBSSH2_SFTP_ATTRIBUTES) -> ReadWriteProcessor.ReadResult {
            let result = libssh2_sftp_readdir_ex(sftpHandle, &buffer, SFTPHandle.bufferSize, nil, 0, &attrs)
            return ReadWriteProcessor.processRead(result: Int(result), buffer: &buffer, session: cSession)
        }

        deinit {
            libssh2_sftp_close_handle(sftpHandle)
        }
        
    }
    
    private let cSession: OpaquePointer
    private let sftpSession: OpaquePointer
    
    // Retain session to ensure it is not freed before the sftp session is closed
    private let session: Session
        
    init(session: Session, cSession: OpaquePointer) throws {
        guard let sftpSession = libssh2_sftp_init(cSession) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_sftp_init failed")
        }
        self.cSession = cSession
        self.sftpSession = sftpSession
        self.session = session
    }

    /// Download a file from the remote server to the local device
    ///
    /// - Parameters:
    ///   - remotePath: the path to the existing file on the remote server to download
    ///   - localURL: the location on the local device whether the file should be downloaded to
    /// - Throws: SSHError if file can't be created or download fails
    public func download(remotePath: String, localURL: URL, shouldAbort: (() -> Bool)? = nil) throws {
        let sftpHandle = try SFTPHandle(
            cSession: cSession,
            sftpSession: sftpSession,
            remotePath: remotePath,
            flags: LIBSSH2_FXF_READ,
            mode: 0
        )

        guard FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil),
            let fileHandle = try? FileHandle(forWritingTo: localURL) else {
            throw SSHError.genericError("couldn't create file at \(localURL.path)")
        }

        defer { try? fileHandle.close() }

        var dataLeft = true
        while dataLeft {
            if shouldAbort?() == true {
                throw SSHError.genericError("SFTP download of \(remotePath) aborted (run cancelled)")
            }
            switch sftpHandle.read() {
            case .data(let data):
                do {
                    try fileHandle.write(contentsOf: data)
                } catch {
                    throw SSHError.genericError("local write failed at \(localURL.path): \(error)")
                }
            case .done:
                dataLeft = false
            case .eagain:
                break
            case .error(let error):
                throw error
            }
        }
    }
    
    /// Upload a file from the local device to the remote server
    ///
    /// - Parameters:
    ///   - localURL: the path to the existing file on the local device
    ///   - remotePath: the location on the remote server whether the file should be uploaded to
    ///   - permissions: the file permissions to create the new file with; defaults to FilePermissions.default
    /// - Throws: SSHError if local file can't be read or upload fails
    public func upload(localURL: URL, remotePath: String, permissions: FilePermissions = .default,
                       shouldAbort: (() -> Bool)? = nil) throws {
        // Stream in bounded chunks: build archives can be multi-GB, and loading
        // them into memory (or memory-mapping, which SIGBUSes if the file changes
        // mid-upload) is not acceptable.
        guard let fileHandle = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHError.genericError("couldn't open local file for upload: \(localURL.path)")
        }
        defer { try? fileHandle.close() }

        let sftpHandle = try SFTPHandle(
            cSession: cSession,
            sftpSession: sftpSession,
            remotePath: remotePath,
            flags: LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
            mode: LIBSSH2_SFTP_S_IFREG | permissions.rawValue
        )

        while true {
            // Checked between chunks so a cancelled run releases the serial SSH
            // queue within one write instead of after a multi-GB transfer.
            if shouldAbort?() == true {
                throw SSHError.genericError("SFTP upload to \(remotePath) aborted (run cancelled)")
            }
            guard let chunk = try fileHandle.read(upToCount: 512 * 1024), !chunk.isEmpty else { break }
            var offset = 0
            var zeroProgressCount = 0
            while offset < chunk.count {
                let upTo = Swift.min(offset + SFTPHandle.bufferSize, chunk.count)
                switch sftpHandle.write(chunk.subdata(in: offset ..< upTo)) {
                case .written(let bytesSent):
                    if bytesSent <= 0 {
                        zeroProgressCount += 1
                        if zeroProgressCount > 1000 {
                            throw SSHError.genericError("SFTP upload to \(remotePath) made no progress")
                        }
                    } else {
                        zeroProgressCount = 0
                        offset += bytesSent
                    }
                case .eagain:
                    continue
                case .error(let error):
                    throw error
                }
            }
        }
    }
    
    /// Upload data to a file on the remote server
    ///
    /// - Parameters:
    ///   - string: String to be uploaded as a file
    ///   - remotePath: the location on the remote server whether the file should be uploaded to
    ///   - permissions: the file permissions to create the new file with; defaults to FilePermissions.default
    /// - Throws: SSHError if string is not valid or upload fails
    public func upload(string: String, remotePath: String, permissions: FilePermissions = .default) throws {
        guard let data = string.data(using: .utf8) else {
            throw SSHError.genericError("Unable to convert string to utf8 data")
        }
        try upload(data: data, remotePath: remotePath, permissions: permissions)
    }
    
    /// Upload data to a file on the remote server
    ///
    /// - Parameters:
    ///   - data: Data to be uploaded as a file
    ///   - remotePath: the location on the remote server whether the file should be uploaded to
    ///   - permissions: the file permissions to create the new file with; defaults to FilePermissions.default
    /// - Throws: SSHError if upload fails
    public func upload(data: Data, remotePath: String, permissions: FilePermissions = .default) throws {
        // TRUNC: overwriting a longer pre-existing file must not leave stale tail bytes.
        let sftpHandle = try SFTPHandle(
            cSession: cSession,
            sftpSession: sftpSession,
            remotePath: remotePath,
            flags: LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
            mode: LIBSSH2_SFTP_S_IFREG | permissions.rawValue
        )

        var offset = 0
        var zeroProgressCount = 0
        while offset < data.count {
            let upTo = Swift.min(offset + SFTPHandle.bufferSize, data.count)
            let subdata = data.subdata(in: offset ..< upTo)
            switch sftpHandle.write(subdata) {
            case .written(let bytesSent):
                if bytesSent <= 0 {
                    zeroProgressCount += 1
                    if zeroProgressCount > 1000 {
                        throw SSHError.genericError("SFTP upload to \(remotePath) made no progress at offset \(offset)")
                    }
                } else {
                    zeroProgressCount = 0
                    offset += bytesSent
                }
            case .eagain:
                continue
            case .error(let error):
                throw error
            }
        }
    }
    
    /// Create a folder on the remote server
    ///
    /// - Parameters:
    ///   - remotePath: the path for the folder, which should be created
    /// - Throws: SSHError if folder can't be created
    public func createDirectory(_ path: String) throws {
        let result = path.withCString { (pointer: UnsafePointer<Int8>) -> Int32 in
            return libssh2_sftp_mkdir_ex(sftpSession, pointer, UInt32(strlen(pointer)), Int(LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH))
        }
        try handleSFTPCommandResult(result)
    }
    
    /// Rename a file on the remote server
    ///
    /// - Parameters:
    ///   - src: the (old) path of the file, which should be renamed
    ///   - dest: the new path of the file
    ///   - override: set to true, if rename should override if there is already a file on dest path
    /// - Throws: SSHError if file can't be renamed
    public func rename(src: String, dest: String, override: Bool) throws {
        var flag: Int = Int(LIBSSH2_SFTP_RENAME_OVERWRITE)
        if !override { flag = 0 }
        
        let result = src.withCString { (srcPointer: UnsafePointer<Int8>) -> Int32 in
            return dest.withCString { (destPointer: UnsafePointer<Int8>) -> Int32 in
                return libssh2_sftp_rename_ex(sftpSession, srcPointer, UInt32(strlen(srcPointer)), destPointer, UInt32(strlen(destPointer)), flag)
            }
        }
        try handleSFTPCommandResult(result)
    }
    
    /// Remove a file on the remote server
    ///
    /// - Parameters:
    ///   - remotePath: the path of the file, which should be removed
    /// - Throws: SSHError if file can't be deleted
    public func removeFile(_ path: String) throws {
        let result = path.withCString { (pointer: UnsafePointer<Int8>) -> Int32 in
            return libssh2_sftp_unlink_ex(sftpSession, pointer, UInt32(strlen(pointer)))
        }
        try handleSFTPCommandResult(result)
    }
    
    /// Remove a folder on the remote server
    ///
    /// - Parameters:
    ///   - remotePath: the path of the folder, which should be removed
    /// - Throws: SSHError if folder can't be deleted
    public func removeDirectory(_ path: String) throws {
        let result = path.withCString { (pointer: UnsafePointer<Int8>) -> Int32 in
            return libssh2_sftp_rmdir_ex(sftpSession, pointer, UInt32(strlen(pointer)))
        }
        try handleSFTPCommandResult(result)
    }
    
    
    
    public func listFiles(in directory: String) throws -> [String : FileAttributes] {
        
        let sftpHandle = try SFTPHandle(
                cSession: cSession,
                sftpSession: sftpSession,
                remotePath: directory,
                flags: LIBSSH2_FXF_READ,
                mode: 0,
                openType: LIBSSH2_SFTP_OPENDIR
        )

        var files = [String : FileAttributes]()
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()

        var dataLeft = true
        while dataLeft {
            switch sftpHandle.readDir(&attrs) {
            case .data(let data):
                guard let name = String(data: data, encoding: .utf8) else {
                    throw SSHError.genericError("unable to convert data to utf8 string")
                }
                files[name] = FileAttributes(attributes: attrs)
            case .done:
                dataLeft = false
            case .eagain:
                break
            case .error(let error):
                throw error
            }
        }
        return files
    }
    
    
    private func handleSFTPCommandResult(_ result: Int32) throws {
        let processedResult = ReadWriteProcessor.processWrite(result: Int(result), session: cSession)
        switch processedResult {
        case .written( _):
            break
        case .eagain:
            // The session is blocking; EAGAIN here means the operation did not
            // complete — surfacing it as success would silently skip mkdir/rm/rename.
            throw SSHError.genericError("SFTP command returned EAGAIN on a blocking session")
        case .error(let error):
            throw error
        }
    }
    
    
    
    deinit {
        libssh2_sftp_shutdown(sftpSession)
    }
    
}
