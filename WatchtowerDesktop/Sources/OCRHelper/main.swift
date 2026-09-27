// watchtower-ocr <file> [--pages 0,2,5]
//
// The OCR helper the Go attachment extractor runs on a spooled attachment
// (internal/extract, NewHelperOCR). It reads only the file named on its
// command line and prints {"pages":[{"index":0,"text":"…"}]} on stdout.
// Exit 0 on success, 2 when the file cannot be read (or on usage errors,
// or when its own deadline passes), with a message on stderr.
import Foundation
import OCRKit

SelfDeadline.arm { code in exit(code) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("watchtower-ocr: \(message)\n".utf8))
    exit(2)
}

do {
    let args = try HelperArguments.parse(Array(CommandLine.arguments.dropFirst()))
    let pages = try OCRRecognizer.run(path: args.path, pages: args.pages)
    FileHandle.standardOutput.write(try OCRRecognizer.encode(pages))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
} catch {
    fail("\(error)")
}
