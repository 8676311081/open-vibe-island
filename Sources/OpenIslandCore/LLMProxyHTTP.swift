import Foundation

/// Minimal HTTP/1.1 parsing primitives for the local LLM proxy.
///
/// Scope is narrow: parse a request line + headers + body (Content-Length
/// or chunked) on the inbound socket, and write a response status line +
/// headers on the outbound socket. The proxy never re-encodes the response
/// body — bytes flow straight through from URLSession to NWConnection.
///
/// We deliberately do NOT impose an upper bound on inbound body size; long
/// Claude Code prompts run several MB and that is normal traffic.

public enum LLMProxyHTTP {
    /// Hop-by-hop headers per RFC 7230 §6.1. These describe the single TCP
    /// hop and must not be forwarded to upstream / downstream peers.
    public static let hopByHopHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]

    public struct RequestHead: Sendable {
        public let method: String
        public let path: String
        public let httpVersion: String
        public let headers: [(name: String, value: String)]
        public let lowercasedHeaders: [String: String]

        public init(
            method: String,
            path: String,
            httpVersion: String,
            headers: [(name: String, value: String)]
        ) {
            self.method = method
            self.path = path
            self.httpVersion = httpVersion
            self.headers = headers
            var lower: [String: String] = [:]
            for (name, value) in headers {
                lower[name.lowercased()] = value
            }
            self.lowercasedHeaders = lower
        }

        public func header(_ name: String) -> String? {
            lowercasedHeaders[name.lowercased()]
        }

        public var contentLength: Int? {
            header("content-length").flatMap { Int($0) }
        }

        public var isChunked: Bool {
            header("transfer-encoding")?
                .lowercased()
                .split(separator: ",")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "chunked" }) ?? false
        }
    }

    public enum ParseError: Error, Sendable {
        case malformedRequestLine
        case malformedHeader
        case nonUTF8Header
    }

    /// Parse the request head out of a buffer that already contains a full
    /// `\r\n\r\n` header terminator. The caller is responsible for finding
    /// that terminator and slicing the head bytes.
    public static func parseRequestHead(_ headerBytes: Data) throws -> RequestHead {
        guard let text = String(data: headerBytes, encoding: .utf8) else {
            throw ParseError.nonUTF8Header
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw ParseError.malformedRequestLine
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw ParseError.malformedRequestLine
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let httpVersion = String(parts[2])

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError.malformedHeader
            }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name: name, value: value))
        }
        return RequestHead(method: method, path: path, httpVersion: httpVersion, headers: headers)
    }

    /// Try to decode a complete chunked body out of `data`, starting at
    /// offset 0. Chunked grammar (RFC 7230 §4.1):
    ///     chunk          = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
    ///     last-chunk     = 1*("0") [ chunk-ext ] CRLF
    ///     trailer-part   = *( header-field CRLF )
    ///     chunked-body   = *chunk last-chunk trailer-part CRLF
    ///
    /// We don't honor trailers (none of the LLM APIs send them) but we do
    /// skip past their CRLF correctly so we don't leave junk in the stream.
    public enum ChunkedResult: Sendable {
        case needMore
        case complete(body: Data, bytesConsumed: Int)
        case malformed
    }

    public static func decodeChunkedBody(_ data: Data) -> ChunkedResult {
        var cursor = 0
        var body = Data()
        while true {
            guard let lineEnd = findCRLF(in: data, from: cursor) else {
                return .needMore
            }
            let sizeLineBytes = data.subdata(in: cursor..<lineEnd)
            guard let sizeLine = String(data: sizeLineBytes, encoding: .ascii) else {
                return .malformed
            }
            // Strip chunk extensions after ';'.
            let hex = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(hex, radix: 16) else {
                return .malformed
            }
            cursor = lineEnd + 2 // past CRLF after size line

            if size == 0 {
                // Skip trailers until terminating CRLF (empty line).
                while true {
                    guard let trailerLineEnd = findCRLF(in: data, from: cursor) else {
                        return .needMore
                    }
                    let isEmpty = trailerLineEnd == cursor
                    cursor = trailerLineEnd + 2
                    if isEmpty {
                        return .complete(body: body, bytesConsumed: cursor)
                    }
                }
            }

            // Need `size` chunk bytes followed by CRLF.
            let needed = cursor + size + 2
            if data.count < needed {
                return .needMore
            }
            body.append(data.subdata(in: cursor..<(cursor + size)))
            cursor += size
            // Validate trailing CRLF.
            if data[cursor] != 0x0D || data[cursor + 1] != 0x0A {
                return .malformed
            }
            cursor += 2
        }
    }

    /// Locate the next CRLF in `data` starting at `from`. Returns the index
    /// of the CR byte, or nil if not yet present.
    public static func findCRLF(in data: Data, from start: Int) -> Int? {
        guard start <= data.count else { return nil }
        var i = start
        while i + 1 < data.count {
            if data[i] == 0x0D && data[i + 1] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Locate the end of the header block (`\r\n\r\n`).
    public static func findHeaderTerminator(in data: Data) -> Int? {
        let needle = Data([0x0D, 0x0A, 0x0D, 0x0A])
        return data.range(of: needle)?.lowerBound
    }

    /// Build an outbound HTTP/1.1 status line + headers block. The proxy
    /// always uses Connection: close framing on the client-facing socket;
    /// keep-alive adds reuse complexity for no measurable win locally.
    public static func formatResponseHeader(
        statusCode: Int,
        reasonPhrase: String,
        headers: [(name: String, value: String)]
    ) -> Data {
        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        var sawConnection = false
        for (name, value) in headers {
            let lower = name.lowercased()
            if Self.hopByHopHeaders.contains(lower) { continue }
            // Strip Content-Length too: we use connection-close framing and
            // upstream's Content-Length may have been computed before any
            // (hypothetical) body rewrite. Keep it simple — close is enough.
            if lower == "content-length" { continue }
            if lower == "connection" {
                sawConnection = true
                continue
            }
            lines.append("\(name): \(value)")
        }
        if !sawConnection {
            lines.append("Connection: close")
        } else {
            lines.append("Connection: close")
        }
        let block = lines.joined(separator: "\r\n") + "\r\n\r\n"
        return Data(block.utf8)
    }
}
