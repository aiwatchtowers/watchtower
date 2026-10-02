/// Russian noun agreement with a count: 1 сессия, 2 сессии, 5 сессий,
/// 11 сессий, 21 сессия.
package enum RussianPlural {
    package static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count) % 100
        if (11...14).contains(n) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}
