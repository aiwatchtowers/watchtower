import Foundation

extension AppState {
    /// Cancel on a company card's waiting sign-in (#2132 C1): the hidden
    /// chain's **Stop**, then a refresh-only re-read of the companies and the
    /// accounts lists — a vendor killed while Go saved shows what landed. No
    /// daemon restart here; the chain's own end does what it always does.
    func cancelCompanyCardSignIn() {
        guard let flow = companyConnect, flow.currentVendor != nil else { return }
        flow.stop()
        refreshConnectionAccounts()
    }
}
