import Foundation
import Testing
@testable import OpenIslandCore

/// Targeted parser tests for `LLMProxyHTTP`. Pinned by reviewer A
/// against commit abc09c6 (NWListener-based reverse proxy) — the
/// gaps the original commit shipped without.
struct LLMProxyHTTPTests {
    // MARK: - Request line

    @Test
    func parseRequestHeadRejectsRequestLineMissingHTTPVersion() throws {
        // Two tokens, not three — `GET /v1/messages` with no `HTTP/1.1`.
        let raw = Data("GET /v1/messages\r\nHost: example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    @Test
    func parseRequestHeadRejectsEmptyRequestLine() throws {
        let raw = Data("\r\nHost: example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    @Test
    func parseRequestHeadRejectsMalformedHeaderMissingColon() throws {
        let raw = Data("POST /v1/messages HTTP/1.1\r\nHost example.com\r\n".utf8)
        #expect(throws: LLMProxyHTTP.ParseError.self) {
            _ = try LLMProxyHTTP.parseRequestHead(raw)
        }
    }

    // MARK: - Chunked decoder fuzz

    @Test
    func chunkedBodyMalformedSizeReturnsMalformedNotCrash() {
        // `xyz` is not valid hex — decoder must return .malformed,
        // never trap.
        let raw = Data("xyz\r\nhello\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return  // expected
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    // NOTE: a `chunkedBodyMalformedNegativeSizeReturnsMalformed`
    // test would belong here — but `Int("-5", radix: 16)` succeeds in
    // Swift, the decoder doesn't gate `size >= 0`, and the resulting
    // negative-stride `subdata(in:)` call traps with
    //
    //   Swift/Range.swift:760: Fatal error: Range requires lowerBound <= upperBound
    //
    // That's a real abc09c6 bug, but the fix belongs in commit 1.6
    // (HTTP body cap + chunked fuzz hardening) where we can pair the
    // test with the `guard size >= 0` patch in one atomic change.
    // 1.1 deliberately stops at parser-shape gaps that today's code
    // already handles correctly.

    @Test
    func chunkedBodyMissingTrailingCRLFAfterChunkDataReturnsMalformed() {
        // Size `5`, then `hello`, then garbage where CRLF should be.
        let raw = Data("5\r\nhelloXX0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .malformed:
            return
        default:
            Issue.record("expected .malformed, got \(result)")
        }
    }

    @Test
    func chunkedBodyBoundaryWhereTrailerLineExtendsPastBuffer() {
        // Last-chunk `0\r\n` followed by an *unfinished* trailer
        // header (no terminating CRLF). Decoder must return .needMore,
        // not crash on the bound check inside the trailer-skip loop.
        let raw = Data("0\r\nX-Trailer: incomp".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .needMore:
            return  // expected — caller will re-read more bytes
        default:
            Issue.record("expected .needMore, got \(result)")
        }
    }

    @Test
    func chunkedBodyHappyPathCompletesAndReportsBytesConsumed() {
        // Two chunks then last-chunk + empty trailer.
        let raw = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        guard case let .complete(body, bytesConsumed) = result else {
            Issue.record("expected .complete, got \(result)")
            return
        }
        #expect(body == Data("hello world".utf8))
        #expect(bytesConsumed == raw.count)
    }

    @Test
    func chunkedBodyNeedMoreWhenSizeLineIncomplete() {
        // No CRLF anywhere yet.
        let raw = Data("5".utf8)
        let result = LLMProxyHTTP.decodeChunkedBody(raw)
        switch result {
        case .needMore:
            return
        default:
            Issue.record("expected .needMore, got \(result)")
        }
    }

    // MARK: - Header terminator

    @Test
    func findHeaderTerminatorLocatesDoubleCRLF() {
        let raw = Data("GET / HTTP/1.1\r\nHost: a\r\n\r\nbody".utf8)
        let idx = LLMProxyHTTP.findHeaderTerminator(in: raw)
        #expect(idx == raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))!.lowerBound)
    }

    @Test
    func findHeaderTerminatorReturnsNilOnIncompleteHeaders() {
        let raw = Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)
        #expect(LLMProxyHTTP.findHeaderTerminator(in: raw) == nil)
    }
}
