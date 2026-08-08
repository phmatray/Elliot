import ElliotModel
import SwiftUI

/// What each category covers, in one sentence.
///
/// Beside the switch rather than in a manual: a switch labelled only "Landed"
/// is a switch people leave alone because they cannot tell what turning it off
/// would cost them.
extension NotificationCategory {
    var settingsTitle: String {
        switch self {
        case .landed: "Landed"
        case .needsYou: "Needs you"
        case .boardMovedItself: "The board moved itself"
        case .analysisReady: "Analysis ready"
        }
    }

    var settingsDetail: String {
        switch self {
        case .landed:
            "A run finished and there is nothing to do — an issue filed, a pull request opened, a merge landed."
        case .needsYou:
            "A run failed, timed out, went quiet, or was refused a tool. The only category that makes a sound."
        case .boardMovedItself:
            "A pull request went ready or was merged on github.com, and Elliot advanced the card."
        case .analysisReady:
            "An analysis finished and its proposals are waiting."
        }
    }
}

/// ⌘, — the master switch and one switch per category.
///
/// Reads and writes `AppModel.notificationPreferences`, which is the same value
/// the policy takes as a parameter. That is what makes "a muted category posts
/// nothing" a unit test rather than something you verify by muting a category
/// and waiting an hour for a run to finish.
///
/// ⚠️ **No `@State` copy, and no `.onAppear` load (#222).** It held both, which
/// cost two things. The copy meant this screen reloaded from storage on every
/// appearance — harmless as a `Settings` scene, lossy the day it becomes
/// something that can be hidden and re-shown. And the storage was
/// `UserDefaults.standard`, keyed by bundle identifier, so a scratch
/// `ELLIOT_HOME` read *and wrote* the operator's real settings.
public struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Notify me about Elliot", isOn: enabledBinding)
                Text(
                    "Elliot notifies about facts it established — never about something you just did."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Categories") {
                ForEach(NotificationCategory.allCases, id: \.self) { category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.settingsTitle)
                            Text(category.settingsDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Off, and greyed, when the master switch is off — the
                    // per-category switches cannot do anything from there, and
                    // showing them live would misdescribe what they control.
                    .disabled(!preferences.isEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var preferences: NotificationPreferences { model.notificationPreferences }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.notificationPreferences.isEnabled },
            set: { model.notificationPreferences.isEnabled = $0 }
        )
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { !model.notificationPreferences.muted.contains(category) },
            set: { allowed in
                // Read, edit, write back through the one setter — never mutate
                // `model.notificationPreferences.muted` in place, which would be
                // two writes and two saves for one switch.
                var updated = model.notificationPreferences
                if allowed { updated.muted.remove(category) } else { updated.muted.insert(category) }
                model.notificationPreferences = updated
            }
        )
    }
}
