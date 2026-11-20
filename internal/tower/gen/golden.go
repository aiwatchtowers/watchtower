package main

import (
	"fmt"
	"reflect"
	"sort"
	"strings"

	"watchtower/internal/tower"
)

// goldenTypes are the types that need a golden file in
// internal/tower/api/testdata: the envelope and every command's request and
// response that has fields, sorted by name.
func goldenTypes(r *tower.Registry) []reflect.Type {
	seen := map[reflect.Type]bool{}
	var out []reflect.Type
	for _, t := range roots(r) {
		if seen[t] || t.NumField() == 0 {
			continue
		}
		seen[t] = true
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out
}

// goldenTests renders the Swift test that round-trips every golden file
// through its generated type. enum is the type testUnknownEnumValueSurvives
// uses ("" leaves that test out).
func goldenTests(types []reflect.Type, enum string) []byte {
	var b strings.Builder
	b.WriteString(header + `

import Foundation
import WatchtowerInterface
import XCTest

/// Decodes each golden file in internal/tower/api/testdata into its generated
/// type and checks that re-encoding it gives the same canonical JSON, so one
/// fixture set proves the Go and the Swift side.
final class GoldenRoundTripTests: XCTestCase {
    /// …/internal/tower/api/testdata, from
    /// …/WatchtowerInterface/Tests/WatchtowerInterfaceTests/Generated/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Generated
        .deletingLastPathComponent()  // …/WatchtowerInterfaceTests
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerInterface
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/tower/api/testdata")
`)
	for _, t := range types {
		fmt.Fprintf(&b, `
    func test%[1]sRoundTrip() throws {
        try assertRoundTrip(%[1]s.self, golden: %[1]q)
    }
`, t.Name())
	}
	if enum != "" {
		fmt.Fprintf(&b, `
    func testUnknownEnumValueSurvives() throws {
        let decoded = try JSONDecoder().decode(%s.self, from: Data(#""zz_future""#.utf8))
        XCTAssertEqual(decoded, .unknown("zz_future"))
        XCTAssertEqual(try JSONEncoder().encode(decoded), Data(#""zz_future""#.utf8))
    }
`, enum)
	}
	b.WriteString(`
    private func assertRoundTrip<T: Codable>(_ type: T.Type, golden name: String) throws {
        let file = try Data(contentsOf: Self.testdata.appendingPathComponent(name + ".json"))
        let value = try JSONDecoder().decode(type, from: file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try Self.canonical(encoder.encode(value)), try Self.canonical(file), name)
    }

    /// Sorted keys, no null members: Go writes a nil pointer as null and
    /// Swift leaves a nil optional out, and both read either as absent.
    private static func canonical(_ data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let out = try JSONSerialization.data(
            withJSONObject: dropNulls(object),
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        return String(bytes: out, encoding: .utf8)
    }

    private static func dropNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.mapValues(dropNulls)
        }
        if let array = value as? [Any] {
            return array.map(dropNulls)
        }
        return value
    }
}
`)
	return []byte(b.String())
}
