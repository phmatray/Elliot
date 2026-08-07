import ElliotModel
import SwiftUI

/// The confirmation both screens show, written once.
///
/// `presenting:` rather than a `Binding` into the optional: unwrapping an
/// optional draft with `Binding($x)` is what crashed the card editor on both
/// Cancel and Save (#9), and the shape recurs wherever a sheet reads a value
/// that goes nil as it dismisses. Here the closures are handed the value.
private struct ForgetConfirmationModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.forgetRequest?.prompt.title ?? "",
            isPresented: Binding(
                get: { model.forgetRequest != nil },
                // A dismissal that is not the Forget button is a cancel: tapping
                // outside must leave the board exactly as a cancel does.
                set: { if !$0 { model.cancelForget() } }),
            titleVisibility: .visible,
            presenting: model.forgetRequest
        ) { _ in
            Button(ForgetPrompt.confirmLabel, role: .destructive) {
                Task { await model.confirmForget() }
            }
            Button("Cancel", role: .cancel) { model.cancelForget() }
        } message: { request in
            Text(request.prompt.message)
        }
    }
}

extension View {
    /// Applied by `PreflightView` and `RepositoriesView`. A second copy would be
    /// a second copy of every decision in the modifier above.
    func forgetConfirmation(model: AppModel) -> some View {
        modifier(ForgetConfirmationModifier(model: model))
    }
}
