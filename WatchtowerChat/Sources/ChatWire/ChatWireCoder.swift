import Foundation

/// The JSON of the chat wire, on chat.sock and in the relay records alike: snake_case keys, Unix-second dates,
/// sorted keys — the settings of the Kit's `RelayCoder` (`ChatWireCoderTests` pins them byte for byte), so one model
/// decodes both.
public enum ChatWireCoder {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
