import XCTest
@testable import HaliteTerminal

/// 한글 출력이 쓰기 경계(PTY read)에서 쪼개져 들어올 때 깨지는지 재현.
/// HaliteSession과 동일하게 parser.didEmitText → grid.putChar(per grapheme) 흐름을 모사.
final class HangulOutputTests: XCTestCase {
    private final class Sink: VTParserDelegate {
        let grid: Grid
        init(_ g: Grid) { grid = g }
        func vtParser(_ parser: VTParser, didEmitText text: String) {
            for ch in text { grid.putChar(ch) }
        }
        func vtParser(_ parser: VTParser, didExecute byte: UInt8) {}
        func vtParser(_ parser: VTParser, didEmitCSI params: [Int], intermediates: [UInt8],
                      finalByte: UInt8, privateMarker: UInt8?) {}
        func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {}
    }

    /// chunk들을 순서대로 feed한 뒤 row0의 글자들을 이어붙여 반환.
    private func render(_ chunks: [[UInt8]]) -> String {
        let grid = Grid(cols: 20, rows: 2, pen: CellAttrs(fg: .default))
        let parser = VTParser()
        let sink = Sink(grid)
        parser.delegate = sink
        for c in chunks { parser.feed(Data(c)) }
        var s = ""
        for col in 0..<20 {
            let cell = grid.cell(row: 0, col: col)
            if cell.isContinuation { continue }
            if cell.char == " " { break }
            s.append(cell.char)
        }
        return s
    }

    // 개 U+AC1C, 선 U+C120, 점 U+C810 (NFC)
    private let nfc: [UInt8] = [0xEA, 0xB0, 0x9C, 0xEC, 0x84, 0xA0, 0xEC, 0xA0, 0x90]
    // NFD: 개=ㄱㅐ, 선=ㅅㅓㄴ, 점=ㅈㅓㅁ
    private let nfd: [UInt8] = [
        0xE1, 0x84, 0x80, 0xE1, 0x85, 0xA2,             // 개
        0xE1, 0x84, 0x89, 0xE1, 0x85, 0xA5, 0xE1, 0x86, 0xAB, // 선
        0xE1, 0x84, 0x8C, 0xE1, 0x85, 0xA5, 0xE1, 0x86, 0xB7, // 점
    ]

    func testNFCWhole() { XCTAssertEqual(render([nfc]), "개선점") }

    func testNFCSplitEveryByte() {
        // 한 바이트씩 쪼개 feed — 부분 UTF-8 재조립 검증.
        XCTAssertEqual(render(nfc.map { [$0] }), "개선점")
    }

    func testNFDWhole() { XCTAssertEqual(render([nfd]), "개선점") }

    func testNFDSplitAtJamo() {
        // "점"의 ㅈㅓ까지 한 chunk, 마지막 ㅁ(U+11B7)을 다음 chunk로 — NFD가 쓰기
        // 경계에서 jamo로 쪼개지는 실제 케이스.
        let head = Array(nfd[0..<(nfd.count - 3)])   // 개선저(ㅈㅓ)까지
        let tail = Array(nfd[(nfd.count - 3)...])     // ㅁ (U+11B7)
        XCTAssertEqual(render([head, tail]), "개선점")
    }

    func testNFDOneJamoPerFeed() {
        // 자모 하나씩(3바이트) 따로 feed.
        var chunks: [[UInt8]] = []
        var i = 0
        while i < nfd.count { chunks.append(Array(nfd[i..<i+3])); i += 3 }
        XCTAssertEqual(render(chunks), "개선점")
    }

    func testNFCSplitMidByteEachChar() {
        // 각 글자를 2+1 바이트로 쪼갬.
        let chunks: [[UInt8]] = [
            [0xEA, 0xB0], [0x9C],   // 개
            [0xEC, 0x84], [0xA0],   // 선
            [0xEC, 0xA0], [0x90],   // 점
        ]
        XCTAssertEqual(render(chunks), "개선점")
    }

    // MARK: wide 문자 부분 덮어쓰기 정리 (TUI 재그리기에서 깨지던 진짜 원인)

    func testOverwriteWideLeadClearsOrphanContinuation() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")                 // col0 lead, col1 continuation
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        g.setCursor(row: 1, col: 1)      // (0,0)
        g.putChar("x")                   // lead 덮어쓰기
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "x")
        XCTAssertFalse(g.cell(row: 0, col: 1).isContinuation, "orphan continuation 제거")
    }

    func testOverwriteWideContinuationClearsOrphanLead() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")
        g.setCursor(row: 1, col: 2)      // (0,1) = continuation
        g.putChar("x")
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "x")
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ", "orphan lead 제거")
    }

    func testWideOverWideClearsTrailingOrphan() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.putChar("점")                 // col0-1
        g.putChar("안")                 // col2-3
        g.setCursor(row: 1, col: 2)      // (0,1) = 점 continuation
        g.putChar("강")                 // wide → col1-2 덮어씀
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ", "점 lead 제거")
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "강")
        XCTAssertTrue(g.cell(row: 0, col: 2).isContinuation)
        XCTAssertFalse(g.cell(row: 0, col: 3).isContinuation, "안 orphan continuation 제거")
    }

    func testNFDPointWithSGRBetweenJamo() {
        // 스트리밍 재렌더가 jamo 사이에 SGR(색) escape를 끼워넣는 경우.
        // 개선 + (ㅈ) ESC[33m (ㅓ) (ㅁ) — 커서 이동 없는 SGR.
        let head = Array(nfd[0..<(nfd.count - 9)])  // 개선까지
        let cho: [UInt8] = [0xE1, 0x84, 0x8C]       // ㅈ
        let sgr: [UInt8] = [0x1B, 0x5B, 0x33, 0x33, 0x6D]  // ESC[33m
        let jung: [UInt8] = [0xE1, 0x85, 0xA5]      // ㅓ
        let jong: [UInt8] = [0xE1, 0x86, 0xB7]      // ㅁ
        XCTAssertEqual(render([head, cho, sgr, jung, jong]), "개선점")
    }
}
