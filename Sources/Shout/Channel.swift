//
//  Channel.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import CSSH
import struct Foundation.Data
import struct Foundation.URL

/// Direct bindings to libssh2_channel
class Channel {

    private static let session = "session"
    private static let exec = "exec"

    static let windowDefault: UInt32 = 2 * 1024 * 1024
    static let packetDefaultSize: UInt32 = 32768
    static let readBufferSize = 0x4000

    /// Retains the owning Session so the underlying libssh2 session cannot be freed
    /// while a channel that references it is still alive.
    private let session: Session
    private let cSession: OpaquePointer
    private let cChannel: OpaquePointer
    private var readBuffer = [Int8](repeating: 0, count: Channel.readBufferSize)

    static func createForCommand(session: Session, cSession: OpaquePointer) throws -> Channel {
        guard let cChannel = libssh2_channel_open_ex(cSession,
                                                     Channel.session,
                                                     UInt32(Channel.session.utf8.count),
                                                     Channel.windowDefault,
                                                     Channel.packetDefaultSize, nil, 0) else {
            throw SSHError.mostRecentError(session: cSession, backupMessage: "libssh2_channel_open_ex failed")
        }
        return Channel(session: session, cSession: cSession, cChannel: cChannel)
    }

    private init(session: Session, cSession: OpaquePointer, cChannel: OpaquePointer) {
        self.session = session
        self.cSession = cSession
        self.cChannel = cChannel
    }

    func requestPty(type: String) throws {
        let code = libssh2_channel_request_pty_ex(cChannel,
                                                  type, UInt32(type.utf8.count),
                                                  nil, 0,
                                                  LIBSSH2_TERM_WIDTH, LIBSSH2_TERM_HEIGHT,
                                                  LIBSSH2_TERM_WIDTH_PX, LIBSSH2_TERM_HEIGHT_PX)
        try SSHError.check(code: code, session: cSession)
    }

    func exec(command: String) throws {
        // Merge stderr into the stdout stream: with a blocking session, draining
        // two streams sequentially can deadlock when the unread stream's window
        // fills. One merged stream cannot.
        _ = libssh2_channel_handle_extended_data2(cChannel, LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE)
        let code = libssh2_channel_process_startup(cChannel,
                                                   Channel.exec,
                                                   UInt32(Channel.exec.utf8.count),
                                                   command,
                                                   UInt32(command.utf8.count))
        try SSHError.check(code: code, session: cSession)
    }

    /// Reads from one of the channel's streams (0 = stdout, 1 = stderr).
    func readData(stream: Int32 = 0) -> ReadWriteProcessor.ReadResult {
        let result = libssh2_channel_read_ex(cChannel, stream, &readBuffer, Channel.readBufferSize)
        return ReadWriteProcessor.processRead(result: result, buffer: &readBuffer, session: cSession)
    }

    func write(data: Data, length: Int, to stream: Int32 = 0) -> ReadWriteProcessor.WriteResult {
        let result: Result<Int, SSHError> = data.withUnsafeBytes {
            guard let unsafePointer = $0.bindMemory(to: Int8.self).baseAddress else {
                return .failure(SSHError.genericError("Channel write failed to bind memory"))
            }
            return .success(libssh2_channel_write_ex(cChannel, stream, unsafePointer, length))
        }
        switch result {
        case .failure(let error):
            return .error(error)
        case .success(let value):
            return ReadWriteProcessor.processWrite(result: value, session: cSession)
        }
    }

    func sendEOF() throws {
        let code = libssh2_channel_send_eof(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func waitEOF() throws {
        let code = libssh2_channel_wait_eof(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func close() throws {
        let code = libssh2_channel_close(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    func waitClosed() throws {
        let code = libssh2_channel_wait_closed(cChannel)
        try SSHError.check(code: code, session: cSession)
    }

    /// Valid only after close + waitClosed.
    func exitStatus() -> Int32 {
        return libssh2_channel_get_exit_status(cChannel)
    }

    /// The signal that terminated the remote command, if any. A signal-killed command
    /// reports exit status 0 from libssh2, so callers must check this too.
    func exitSignal() -> String? {
        var signal: UnsafeMutablePointer<Int8>? = nil
        var signalLength = 0
        let code = libssh2_channel_get_exit_signal(cChannel, &signal, &signalLength, nil, nil, nil, nil)
        guard code == 0, let signal, signalLength > 0 else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: signal, count: signalLength), encoding: .utf8)
    }

    deinit {
        libssh2_channel_free(cChannel)
    }

}
