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

    /// Which screen this copy belongs to. Preflight and Repositories are
    /// separate `Window` scenes over **one** `AppModel`, so an ungated modifier
    /// raises a modal in both whenever either asks — and cancelling the copy
    /// nobody asked for drops the act in the window they were looking at.
    /// `Origin` already records who asked; this is what it is for.
    let origin: AppModel.ForgetRequest.Origin

    private var request: AppModel.ForgetRequest? {
        guard let request = model.forgetRequest, request.origin == origin else { return nil }
        return request
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            request?.prompt.title ?? "",
            isPresented: Binding(
                get: { request != nil },
                // A dismissal that is not the Forget button is a cancel: tapping
                // outside must leave the board exactly as a cancel does. This
                // also runs for the Forget button's own dismissal, which is why
                // `confirmForget` takes the request instead of reading it back.
                set: { if !$0 { model.cancelForget() } }),
            titleVisibility: .visible,
            presenting: request
        ) { request in
            Button(ForgetPrompt.confirmLabel, role: .destructive) {
                Task { await model.confirmForget(request) }
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
    func forgetConfirmation(
        model: AppModel, on origin: AppModel.ForgetRequest.Origin
    ) -> some View {
        modifier(ForgetConfirmationModifier(model: model, origin: origin))
    }
}
