import Foundation

extension SignInWaitCopy {
    /// The waiting line of a company vendor's browser sign-in: the chain's
    /// step on the Companies card (C1) and the wizard's check (C2).
    package init(vendor: CompanyVendor) {
        self = switch vendor {
        case .slack: .slack
        case .google: .google
        case .atlassian: .atlassian
        case .linear: .linear
        case .microsoft: .microsoft
        }
    }
}
