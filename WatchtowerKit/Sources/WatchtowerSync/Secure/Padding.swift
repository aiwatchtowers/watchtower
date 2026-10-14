import Foundation

public enum Padding {
    public static let buckets = [256, 1_024, 4_096, 16_384, 65_536]
    private static let step = 65_536

    /// Next bucket, then 64 KiB multiples, clipped to `cap` (D12). nil when `length > cap`.
    public static func paddedLength(_ length: Int, cap: Int) -> Int? {
        guard length <= cap else { return nil }
        let length = max(length, 0)
        let target: Int
        if let bucket = buckets.first(where: { $0 >= length }) {
            target = bucket
        } else {
            target = (length + step - 1) / step * step
        }
        return min(target, cap)
    }
}
