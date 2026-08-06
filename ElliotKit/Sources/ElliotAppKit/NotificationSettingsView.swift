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
/// Writes an encoded `NotificationPreferences` to `UserDefaults`, which is the
/// same value the policy takes as a parameter. That is what makes "a muted
/// category posts nothing" a unit test rather than something you verify by
/// muting a category and waiting an hour for a run to finish.
public struct NotificationSettingsView: View {
    @State private var preferences: NotificationPreferences = .default
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
        .onAppear(perform: load)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.isEnabled },
            set: { preferences.isEnabled = $0; save() }
        )
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { !preferences.muted.contains(category) },
            set: { allowed in
                if allowed { preferences.muted.remove(category) } else { preferences.muted.insert(category) }
                save()
            }
        )
    }

    private func load() {
        guard
            let data = defaults.data(forKey: NotificationPresenter.preferencesKey),
            let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else { return }
        preferences = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: NotificationPresenter.preferencesKey)
    }
}
