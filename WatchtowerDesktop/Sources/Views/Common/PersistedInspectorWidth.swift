import SwiftUI

/// The last settled width of an `.inspector` column, kept across launches
/// under `key` (#401): usually the width it was dragged to, but also one a
/// narrow window forced on it. SwiftUI's inspector takes only an ideal
/// width, so the stored one is the ideal the column opens at; the live width
/// is stored once it has held still for a moment, which leaves out the
/// frames of the open and close animations.
struct PersistedInspectorWidth: ViewModifier {
    let key: String
    let range: ClosedRange<Double>
    let ideal: Double
    let defaults: UserDefaults
    @State private var openingWidth: Double
    @State private var liveWidth: Double?

    init(key: String, range: ClosedRange<Double>, ideal: Double, defaults: UserDefaults = .standard) {
        self.key = key
        self.range = range
        self.ideal = ideal
        self.defaults = defaults
        _openingWidth = State(initialValue: Self.storedWidth(defaults: defaults, key: key, range: range, ideal: ideal))
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .inspectorColumnWidth(min: range.lowerBound, ideal: openingWidth, max: range.upperBound)
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { liveWidth = $0 }
            .task(id: liveWidth) {
                guard let liveWidth else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                Self.store(liveWidth, key: key, range: range, defaults: defaults)
            }
    }

    /// The width the column opens at: the stored one, clamped into `range`.
    static func storedWidth(defaults: UserDefaults, key: String, range: ClosedRange<Double>, ideal: Double) -> Double {
        let stored = defaults.object(forKey: key) as? Double ?? ideal
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// A measured width worth keeping: nil while the column is narrower than
    /// it can be dragged to (it is opening or closing).
    static func widthToStore(_ width: Double, range: ClosedRange<Double>) -> Double? {
        guard width >= range.lowerBound - 1 else { return nil }
        return min(width.rounded(), range.upperBound)
    }

    /// Keeps a settled width under `key`, if it is one worth keeping.
    static func store(_ width: Double, key: String, range: ClosedRange<Double>, defaults: UserDefaults) {
        guard let width = widthToStore(width, range: range) else { return }
        defaults.set(width, forKey: key)
    }
}

extension View {
    /// `.inspectorColumnWidth(min:ideal:max:)` that remembers the last settled width.
    func persistedInspectorColumnWidth(key: String, range: ClosedRange<Double>, ideal: Double) -> some View {
        modifier(PersistedInspectorWidth(key: key, range: range, ideal: ideal))
    }
}
