// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// A byte stream read by lines and by counts, over `URLSessionStreamTask`.
///
/// `.tls` is encrypted from the first byte, `.startTLS` is plain until `startTLS()`, and
/// `.plainLoopbackOnly` is refused for any host but this computer.
public actor LineConnection {
    private static let chunk = 64 * 1024

    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: Duration
    private var buffer: [UInt8] = []
    private var start = 0
    /// Bumped by every consume, so a read that waited can tell another read ran meanwhile.
    private var consumptions = 0
    private var isClosed = false

    private init(endpoint: ServerEndpoint, timeout: Duration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.seconds(timeout)
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: endpoint.host, port: Int(endpoint.port))
        self.timeout = timeout
        task.resume()
    }

    deinit {
        task.cancel()
        session.invalidateAndCancel()
    }

    public static func open(
        _ endpoint: ServerEndpoint,
        timeout: Duration = .seconds(30)
    ) async throws(NetError) -> LineConnection {
        if endpoint.security == .plainLoopbackOnly, !endpoint.isLoopback {
            throw .plainRefused
        }
        guard endpoint.port != 0, !endpoint.host.isEmpty else {
            throw .io("no host or port")
        }
        let connection = LineConnection(endpoint: endpoint, timeout: timeout)
        if endpoint.security == .tls {
            try await connection.startTLS()
        }
        return connection
    }

    /// One line without its CR LF (a bare LF also ends a line). Throws `.lineTooLong` when
    /// `maxBytes` arrive without an end of line.
    public func readLine(maxBytes: Int = 1 << 20) async throws(NetError) -> Data {
        try await readLine(maxBytes: maxBytes, timeout: timeout, deadline: nil)
    }

    /// As `readLine(maxBytes:)`, waiting at most `timeout` for each piece to arrive.
    public func readLine(maxBytes: Int = 1 << 20, timeout: Duration) async throws(NetError) -> Data {
        try await readLine(maxBytes: maxBytes, timeout: timeout, deadline: nil)
    }

    /// As `readLine(maxBytes:)`, and `.timeout` when the whole line has not arrived by
    /// `deadline`: a server that drips bytes cannot hold the line open for ever.
    public func readLine(maxBytes: Int = 1 << 20, deadline: ContinuousClock.Instant) async throws(NetError) -> Data {
        try await readLine(maxBytes: maxBytes, timeout: timeout, deadline: deadline)
    }

    /// As `readLine(maxBytes:deadline:)`, waiting at most `timeout` for each piece.
    public func readLine(
        maxBytes: Int = 1 << 20,
        timeout: Duration,
        deadline: ContinuousClock.Instant?
    ) async throws(NetError) -> Data {
        var scanned = start
        while true {
            if let end = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
                var lineEnd = end
                if lineEnd > start, buffer[lineEnd - 1] == UInt8(ascii: "\r") {
                    lineEnd -= 1
                }
                guard lineEnd - start <= maxBytes else {
                    throw .lineTooLong
                }
                let line = Data(buffer[start..<lineEnd])
                consume(upTo: end + 1)
                return line
            }
            scanned = buffer.count
            guard buffer.count - start <= maxBytes.saturatingAdding(1) else {
                throw .lineTooLong
            }
            let mark = consumptions
            try await fill(timeout: timeout, deadline: deadline)
            // Another read may have run while this one waited (the actor is reentrant at each
            // await) and consumed or moved the buffer: the scan starts over.
            if consumptions != mark {
                scanned = start
            }
        }
    }

    /// Exactly `count` bytes. The caller bounds `count`.
    public func read(exactly count: Int) async throws(NetError) -> Data {
        try await read(exactly: count, deadline: nil)
    }

    /// Exactly `count` bytes, and `.timeout` when they have not all arrived by `deadline`.
    public func read(exactly count: Int, deadline: ContinuousClock.Instant?) async throws(NetError) -> Data {
        guard count >= 0 else {
            throw .io("negative length")
        }
        var out = Data()
        while out.count < count {
            if start == buffer.count {
                try await fill(timeout: timeout, deadline: deadline)
            }
            let take = min(count - out.count, buffer.count - start)
            out.append(contentsOf: buffer[start..<(start + take)])
            consume(upTo: start + take)
        }
        return out
    }

    /// Sends `data` in 64 KiB pieces, each with the connection's timeout.
    public func write(_ data: Data) async throws(NetError) {
        guard !isClosed else {
            throw .closed
        }
        // In pieces, each with its own timeout, so a large message is not held to one timeout.
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(Self.chunk, data.endIndex - offset))
            do {
                let task = task
                let piece = data.subdata(in: offset..<end)
                let seconds = Self.seconds(timeout)
                try await StreamWrite.once { answer in
                    task.write(piece, timeout: seconds, completionHandler: answer)
                }
            } catch {
                throw Self.translate(error)
            }
            offset = end
        }
    }

    /// Switches the connection to TLS. Refused when the server has sent anything that has not
    /// been read: bytes that arrived before the handshake must never be read as if after it.
    public func startTLS() async throws(NetError) {
        guard !isClosed else {
            throw .closed
        }
        guard start == buffer.count else {
            throw .io("data arrived before TLS")
        }
        task.startSecureConnection()
    }

    public func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        task.cancel()
        session.invalidateAndCancel()
    }

    private func fill(timeout: Duration, deadline: ContinuousClock.Instant?) async throws(NetError) {
        guard !isClosed else {
            throw .closed
        }
        var wait = timeout
        if let deadline {
            let left = deadline - .now
            guard left > .zero else {
                throw .timeout
            }
            wait = min(wait, left)
        }
        let result: (Data?, Bool)
        do {
            let task = task
            let seconds = Self.seconds(wait)
            result = try await StreamRead.once { answer in
                task.readData(ofMinLength: 1, maxLength: Self.chunk, timeout: seconds, completionHandler: answer)
            }
        } catch {
            throw Self.translate(error)
        }
        if let data = result.0, !data.isEmpty {
            buffer.append(contentsOf: data)
        } else if result.1 {
            throw .closed
        }
    }

    private func consume(upTo index: Int) {
        consumptions &+= 1
        start = index
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > Self.chunk {
            buffer.removeSubrange(0..<start)
            start = 0
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    private static func translate(_ error: any Error) -> NetError {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, URLError.timedOut.rawValue), (NSPOSIXErrorDomain, Int(ETIMEDOUT)):
            return .timeout
        case (NSURLErrorDomain, URLError.networkConnectionLost.rawValue), (NSPOSIXErrorDomain, Int(ECONNRESET)),
             (NSPOSIXErrorDomain, Int(EPIPE)):
            return .closed
        default:
            return .io("\(error.domain) \(error.code)")
        }
    }
}

extension Int {
    func saturatingAdding(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
