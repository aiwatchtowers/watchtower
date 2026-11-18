import SwiftUI
import WatchtowerCore

/// The merge confirmation and its refusal (#2003, spec §6.13), over the
/// Workbenches tab: offered by Put on the Bench… and a suggestion card's
/// Merge Benches… when the folder is on another bench.
extension View {
    func benchMergeDialogs(vm: WorkbenchesViewModel) -> some View {
        modifier(BenchMergeDialogs(vm: vm))
    }
}

private struct BenchMergeDialogs: ViewModifier {
    typealias Copy = BenchMergePresentation

    let vm: WorkbenchesViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                vm.mergeOffer?.title ?? "",
                isPresented: Binding(get: { vm.mergeOffer != nil }, set: { if !$0 { vm.cancelMerge() } }),
                presenting: vm.mergeOffer
            ) { _ in
                Button(Copy.cancel, role: .cancel) { vm.cancelMerge() }
                Button(Copy.merge) { Task { await vm.confirmMerge() } }
                    .keyboardShortcut(.defaultAction)
            } message: { offer in
                Text(offer.text)
            }
            .alert(
                vm.mergeRefusal?.title ?? "",
                isPresented: Binding(get: { vm.mergeRefusal != nil }, set: { if !$0 { vm.dismissMergeRefusal() } }),
                presenting: vm.mergeRefusal
            ) { _ in
                Button(Copy.ok) { vm.dismissMergeRefusal() }
            } message: { refusal in
                Text(refusal.text)
            }
    }
}
