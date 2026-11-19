import Foundation
import WatchtowerInterface
import XCTest

final class RawJSONTests: XCTestCase {
    private struct Holder: Codable, Equatable {
        var raw: RawJSON
    }

    func testEveryJSONKindRoundTripsCanonically() throws {
        let text = #"{"z":[1,-2,0.5,9007199254740993],"a":{"t":true,"f":false,"n":null,"s":"x/y"}}"#
        let raw = try RawJSON(data: Data(text.utf8))
        let canonical = #"{"a":{"f":false,"n":null,"s":"x/y","t":true},"z":[1,-2,0.5,9007199254740993]}"#
        XCTAssertEqual(String(bytes: raw.data, encoding: .utf8), canonical)

        let holder = try JSONDecoder().decode(Holder.self, from: Data(#"{"raw":\#(text)}"#.utf8))
        XCTAssertEqual(holder.raw, raw)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(bytes: try encoder.encode(holder), encoding: .utf8), #"{"raw":\#(canonical)}"#)
    }

    func testBooleansStayBooleansAndNumbersStayNumbers() throws {
        let raw = try RawJSON(data: Data("[true,1,0,false]".utf8))
        XCTAssertEqual(String(bytes: raw.data, encoding: .utf8), "[true,1,0,false]")
    }

    func testScalarTopLevelValues() throws {
        for text in [#""s""#, "null", "3", "true"] {
            XCTAssertEqual(String(bytes: try RawJSON(data: Data(text.utf8)).data, encoding: .utf8), text)
        }
    }

    func testNotJSONThrows() {
        XCTAssertThrowsError(try RawJSON(data: Data("{oops".utf8)))
    }
}
