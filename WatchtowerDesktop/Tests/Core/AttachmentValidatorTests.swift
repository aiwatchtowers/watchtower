import XCTest
@testable import WatchtowerCore

final class AttachmentValidatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    static let pdf = Data("%PDF-1.4\n%fake\n".utf8)
    static let webp = Data("RIFF\0\0\0\0WEBPVP8 ".utf8)
    static let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func sparse(_ name: String, head: Data, size: Int64) throws -> URL {
        let url = try file(name, head)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    func testImagesPdfAndText() throws {
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.png", Self.png)).get(), .image(mime: "image/png"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.webp", Self.webp)).get(), .image(mime: "image/webp"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("a.pdf", Self.pdf)).get(), .pdf)
        XCTAssertEqual(try AttachmentValidator.validate(url: file("n.md", Data("# План".utf8))).get(), .text(mime: "text/markdown"))
        XCTAssertEqual(try AttachmentValidator.validate(url: file("main.go", Data("package main".utf8))).get(), .text(mime: "text/plain"))
    }

    func testMagicBytesBeatExtension() throws {
        XCTAssertEqual(try AttachmentValidator.validate(url: file("shot.txt", Self.png)).get(), .image(mime: "image/png"))
        XCTAssertEqual(AttachmentValidator.validate(url: try file("fake.png", Self.zip)),
                       .failure(.unsupportedType(fileName: "fake.png")))
    }

    func testRejections() throws {
        XCTAssertEqual(AttachmentValidator.validate(url: try file("a.zip", Self.zip)), .failure(.unsupportedType(fileName: "a.zip")))
        XCTAssertEqual(AttachmentValidator.validate(url: try sparse("big.png", head: Self.png, size: AttachmentValidator.imageLimit + 1)),
                       .failure(.tooLarge(fileName: "big.png", limit: AttachmentValidator.imageLimit)))
        XCTAssertEqual(AttachmentValidator.validate(url: try sparse("big.log", head: Data("x".utf8), size: AttachmentValidator.textLimit + 1)),
                       .failure(.tooLarge(fileName: "big.log", limit: AttachmentValidator.textLimit)))
        XCTAssertEqual(AttachmentValidator.validate(url: try file("bin.txt", Data([0xFF, 0xFE, 0x00, 0x81]))),
                       .failure(.notUTF8(fileName: "bin.txt")))
        XCTAssertEqual(AttachmentValidator.validate(url: dir.appendingPathComponent("gone.png")),
                       .failure(.unreadable(fileName: "gone.png")))
        XCTAssertEqual(AttachmentValidator.validate(url: dir), .failure(.unreadable(fileName: dir.lastPathComponent)))
    }

    func testValidateDataForPaste() {
        XCTAssertEqual(try AttachmentValidator.validate(data: Self.png, fileName: "Pasted image.png").get(), .image(mime: "image/png"))
        XCTAssertEqual(AttachmentValidator.validate(data: Self.zip, fileName: "x.bin"), .failure(.unsupportedType(fileName: "x.bin")))
    }

    func testRejectionMessagesNameTheFile() {
        XCTAssertTrue(AttachmentRejection.tooLarge(fileName: "big.png", limit: AttachmentValidator.imageLimit).message.contains("big.png"))
        XCTAssertTrue(AttachmentRejection.unsupportedType(fileName: "a.zip").message.contains("a.zip"))
    }

    /// Mirrors Go internal/chat MaxImageBytes/MaxPDFBytes/MaxTextBytes
    /// (TestAttachmentLimits_MirrorSwift) — change both sides together.
    func testLimitsMirrorGo() {
        XCTAssertEqual(AttachmentValidator.imageLimit, 5 * 1024 * 1024)
        XCTAssertEqual(AttachmentValidator.pdfLimit, 32 * 1024 * 1024)
        XCTAssertEqual(AttachmentValidator.textLimit, 256 * 1024)
    }

    /// Cross-check with Go `isTextMime` (`internal/chat/attachments.go`):
    /// `strings.HasPrefix(m, "text/") || attachmentTextMimes[m]` where
    /// `attachmentTextMimes` = {application/json, application/yaml,
    /// application/x-yaml, application/xml, application/toml}. Every
    /// extension Swift accepts as text-like must map to a mime Go also
    /// treats as text — this is what keeps the two sides from disagreeing on
    /// what a "text file" is (controller cross-check for Task 21).
    func testTextMimesAllPassGoIsTextMime() {
        func goIsTextMime(_ mime: String) -> Bool {
            let base = mime.split(separator: ";").first.map(String.init) ?? mime
            let attachmentTextMimes: Set<String> = [
                "application/json", "application/yaml", "application/x-yaml", "application/xml", "application/toml"
            ]
            return base.hasPrefix("text/") || attachmentTextMimes.contains(base)
        }
        for ext in AttachmentValidator.textExtensions {
            let mime = AttachmentValidator.textMime(ext)
            XCTAssertTrue(goIsTextMime(mime), "extension .\(ext) maps to \(mime), which Go's isTextMime rejects")
        }
    }

    /// A handful of source-code extensions (never `application/x-*`, which
    /// Go's isTextMime would reject) — the controller's named concrete cases.
    func testSourceExtensionsMapToPlainText() {
        for ext in ["sh", "js", "swift", "go", "py", "rb", "rs"] {
            XCTAssertEqual(AttachmentValidator.textMime(ext), "text/plain")
        }
    }

    /// Review finding (task-21 round 1): the old checks accepted a strict
    /// SUBSET of Go's `net/http` sniff signatures (PNG's 4-byte prefix, GIF's
    /// 4-byte prefix, WEBP without the "VP" sub-chunk tag) — a file matching
    /// only the short prefix would be accepted here but rejected by Go's
    /// `classifyAttachment` (`http.DetectContentType`) at send time. None of
    /// these carry a recognized text extension, so a real signature mismatch
    /// must fall through to unsupportedType, not a text guess.
    func testShortMagicPrefixesAreRejected() {
        // PNG's old 4-byte prefix, missing the CRLF/SUB/LF trailer Go's exact 8-byte signature requires.
        XCTAssertEqual(AttachmentValidator.validate(data: Data([0x89, 0x50, 0x4E, 0x47]), fileName: "a.bin"),
                       .failure(.unsupportedType(fileName: "a.bin")))
        // GIF's old 4-byte prefix, missing the "87a"/"89a" version bytes Go's exact 6-byte signatures require.
        XCTAssertEqual(AttachmentValidator.validate(data: Data("GIF8".utf8), fileName: "a.bin"),
                       .failure(.unsupportedType(fileName: "a.bin")))
        // WEBP's old check (RIFF + "WEBP" at offset 8), missing the "VP" sub-chunk fourCC bytes Go's masked signature requires at offset 12-13.
        XCTAssertEqual(AttachmentValidator.validate(data: Data("RIFF\0\0\0\0WEBPxx".utf8), fileName: "a.bin"),
                       .failure(.unsupportedType(fileName: "a.bin")))
    }

    /// The tightened signatures still accept every real-world fixture already
    /// exercised elsewhere in this file (full PNG/GIF/WEBP signatures).
    func testFullMagicSignaturesStillAccepted() throws {
        XCTAssertEqual(try AttachmentValidator.validate(data: Data("GIF89a".utf8), fileName: "a.bin").get(), .image(mime: "image/gif"))
        XCTAssertEqual(try AttachmentValidator.validate(data: Data("GIF87a".utf8), fileName: "a.bin").get(), .image(mime: "image/gif"))
        XCTAssertEqual(try AttachmentValidator.validate(data: Self.webp, fileName: "a.bin").get(), .image(mime: "image/webp"))
    }
}
