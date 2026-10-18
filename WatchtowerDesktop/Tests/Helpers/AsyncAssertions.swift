import XCTest

/// `XCTAssertThrowsError` for an async expression, which an autoclosure
/// cannot await (board #670 made view model writes async).
@MainActor
func assertThrowsAsync<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

/// As above, and the error is `expected`.
@MainActor
func assertThrowsAsync<E: Error & Equatable, T>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}
