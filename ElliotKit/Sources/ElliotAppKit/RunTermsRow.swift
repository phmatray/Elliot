import ElliotModel
import SwiftUI

/// The handle `permissionMode` and `extraAllowedTools` never had.
///
/// Preflight already carries the other two brakes on what a drag costs — *Runs
/// at once* and *Spending*. This is the third, and the only one that bounds what
/// a run may **do** rather than how much of it there may be: until #333 a drag
/// in any registered repository started `claude -p` at `bypassPermissions`
/// inside a real checkout, accepting every tool call and asking nobody, and the
/// column that was supposed to allow tightening one repository had no writer.
///
/// Collapsed by default. A repository nobody has retuned costs one summary line,
/// on a screen that is already long.
struct RunTermsRow: View {
    let repo: Repo
    @Environment(AppModel.self) private var model

    /// Expansion and the half-typed pattern are the only local state here.
    ///
    /// ⚠️ Preflight is a console face, so folding the console destroys this view
    /// and takes `draft` with it. That is a real loss and it is bounded on
    /// purpose: **Add** writes through to the store immediately, so the only
    /// thing a fold can discard is a pattern that was never added. Anything the
    /// reader has *committed* lives in `model.repos`. The analysis panel had to
    /// move four values onto `AppModel` for this reason; one text field being
    /// re-typed is a different size of problem from eight lenses, a limit and a
    /// set of instructions.
    @State private var expanded = false
    @State private var draft = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                mode
                tools
                Text(
                    "Applies to runs started after it. A run already going keeps the terms "
                        + "it started with."
                )
                .font(Type.prose)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                ConsoleLabel(text: "Run terms")
                Fact(text: RunTermsSummary.line(repo), tint: Palette.quiet, small: true)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Run terms for \(repo.displayName): \(RunTermsSummary.line(repo))")
        }
    }

    // MARK: - Mode

    /// Read-through, with no local `@State` mirror — `PreflightView.makeBinding`
    /// makes the argument two controls over: a mirror lets the screen and the
    /// store disagree the moment a save fails. A failed save snaps the picker
    /// back, which is the honest rendering.
    private var mode: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Permission mode", selection: Binding(
                get: { repo.permissionMode },
                set: { new in Task { await model.setRunTerms(repo, .mode(new)) } }
            )) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Permission mode for \(repo.displayName)")

            Text(repo.permissionMode.explanation)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Every case is offered, including `plan`, and the one whose
            // consequence is a *silent* one says so where the choice is made.
            // Withholding the case would be the worse answer: a mode the CLI
            // accepts and this screen hides is a knob you reach by editing the
            // database, which is where this whole issue started.
            if let caveat = repo.permissionMode.caveat {
                Label(caveat.sentence, systemImage: "exclamationmark.triangle")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Extra allowed tools

    /// ⛔ Deliberately **not** `LabelChips`, whose own doc comment argues that
    /// its values are chosen from the repository's list rather than typed
    /// *because a typo would become a label the repository does not have*. There
    /// is no authoritative list of tool patterns to choose from, so these are
    /// typed and that argument is false at this site. Reusing the view would
    /// import a justification that does not hold here.
    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConsoleLabel(text: "Extra allowed tools")
            Text(
                "Passed to `claude --allowedTools`. Elliot does not check these against "
                    + "Claude Code's grammar — it does not own it, and a wrong check would "
                    + "refuse a legal pattern."
            )
            .font(Type.prose)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if repo.extraAllowedTools.isEmpty {
                // Not an empty space: "allows nothing extra" and "this screen
                // could not tell you" must not render the same.
                Fact(text: "None", tint: Palette.quiet, small: true)
            } else {
                ChipRow(patterns: repo.extraAllowedTools) { pattern in
                    Task {
                        await model.setRunTerms(
                            repo, .tools(repo.extraAllowedTools.filter { $0 != pattern })
                        )
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Bash(git status *)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(Type.fact)
                    .frame(maxWidth: 320)
                    .onSubmit { add() }
                    .accessibilityLabel("Add an allowed tool to \(repo.displayName)")
                Button("Add", action: add)
                    // No `.keyboardShortcut(.defaultAction)`. `DefaultAction`
                    // lists the three sanctioned claimants and this is not one
                    // of them; `.onSubmit` covers the field itself without
                    // contesting Return with anything else on screen.
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
    }

    private func add() {
        let pattern = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        draft = ""
        Task { await model.setRunTerms(repo, .tools(repo.extraAllowedTools + [pattern])) }
    }
}

/// One pattern, with the button that removes it.
private struct ChipRow: View {
    let patterns: [String]
    let remove: (String) -> Void

    var body: some View {
        // `WrapLayout` is not available here, so a horizontal scroll rather
        // than a clipped row: a pattern the reader cannot see is a pattern they
        // cannot remove.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(patterns, id: \.self) { pattern in
                    HStack(spacing: 4) {
                        Text(pattern).font(Type.factSmall)
                        Button {
                            remove(pattern)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Remove \(pattern)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Surface.well)
                    .clipShape(Capsule())
                }
            }
            .padding(.vertical, 1)
        }
    }
}
