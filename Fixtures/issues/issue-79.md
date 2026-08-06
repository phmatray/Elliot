## User story

As Philippe working the board, I want a card's details to open **between the columns** — right next to the card I clicked, tethered to it by a visible line — so that reading an issue or watching a run keeps the card, its column's standing rule, and the columns on either side in one field of view, instead of pushing the detail to the far right edge of the window where nothing connects it to what I selected; and I want what is *inside* that panel to be readable as structure rather than prose — the issue body as components, each run log line as a typed row, and the agent's claim visibly separated from what `gh` established.

## Acceptance criteria

Numbers below are computed from the real formula at `ElliotKit/Sources/ElliotAppKit/BoardView.swift:236-239` — `columnWidth = max(226, (boardWidth − 60) / 5)` — not from the 226 floor, which only binds below a 1190pt window.

1. `cd ElliotKit && swift test` is green, and each new suite reports a non-zero test count when run alone (`swift test --filter IssueMarkdownParserTests`, `--filter RunLogRowTests`, `--filter PanelLayoutTests`, `--filter RunsPaneLiveTests`). A filter matching nothing prints `warning: No matching test cases were run` and exits 0, so the count is the check, not the exit code.
2. With a card selected in Backlog, To Do, In Progress or In Review, the panel is a sibling **immediately after** that card's column, and the columns to its right are pushed rightward and still reachable by scrolling — nothing is clipped, and a horizontal scrollbar is present.
3. With a card selected in **Done** (the last column in board order), the panel opens to Done's **left**, the caret is on the panel's **right** edge, and the tether leaves rightwards.
4. `swift test --filter PanelLayoutTests` pins: `panelWidth(columnWidth: 316, spans: 3) == 968` and `spans: 2 == 642`; `contentWidth(boardWidth:spans:) > boardWidth` at boardWidth ∈ {1000, 1640, 2560} for **both** spans (1898/1662 · 2618/2292 · 4090/3580), so the scroll predicate is false whenever the panel is open at any window size the app allows.
5. At 3 spans the panel shows two panes side by side (issue | runs). Switching to 2 spans (View ▸ Narrow details, ⌘⌥⇧I) shows one pane behind a segmented `Picker` that actually switches, and the hidden pane is **absent from the view tree** — with VoiceOver on, only the visible pane's contents are reachable.
6. The panel's top rail carries the origin column's `railTint`: grey for Backlog and In Review, violet for To Do and In Progress, crimson for Done (`ElliotKit/Sources/ElliotAppKit/Consequence.swift:137-143`).
7. Clicking three different cards in the same column moves the caret to each one in turn — it tracks the card, not the column and not the first card.
8. Scrolling that column until the selected card leaves its viewport: the 2pt tether disappears and the caret drops to about a third opacity. Scrolling it back restores both. The caret never points at where the card used to be. The same detached state shows when the card is scrolled far enough that it is not built at all.
9. The tether visibly **touches** the card: zoom in on the 2pt line and it crosses the column's rounded border and ends on the card's armed border (`ElliotKit/Sources/ElliotAppKit/CardView.swift:87-93`). Check on a Backlog card and on a Done card — the flipped side must not be cut off at the column edge.
10. With a card selected level with the caret, that card can still be clicked and still be dragged to another column: the caret and tether do not intercept the gesture.
11. Selecting a card frames the pair on the **first** click, from a cold launch with nothing selected: the origin column (or the panel, when flipped) sits at the leading edge with roughly 96pt of the preceding column still showing, and the whole panel is on screen. True for a pointer click and for ⌘→ / ⌘← across all five columns.
12. Selecting a Backlog card and then a Done card never shows two panels or two carets at once, and the panel does not slide across four columns.
13. The four #52 symptoms hold with the panel open in Backlog and in Done, checked from the Finder (`./Scripts/build-app.sh && open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app`): title bar present, column headers clear of the traffic lights, status bar full-width at the bottom, and the StatusBar's bottom edge and the first column header's top edge do not move by a point between panel-closed and panel-open.
14. Clicking empty space below the last card in a column, or the board's 10pt padding ring, still clears the selection and closes the panel. Clicking the panel's padding, a section label or its header does **not**.
15. The issue pane renders `card.body` as components, all present for an issue that carries them: a user-story block with proportional (not monospace) `AS A / I WANT / SO THAT` captions; **numbered** acceptance criteria in source order; a task list with a progress meter whose count equals the ticked boxes; `<details>` collapsibles that open; code fences with a language chip, soft-wrapped, and **no syntax colour**; tables with rules and prose (not monospace) cells; markdown callouts, greyscale, with the kind as a `ConsoleLabel`; and inline `#47` / `PR 72` / path chips that open GitHub. A card that has both a `story` and a `body` shows both — today `ElliotKit/Sources/ElliotAppKit/InspectorView.swift:161-192` shows one or the other.
16. The runs pane renders one typed row per event kind, distinguishable on screen: session init (model / permission mode / tool count / cwd as chips), agent text (demoted italic), tool use with **its own tool result nested under it** — including a **successful** one, which is invisible today (`AppModel.describe` returns nil for it, `ElliotKit/Sources/ElliotAppKit/AppModel.swift:343-344`) — a permission-denial row, and the terminal result as the run's closing line. The all/tools/errors filter changes what is shown; `errors` admits failing tool rows and denial rows and nothing else.
17. Those five row kinds all appear **while a run is still running**, not only after it ends: `swift test --filter RunsPaneLiveTests` drives `Scripts/fake-claude.sh` through the real spawn and asserts it, waiting on `FAKE_CLAUDE_READY` with `withTimeout`, never on a fixed sleep.
18. The verdict block shows `run.resultText` under **it said** in demoted italic proportional type, and `run.verifiedOutcome` under **gh says** in the fact face — and the gh side takes its tint and icon from `VerifiedOutcome.receipt` verbatim, so a `.notMerged` or `.unverified` outcome is **not** green. Check on a run whose PR was not merged.
19. `swift test --filter RunLogRowTests` asserts a run whose `resultText` reads `"Filed issue #47"` while its `verifiedOutcome` is `.unverified` produces a `ghSays` string containing no digits.
20. With System Settings ▸ Accessibility ▸ Display ▸ Reduce motion on: selecting cards across columns re-lays the row out instantly — no column slide, no caret travel, no framing-scroll animation. `grep -nE '\.animation\(|withAnimation\(|\.transition\(' ElliotKit/Sources/ElliotAppKit/*.swift` — every hit either carries `reduceMotion ? nil :` or sits under a gated `.animation(…, value:)`. (Today `ElliotKit/Sources/ElliotAppKit/AnalysisWindow.swift:430` does not.)
21. With VoiceOver on: the panel is reached immediately **beside** its origin column — after it in four columns, and *before* it for Done, announces as "Details for ‹title›, in ‹column›". **(Written as “after”; corrected to “beside” on 2026-08-06.** Criteria 3 and 21 contradicted each other and only one of them could hold. Criterion 3 puts the panel *before* Done, because Done is the last column and there is no after; VoiceOver reads siblings in layout order, so in that one case it reaches the panel first. `accessibilitySortPriority` cannot patch it — it sorts the whole container, so raising Done would move it to the front of the entire row. The panel is adjacent to its card either way, which is what the criterion is actually for.); the caret and tether are silent; each log row speaks its kind first ("Tool use, Bash…", "Refused, WebFetch", "It said…", "gh says…"); glyphs and row ordinals are hidden; the five column captions and the status-bar text are all still present. Changing the log filter posts one announcement ("tools, 6 of 11 lines"); the live tail posts none.
22. `grep -rn "Palette.attention" ElliotKit/Sources/ | wc -l` returns **17** — the count before this change. The panel adds no new site for the loosest of the five accents. **(Written as 14; corrected to 17 on 2026-08-06.** The baseline moved when #75–#89 landed on `main`. Measured at the merge commit `dc080be`, before any panel work sat on top of it, the count was already 17. The criterion is *the panel adds none*, and that still holds — 17 before the runs pane, 17 after. Pinning the stale number would have failed this check for someone else's work.)
23. `grep -rn "inspectorWidth" ElliotKit/` returns nothing, and `grep -n "NavigationStack" ElliotKit/Sources/ElliotApp/ElliotApp.swift` still returns hits.

**Related:** #54 (the same complaint, answered differently), #47 (adopted `.inspector()`), #50 (the crash), #52 (the layout), #53 (the revert), #48 (the by-hand pass owed since #47)

**On #54.** #54 proposes making the trailing panel resizable — the third `.inspector()` attempt. This
issue answers the same complaint, in its own words: *"You cannot see the Done column and the card you
are reading at the same time."* It answers it by moving the panel to the card instead of making the
panel narrower, and it uses no `.inspector()`, no `NSSplitViewItem` and no platform inspector API at
all — so none of #50's crash surface exists here. If this lands, #54 is moot and should be closed
rather than attempted a fourth time. The four constraints #54 records are still respected, because
three of them are about the window and not about `.inspector()`: presentation stays driven by an
explicit request, no toolbar item reads the panel's presentation state, nothing wraps the stack that
holds `StatusBar()`, and `NavigationStack` stays.

**Verification is part of this work, not a follow-up.** This repository has no CI — no
`.github/` directory at all — so a pull request is judged by a local `cd ElliotKit && swift test`
plus someone looking at the running app. Criteria 2-3, 5-14, 15-16, 18 and 20-21 below are on-screen
checks, and they are the acceptance criteria, not a checklist for later. ⛔ Do not run `swift format`
over the tree while doing it — `CLAUDE.md` records why.

## Problem

**The panel is at the wrong end of the window.** `ElliotKit/Sources/ElliotAppKit/BoardView.swift:39-47` puts `InspectorView` at a fixed `Metric.inspectorWidth` (344pt, `DesignSystem.swift:130`, one call site) after `columns`. Selecting a card in Backlog puts its details four columns away with nothing joining them; the eye has to carry the association across the whole board. Nothing on screen says *which* card the panel is about except its title.

**Everything inside the panel is a blob.**

- The issue body is one `Text(card.body)` at `InspectorView.swift:187`, and only when the card has no `story` — a card that has both shows the story and silently drops the body (`InspectorView.swift:161-192`). `card.body` is the verbatim GitHub issue body (`ElliotKit/Sources/ElliotModel/GitHubImport.swift:220`), so the acceptance criteria, the `🛠️ Implementation plan` checklist that `implement-issue` ticks as it works, the `<details>` blocks, the code fences and the tables all render as one wall of proportional text.
- The run log is `[String]`. `AppModel.describe` (`AppModel.swift:335-350`) flattens every event to one line, **drops** `.system`, `.partial`, `.unknown`, `.malformed` and every *successful* `.toolResult`, keeps only the first line of agent text, and throws away the tool-use `id` — which is exactly the key needed to nest a result under its call. `RunRow` then renders `Text(line)` per line at 11pt monospace (`InspectorView.swift:372-409`).
- The verdict is there but split across three places and never contrasted: `run.state.label`, then `outcome.receipt` at `InspectorView.swift:319-327`, then the denials at `:334-343`. `run.resultText` — the agent's own prose, documented "Display only — never parsed for issue or PR numbers" at `ElliotKit/Sources/ElliotModel/SkillRun.swift:73-75` — is rendered **nowhere**. The app's central epistemic rule is enforced in code and invisible on screen.

**Two supporting facts the parser has to work around.** `StreamEventDecoder.decodeMessage` returns on the first meaningful block (`ElliotKit/Sources/ElliotModel/StreamEvent.swift:196-227`), so an assistant turn carrying prose *and* a tool call yields one event where the design shows two rows. And `StreamEvent` has no denial case at all: `permission_denials` arrives inside the terminal `result` object (`Fixtures/stream-json/denied.ndjson:3`, decoded at `StreamEvent.swift:174-179`).

## Proposed solution

The approved mockup is `docs/mockups/inline-detail-panel.html` — layout, component inventory and row inventory are read from it. Where it and this repository's design rules disagree, the rules win; those cases are named below.

### Placement

The panel stays a plain conditional sibling inside the columns' `HStack`. **Never `.inspector()`** — an `NSSplitViewItem` whose collapse animation crashed on a constraint invalidation (#50, `2a199ad`) and, applied to the stack that also holds the Divider and StatusBar, covered the title-bar band so the board rode up under the traffic lights and the status bar fell off the bottom (#52, `43f7da3`). The `NavigationStack` at `ElliotApp.swift:28` stays: `.toolbar` is written against a navigation container, which supplies the top safe-area inset. No overlay and no ZStack either — an overlay is not a sibling, so VoiceOver would reach the panel somewhere other than after its origin column, with no visible symptom.

The columns and the panel become one ordered list, `PanelLayout.boardOrder(selected:)` returning `[BoardSlot]`, driven by `ForEach(slots, id: \.self)`. The panel slot carries a **constant** identity, so changing origin column re-orders it rather than destroying and rebuilding it. Emitting the panel conditionally *inside* `ForEach(Column.allCases)` would give it a different identity per column, and under the stack-wide `.animation(…, value: model.selectedCardID)` at `BoardView.swift:52` that is a remove plus an insert — two panels, two carets, mid-transition. The trailing-edge `.transition(.move(edge: .trailing))` at `BoardView.swift:45` goes with it: the panel no longer enters from the window edge.

The panel gets **`.zIndex(1)`**. There is no `zIndex` anywhere in `ElliotKit/Sources/` today, and in a SwiftUI stack later siblings paint over earlier ones. In the flipped case the panel is placed *before* Done, whose `.background` + `.clipShape` + `strokeBorder` (`BoardView.swift:379-384`) would paint over the 8pt of tether that is meant to reach the card. `Surface.recess` is `Color.secondary.opacity(0.06)`, so the occluded segment would not even vanish cleanly — it would show through greyed, reading as a rendering artefact.

The flip is keyed on `column.boardIndex == Column.allCases.count - 1`, not on `naturalNext == nil`. "Which edge of the board is this" is positional, and `Column.boardIndex` exists for exactly that (`ElliotKit/Sources/ElliotModel/Column.swift:38-47`); `naturalNext` is the rule engine's transition matrix (`:31-35`) and is what the panel's own next-step block keys on at `InspectorView.swift:122`. They coincide today only because both read off `allCases`. Keying layout on the matrix would put the caret on the wrong edge the day a terminal-but-not-last column exists.

### Width, and why there is no width threshold

Columns keep today's shared-width formula unchanged, so the board looks identical with the panel closed. The panel is `spans · columnWidth + (spans − 1) · gutter`. `Metric.inspectorWidth` is retired — it has one call site and a span-derived width cannot reuse it.

**The 3-vs-2 span choice is a reader preference on `AppModel`, default 3, in the View menu — not a function of window width.** The mockup does not decide it either: its `width(n)` (line 1035) is bound to two annotation buttons and just sets `--panel-cols`. And a width-derived rule is provably vacuous here: above a 1190pt window `columnWidth = (W − 60)/5`, so `panelWidth(3)/W = 0.6 − 16/W` — essentially constant. The panel is the same *fraction* of the window at 1640pt as at 2560pt, so no threshold in W can distinguish them. Below 1190 the 226 floor binds and the ratio only moves from 0.590 to 0.698. Putting it on a preference is the honest version of what the mockup does; the pure function stays in `PanelLayout` so the arithmetic is still pinned by test.

The board therefore **scrolls horizontally whenever the panel is open, by design**. `.scrollDisabled` at `BoardView.swift:252` currently derives from the five-column share alone and would report "everything fits" over content that is 1.6–1.7× the viewport, leaving the panel or Done silently unreachable with no scrollbar — green on both `swift build` and `swift test`. It becomes `contentWidth(boardWidth:spans:) <= boardWidth`.

Framing switches the board's horizontal scroll to macOS 15's `ScrollPosition` + `.scrollPosition($pos)` with an explicit `pos.scrollTo(x:)`. `ScrollViewProxy.scrollTo(_:anchor:)` aligns one view to a `UnitPoint` and takes no offset, so it cannot express the mockup's 96pt lead (line 1030) and, with the panel inline, `anchor: .center` on the origin column pushes the panel half off the right edge — and the whole panel off-screen in the flipped case. The per-column vertical `ScrollViewReader` at `BoardView.swift:443-491` is a different scroll view and is untouched. Both existing `.onChange` handlers (`:255-260` and `:265-270`) route through one `frame(on:)`; they exist separately because `nudgeSelection` never writes `selectedCardID`, so updating only the click path leaves ⌘→ behind the card.

### Caret, tether, detached

The caret is notched out of the panel's edge at −9pt; the tether spans `Metric.gutter + Metric.columnListPadding` = 18pt, the gutter plus `ColumnView`'s own 8pt list padding (`BoardView.swift:471`), so it *touches* the card rather than reading as a dash near it. Naming that literal is the point — left bare, the tether stops touching the day the padding changes. Both are drawn outside the panel's bounds and both carry `.allowsHitTesting(false)` and `.accessibilityHidden(true)`: in SwiftUI an overlay drawn outside its parent still hit-tests, and without that an ~18pt strip of the origin column would stop accepting taps and drops.

`caretY = clamp(cardMidY − panelMinY, 26, panelHeight − 26)` — 26 keeps it off the panel's rounded corners. The card is detached when its centre falls outside `listTop + 6 … listBottom − 6` **or when there is no card rect at all**: cards live in a `LazyVStack`, so a card scrolled far enough is never built and its geometry reporter simply stops firing. Treating absence as `y = 0` would aim the caret at the top of the panel and assert a card is there. Detached means tether opacity 0, caret opacity 0.35.

Geometry comes from `.onGeometryChange` / `.anchorPreference(.bounds)` reported in the board's coordinate space — one reporter feeding both the caret and the framing offset. Never a bare wrapping `GeometryReader` (greedy — it would resize the card), never `matchedGeometryEffect` (it relocates a view; it reports nothing).

Caret and tether position **never interpolate in response to scrolling**. The mockup recomputes the anchor on every column scroll, board scroll and resize (lines 930-956) with `transition: top .18s`; animated position driven by scroll is continuous motion nobody asked for. They animate on selection change only, gated on `accessibilityReduceMotion` — as is the container's `.animation(value:)`, since the largest motion when the panel opens is every column to its right sliding.

### The issue body as components

A hand-written scanner in `ElliotModel`, **total** in the same sense `StreamEventDecoder` is: never throws, never drops a line, anything unrecognised degrades to a paragraph. `card.body` is arbitrary user prose, not a template, and a mis-segmented body renders an empty or truncated panel with no error, no crash and no failing test. No new package dependency: the parser must be `Sendable` under `swiftLanguageModes: [.v6]`, and this repository has no CI to catch a dependency that stops resolving.

Two colour decisions against the mockup:

- **No syntax highlighting.** The mockup paints YAML keys in `--armed` and string literals in `--verified` (line 306). Those are the two scarcest accents in the app — armed means "a gesture here starts an autonomous run", verified means "`gh` confirmed it". A quoted string in an issue's code fence arms nothing and was confirmed by nothing, and it is high-frequency: many tokens per fence, several fences per issue. `Palette.quiet` exists for exactly this.
- **Callouts render greyscale**, kind carried by `ConsoleLabel` and repeated in the accessibility label. `Palette.attention` means "still alive, wants a decision"; letting an issue author's `> [!IMPORTANT]` paint the panel amber lets arbitrary prose imitate a run state.

The one licensed green is the task-list ticks and progress meter, **on the stated condition that the body was fetched through `GHClient`**: those checkboxes are ticked on the live issue by `implement-issue` and read back by `gh issue view --json body`, so a tick genuinely is a fact `gh` established. Write the condition in the comment beside the tint. The mockup's `.plan li.is-live` "being written now" highlight (line 323) is dropped — nothing in the model maps a run to a checklist item, so it could only come from the agent's prose or a guess.

Three more mockup details dropped, each for a stated reason: `.md-story .kw` in mono (line 286) — those are Elliot's own field names, and the machine face is reserved for what a machine established; use `ConsoleLabel`. `.md-table td.m` (line 339) — the class is applied by hand in the mockup and there is no signal in markdown for it; a cell whose author wrote `` `swift build` `` picks up the inline-code face through the normal inline path. And the "On GitHub" chips `#47 open`, `PR 72 draft` and Labels have no data source: `GHClient.issueListFields` is `"number,title,body,url,state,createdAt"` (`ElliotKit/Sources/ElliotProcess/GHClient.swift:101`) — no labels at all — and neither issue state nor PR draft is a `Card` column. They are drawn in the fact face, which asserts a machine established them; populating any of them from the column or from a run's prose would be the exact lie the verdict block exists to expose. They need a fetch widening plus an additive migration, which is its own issue.

### The log as typed rows

`AppModel.liveLog` becomes `[UUID: [StreamEvent]]`, still capped at 300. `AppModel.describe` **survives**, narrowed to the card's one-line running strip (`CardView.swift:29`), and its two existing tests survive with it. A typed-row renderer built over the current `[String]` would look typed and be empty for a run in flight — the one case the panel exists for.

`StreamEventDecoder.decodeAll(line:)` is added and `decode` is redefined as `decodeAll(line:).first`. Additive on purpose: "never throws and never drops a line" is a shipped contract that `ElliotProcess`, `ElliotEngine`, `ElliotMCPKit` and `InspectorView` all consume, pinned by an existing suite.

Denial rows are **synthesised** from `RunResult.permissionDenials` (live) and `SkillRun.permissionDenials` (replayed), never decoded — `StreamEvent` has no denial case. Write that into the classifier's contract so nobody tests for an event that does not exist.

Three further decisions:

- **A successful tool result is greyscale.** The mockup's `.tres .ok{color:var(--verified)}` (line 403) puts the process's report on itself in the colour reserved for `gh`'s receipt — a green ✓ on `gh pr create` sits three rows above a green `verdict--fact` block with nothing distinguishing them. A **failing** result keeps `Palette.refused`: a non-zero exit is an observed error, not an outcome claim.
- **`.lrow--live .c{color:var(--armed)}` (line 397) is dropped.** A log row is not a gesture and nothing starts by looking at it. "This is the newest line" is already carried by position, by the spinner in that row's gutter, by the run-box state line, and by the card's `RunningStrip`.
- **The per-denial row is greyscale** with a `ConsoleLabel("Refused")`; `Palette.attention` stays on the aggregate "Refused tools: …" label, which is the actionable one. Otherwise one fact is stated three times in one panel, and the `errors` filter becomes a screen of nothing but amber. Attention already has 14 call sites across six files — the loosest of the five accents.
- **One glyph per row *kind***, not per tool. The mockup's per-tool glyph (terminal for Bash, file for Write) duplicates the tool chip 13px to its right, needs a table maintained as Claude Code adds tools, and `StreamEvent.assistantToolUse` carries the name as a free `String`, so unmapped is the normal case.
- **No per-row elapsed gutter.** No `StreamEvent` carries a timestamp and the decoder reads none. Stamping `Date()` at arrival gives a number that is right for a live run and wrong for a finished one re-read from disk, rendering identically — two sources, one face, which is the failure the verdict block exists to prevent. The run-level elapsed stays.
- **`StreamEventDecoder.preview(of:limit: 200)` is unchanged**, so a failing tool result shows its 200-character preview soft-wrapped in the code well rather than the mockup's full `<pre>` body. Raising that limit changes ElliotModel's contract, and `RunRow.logLines` (`InspectorView.swift:417-434`) already reads and decodes the whole NDJSON file synchronously inside a computed property evaluated during `body`.

### The verdict

`RunVerdict.of(_:)` in `ElliotModel` splits `run.resultText` ("it said", demoted italic proportional) from `run.verifiedOutcome` ("gh says", fact face). Pure, so a test can feed a run whose `resultText` claims "Filed issue #47" while its outcome is `.unverified` and assert the gh side carries no number — the app's central invariant becomes a failing test instead of a convention.

**The gh side takes `receipt.tint` and `receipt.icon` verbatim**, exactly as `InspectorView.swift:326` does today; the wash is `Surface.wash(receipt.tint)`. The mockup's `.verdict__fact{color:var(--verified)}` (line 359) only ever illustrates the happy case. `VerifiedOutcome.receipt` (`Consequence.swift:204-221`) returns `Palette.inert` for `.noIssueCreated`, `Palette.refused` for `.notMerged` and `.closedUnmerged`, `Palette.attention` for `.unverified`. A fixed verified tint would render "Not merged — CI red" in the colour meaning `gh` confirmed it, in the one block whose entire purpose is to stop the app conflating a claim with a receipt.

`VerifiedOutcome.receiptText` moves down to `ElliotModel` and `Consequence.receipt` decorates it with tint and icon: one text, one implementation, and reachable from `ElliotModelTests`, which cannot import `ElliotAppKit`.

### Where the pure code lives

`CLAUDE.md` now says to put a rule in `ElliotModel` because it is pure and shared with the MCP helper, not because the app target is a black box — `ElliotAppKit` is a library with a test target (`ElliotKit/Package.swift:103`). So: folds over model types (the markdown parser, `decodeAll`, the log-row classifier, `RunVerdict`, `receiptText`) go to **ElliotModel**, beside `StreamEventDecoder` whose contract they copy. Arithmetic measured in points, consuming `Metric` and producing `Column.railTint`, goes to **ElliotAppKit** — `grep -rn 'CGFloat|CGRect|CGPoint' ElliotKit/Sources/ElliotModel/` returns nothing today, and it should stay that way.

Panel view state — the span preference, the selected pane, the log filter — lives on `AppModel` beside `showingInspector`, for the reason that file already gives at `AppModel.swift:38-46`: a menu command cannot reach a view's `@State`, and `showingInspector` is already driven by both the toolbar Button and View ▸ Show Details (⌘⌥I).

### What does not change

The Details toolbar item stays a `Button` and stays untinted (`BoardView.swift:182-195`) — the mockup's `.tb--on` armed state (line 110) would regress a decision already commented there, and both #50 triggers were derived presentation bindings on that item. No binding is introduced whose `get` reads `selectedCard` while its `set` writes `showingInspector`.

The board's deselect gesture stays on the `columns` container (`BoardView.swift:273-278`) — it fires by bubbling today, from empty space inside a column's list and from the board's padding ring, and moving it behind the `HStack` risks losing both silently. The panel absorbs its own stray taps with `.contentShape(Rectangle()).onTapGesture {}`.

The panel never takes focus when it opens. `BoardView` is the only `@FocusState` in the tree and owns the arrow keys, Escape and ⌘→/⌘←; `onKeyPress` fires on the focused view, so a `.defaultFocus` inside a panel that appears on every selection would take the arrows away on the very gesture that opens it.

`CardFieldsEditor` keeps its current full-panel-takeover shape. It is orthogonal to this change and putting a second unverifiable layout change in the same diff is how #47 happened. Both existing guarantees stand: editing is refused once `card.issueNumber != nil`, and a failed save keeps the typed text on screen with the reason.

The panel gets the app's first `.shadow` — there is none in `ElliotKit/Sources/` today. It is greyscale, so it spends none of the colour budget, and it is the only thing distinguishing "panel" from "a sixth column".

## Area

`ElliotModel` · `ElliotAppKit` · `ElliotApp` · `ElliotModelTests` · `ElliotAppKitTests`

Not touched: `ElliotStore` (no migration — nothing new is persisted), `ElliotProcess`, `ElliotEngine`, `ElliotIPC`, `ElliotMCPKit`.

<details>
<summary>🧠 Brainstorm</summary>

**`.inspector()` again, now that we would place it correctly.** Rejected without weighing. It has shipped three times, green on `swift build` and `swift test` each time: #47 adopted it unverified, #50 was the crash, #52 destroyed the window layout, #53 the revert (68/75 lines across 3 files to undo). `ElliotKit/Package.swift:25-31` records that history as the reason `ElliotAppKit` exists. The panel must be a sibling because the status bar and the board's height depend on it.

**An overlay or ZStack floating over the columns.** Loses nothing visually and everything structurally: an overlay is not in the accessibility reading order, so VoiceOver would reach the panel at an arbitrary point with no visible symptom. Rejected.

**Re-share the viewport across five columns plus the panel** so nothing scrolls. Rejected: every column re-lays out on selection, so the card the caret is trying to point at moves under the pointer at the moment the caret appears. The mockup takes the fixed-width route (`--col-w:236px`, `overflow-x:auto`) for the same reason.

**Pin the panel to `Metric.minColumnWidth`** — a constant 698 / 462 regardless of window. Attractive: the panel is the same size everywhere, and 968pt at a 1640pt window is a lot of panel. Lost because the brief and the caret both depend on the panel being measured *in columns*: 698 beside 316-wide columns reads as 2.2 columns, not 3, and the "this panel is of that column" reading weakens.

**Derive the span from board width.** Five readers assumed this; the mockup does not do it and the arithmetic says it cannot be done. Above 1190pt `panelWidth(3)/boardWidth` is constant at 0.6 − 16/W, so no threshold in W separates a wide window from a narrow one. Preference it is.

**Keep `ScrollViewReader` and use `anchor: .leading`** on the origin column, giving up the 96pt lead. Genuinely cheaper — no new mechanism, and the pair fits the viewport at every width (1294pt at 1640, 934pt at 1000). Lost on the lead: without it the board looks like it *starts* at that column rather than being scrolled to it, and the geometry reporter the caret needs already supplies the minX that `ScrollPosition` wants. One mechanism, decided once, beats two.

**Nested scroll regions.** The mockup's code fences are `overflow-x:auto` (line 306), which inside the board's own horizontal `ScrollView` means a two-finger swipe over a wide fence scrolls the fence and never the board — with content at 2618pt, Done becomes unreachable by gesture. Resolved by soft-wrapping fences instead of scrolling them. The **log's** own bounded vertical scroller inside a scrolling pane is the arrangement that ships today (`InspectorView.swift:387`, `.frame(height: 260)`) and is kept: an unbounded 300-line log inside the pane is worse.

**`swift-markdown` as a dependency.** Weighed and dropped: the parse output must be `Sendable` under `swiftLanguageModes: [.v6]`, the parser must be total in a way a general-purpose library does not promise, and this repository has no CI — a dependency that stops resolving is discovered by a human at the wrong moment. The scanner needed here is small and its contract is the interesting part.

**Reflection over `Palette` for the accent guard.** Cannot be written: `Palette` is an enum namespace of `static let`s (`DesignSystem.swift:19-67`) with no reflection over static members, its values are `Color(nsColor: NSColor(name: nil) { … })` whose cross-instance equality is meaningless, and `BrandColor` is a struct, not `CaseIterable`. The guard becomes `BrandColor.consequences: [BrandColor]` in `ElliotModel`, asserted by count and by hex in `BrandColorTests` where the numbers are real data, plus the radius-ladder assertion in `DesignSystemTests` — the one half that was always writable.

**Landing this as one pull request.** The change has two halves with disjoint verification: tasks 2–10 are provable by `swift test` and touch no layout; tasks 11–14 are provable only by launching from the Finder and looking. The seam is real and the plan below is ordered on it — tasks 2–10 leave the panel in its current trailing slot and the board whole, so they can be landed and merged before the placement half begins. Whether that is one PR or two is the implementer's call; if two, retire `Metric.inspectorWidth` in the second, where the span-derived width replaces it.

### Critiques applied

**Accepted, verified against the code:**

- *Missing `zIndex`* (layout 1) — `grep -rn zIndex ElliotKit/Sources/` returns nothing, and `ColumnView` paints background + clip + border at `BoardView.swift:379-384`. In the flipped case Done would paint over the tether's reach. Fixed with `.zIndex(1)` on the panel slot, and the shadow needs it too.
- *Widths computed at the 226 floor* (layout 2) — confirmed: `max(226, (W−60)/5)` gives 316 at the 1640pt default, so the panel is 968/642 and content 2618/2292, not the 1898/1662 in the map (those are the 1000pt numbers). Every derived decision — the scroll predicate, the span threshold, `defaultSize` — was resting on a figure 2.4× off. The tests now drive `columnWidth` from the real formula at three board widths.
- *`scrollTo(anchor:)` cannot express an offset* (layout 3) — confirmed, no `ScrollPosition` or `scrollPosition` anywhere in `ElliotKit/Sources/`. The mechanism is now named.
- *The chrome check expires one task early* (layout 4) — accepted; it now runs at the end of tasks 11, 12, 13 and 14, with the two falsifiable measurements.
- *Only the negative half of the deselect gesture was checked* (layout 5) — accepted, and resolved by keeping the gesture where it is rather than moving it behind the stack.
- *Panel identity across columns* (layout 6) — accepted; `ForEach` over a slot list with a constant panel identity, and the trailing-edge transition replaced.
- *Nested same-axis scrolling* (layout 7) — accepted for code fences, **rejected for the log**: that nesting ships today and unbounded is worse.
- *Framing fires in the same update that inserts the panel* (layout 8) — accepted as a first-click verification rather than a mandated deferral.
- *Panel height* (layout 9) — accepted; `.frame(maxHeight: .infinity, alignment: .top)` matching `ColumnView` at `BoardView.swift:378`, otherwise the caret's clamp range varies with the card's content.
- *`EndToEndTests` cannot see `ElliotAppKit`* (verification 1) — confirmed: `Package.swift:85` gives it `["ElliotEngine", "TestSupport"]` and it opens `@testable import ElliotEngine`. The named filter would have run six pre-existing tests and exited 0. New suite `RunsPaneLiveTests` in `ElliotAppKitTests`, with the seam named.
- *Task 3's fixtures do not exist* (verification 2) — confirmed by reading all four `.ndjson` files: `create-issue-success.ndjson` is strictly sequential, nothing has `is_error:true` on a `tool_result`, nothing is malformed, and denials arrive inside `result` (`denied.ndjson:3`). Four fixtures added, and the denial synthesis written into the contract.
- *`receipt` is in `ElliotAppKit` and returns a `Color`* (verification 3) — confirmed at `Consequence.swift:204`. `receiptText` moves to `ElliotModel`.
- *The accent guard cannot be written* (verification 4) — confirmed; replaced with `BrandColor.consequences`.
- *The span boundary is asserted nowhere* (verification 5) — accepted, and resolved by proving no boundary exists.
- *The animation grep is blind to `withAnimation`* (verification 6) — confirmed: the narrow pattern finds 5 hits, the wide one finds 4 `withAnimation(` and 6 `.transition(`, including the panel's own at `BoardView.swift:45` and the ungated `AnalysisWindow.swift:430`.
- *Totality proves nothing is lost, not that anything is segmented right* (verification 7) — accepted; the criteria count, the meter tuple, and the inline scan (including "`#47` inside a fence is not a chip") are asserted in `IssueMarkdownParserTests`.
- *Backlog → To Do is live too* (verification 8) — confirmed at `RuleEngine.swift:107-113`: a complete unfiled story spawns `create-issue`. Added to the forbidden list, with the safe way to seed all five columns (`GitHubImport.column(for:)`, `GitHubImport.swift:65-76`).
- *The 408 floor cannot detect the loss it exists for* (verification 9) — accepted; replaced with a per-suite survival check, and the number is updated in the docs task.
- *`apply(_:)` is private* (verification 10) — confirmed at `AppModel.swift:297`; the seam is named.
- *Fixed verified tint on the gh side* (scope 1) — confirmed against `Consequence.swift:204-221`. This was the worst finding: it would have painted "Not merged" green in the block built to stop exactly that, and regressed working code at `InspectorView.swift:326`.
- *Task 6 does not compile* (scope 3) — confirmed: retyping `liveLog` breaks `InspectorView.swift:254`, `:293` and `:417`, and `InspectorView.swift` was not in that task's file list. The retype task now carries both files.
- *`.lrow--live` armed* (scope 4) — confirmed at mockup line 397, a different selector from `.plan li.is-live` at 323. Dropped, and named in the drop list.
- *Mono on the filter and the story captions* (scope 5) — confirmed at mockup lines 364 and 286. `ConsoleLabel` and a segmented `Picker` instead.
- *Attention stated three times* (scope 6) — confirmed, 14 call sites across six files. The per-denial row goes greyscale, and the count becomes a checkable criterion.
- *Per-tool glyphs* (scope 7) and *`td.m`* (scope 8) — confirmed at mockup lines 741/759 and 339. Both dropped.
- *Flip on `boardIndex`, not `naturalNext`* (scope 9) — accepted; both exist and are documented in `Column.swift`.
- *Repo-profile drift and the `AnalysisWindow` one-liner* (scope 10, 11) — confirmed: `repo-profile.md:19` says 408 tests, `:86` names `ElliotKit/Sources/ElliotApp/AppModel.swift`, `:100` claims a rule in a SwiftUI view is unprovable, `:26`/`:29` float `swift format --recursive -i`. All four are stale and none is caused by this change. They become the first commit, along with the ungated `.animation` at `AnalysisWindow.swift:430`.

**Rejected:**

- *Split into two GitHub issues* (scope 2). The seam is real and is honoured in the ordering — tasks 2–10 land the content in the existing trailing slot and are separately mergeable — but the brief asks for one issue, and splitting the *story* would leave neither half describing the thing the user asked for.
- *The log's nested vertical scroller* (half of layout 7). It ships today at `InspectorView.swift:387` and the alternative is worse.

**Corrected in the map, unprompted by any critic:** the map claims a run's `verifiedOutcome` receipt and the mockup's `<pre>` failure body can both be rendered; `StreamEventDecoder.preview` collapses to a single line and truncates at 200 characters (`StreamEvent.swift:240-258`), so the multi-line body cannot reach a view. Stated as a deliberate omission rather than left as an open question.
</details>

<details>
<summary>📋 Spec</summary>

### `ElliotModel/IssueMarkdown.swift` — the block model

```swift
public enum IssueBlock: Sendable, Hashable {
    case heading(level: Int, text: InlineText)
    case paragraph(InlineText)
    case userStory(role: String, want: String, benefit: String)   // "As a … I want … so that …"
    case orderedList([InlineText])                                // acceptance criteria
    case bulletList([InlineText])
    case taskList([TaskItem])                                     // "- [x] …" / "- [ ] …"
    case codeFence(language: String?, code: String)
    case callout(kind: String, body: [IssueBlock])                // "> [!IMPORTANT]"
    case quote([IssueBlock])
    case table(header: [InlineText], rows: [[InlineText]])
    case collapsible(summary: InlineText, body: [IssueBlock], lineCount: Int)  // <details>
    case rule
}

public struct TaskItem: Sendable, Hashable {
    public var done: Bool
    public var text: InlineText
}

/// Inline runs, so `#47`, `PR 72`, paths and `code` spans survive segmentation.
public struct InlineText: Sendable, Hashable {
    public var runs: [Run]
    public enum Run: Sendable, Hashable {
        case text(String)
        case emphasis(String)
        case strong(String)
        case code(String)
        case issueRef(Int)        // #47 — never inside a code span or fence
        case prRef(Int)           // PR 72 / pull/72
        case path(String)         // a/b.swift, .github/workflows/ci.yml
        case link(text: String, url: String)
    }
    public var plain: String { get }   // every run's characters, in order
}

public struct IssueDocument: Sendable, Hashable {
    public var blocks: [IssueBlock]
    /// (done, total) over every `.taskList` in the document. `nil` when there is none.
    public var taskProgress: (done: Int, total: Int)?
    public var acceptanceCriteria: [InlineText]   // the first `.orderedList` under an
                                                  // "Acceptance criteria" heading, else []
}
```

### `ElliotModel/IssueMarkdownParser.swift`

```swift
public enum IssueMarkdownParser {
    /// Total: never throws, never drops a line. Anything unrecognised becomes
    /// `.paragraph`. The same discipline as `StreamEventDecoder.decode`.
    public static func parse(_ body: String) -> IssueDocument
}
```

Totality invariant, asserted per fixture: for every non-blank line of the source, that line's non-whitespace characters appear in the concatenation of every block's plain text, in order.

Fixtures at `Fixtures/issues/`: `full-template.md` (the repo's own issue shape — user story, acceptance criteria, problem, proposed solution, area, two `<details>`, a task list with a known ticked count, a code fence, a table, a callout, `#47` in prose **and** inside a fence), `prose-only.md` (no headings, no lists), `adversarial.md` (unterminated fence, `<details>` with no `</details>`, a table with ragged rows, a task list inside a collapsible, CRLF).

### `ElliotModel/StreamEvent.swift` — additive

```swift
public extension StreamEventDecoder {
    /// Every meaningful block of one NDJSON line, in order. An assistant turn
    /// carrying prose *and* a tool call yields two events.
    static func decodeAll(line: Data) -> [StreamEvent]
}
// decode(line:) becomes decodeAll(line:).first — signature, doc comment and
// every existing assertion unchanged.
```

### `ElliotModel/RunLogRow.swift`

```swift
public enum RunLogRow: Sendable, Hashable, Identifiable {
    case session(SystemInit)
    case agentText(String)
    case toolUse(name: String, id: String, input: String, outcome: ToolOutcome?)
    case denial(toolName: String)          // synthesised from permissionDenials,
                                           // never decoded — StreamEvent has no case
    case orphanResult(ToolOutcome)         // a result whose tool_use never arrived
    case terminal(RunResult)
    case unreadable(text: String)          // .malformed / .unknown, raw text kept
    public var id: String { get }
}

public struct ToolOutcome: Sendable, Hashable {
    public var isError: Bool
    public var preview: String
}

public enum RunLogFilter: String, CaseIterable, Sendable {
    case all, tools, errors
}

public enum RunLog {
    /// Folds a decoded stream into rows. A `.toolResult` attaches to the
    /// `.toolUse` whose `id` matches — by id, never by arrival order — and an
    /// unmatched one becomes `.orphanResult`. `.system` and `.partial` are
    /// dropped; `.malformed`/`.unknown` survive as `.unreadable`.
    public static func rows(from events: [StreamEvent],
                            denials: [String] = []) -> [RunLogRow]

    /// `.tools` keeps `.toolUse`; `.errors` keeps `.denial`, `.toolUse` whose
    /// outcome `isError`, `.orphanResult` whose outcome `isError`, and a
    /// `.terminal` that is not clean. Nothing else.
    public static func filter(_ rows: [RunLogRow], by: RunLogFilter) -> [RunLogRow]
}

public struct RunVerdict: Sendable, Hashable {
    /// `run.resultText`. Demoted italic proportional. Never parsed.
    public var itSaid: String?
    /// `run.verifiedOutcome?.receiptText`. Fact face.
    public var ghSays: String?
    public static func of(_ run: SkillRun) -> RunVerdict
}

public extension VerifiedOutcome {
    /// The text half of what `gh` established. `Consequence.receipt` in
    /// ElliotAppKit decorates it with tint and icon — one text, one place.
    var receiptText: String { get }
}
```

New fixtures at `Fixtures/stream-json/`: `interleaved-tools.ndjson` (two `tool_use` in flight, results returning out of order), `orphan-result.ndjson`, `failing-tool.ndjson` (`"is_error":true` on a `tool_result`), `garbage-line.ndjson` (a non-JSON line and an unknown `type`).

### `ElliotAppKit/PanelLayout.swift`

```swift
enum BoardSlot: Hashable {
    case column(ElliotModel.Column)
    case panel                    // one constant identity — reordered, never rebuilt
}

enum PanelLayout {
    /// Today's formula, extracted so the panel's width and the scroll predicate
    /// derive from the same number the columns do.
    static func columnWidth(boardWidth: CGFloat) -> CGFloat

    static func panelWidth(columnWidth: CGFloat, spans: Int,
                           gutter: CGFloat = Metric.gutter) -> CGFloat

    /// 5 columns + panel + 7 gutters, or 5 columns + 6 gutters when closed.
    static func contentWidth(boardWidth: CGFloat, spans: Int?) -> CGFloat

    /// The last column in board order opens left.
    static func opensLeft(of column: ElliotModel.Column) -> Bool

    /// Columns in board order with `.panel` inserted after (or before) the
    /// origin. Always 6 entries when a card is selected, 5 otherwise.
    static func boardOrder(selected: ElliotModel.Column?) -> [BoardSlot]

    static func caretY(cardMidY: CGFloat, panelMinY: CGFloat,
                       panelHeight: CGFloat, inset: CGFloat = 26) -> CGFloat

    /// `nil` cardMidY (the card is not built) reads the same as out of band.
    static func isDetached(cardMidY: CGFloat?, listTop: CGFloat,
                           listBottom: CGFloat, inset: CGFloat = 6) -> Bool

    /// Leading edge of the pair minus the lead. Never negative.
    static func frameOffsetX(originMinX: CGFloat, panelMinX: CGFloat,
                             flipped: Bool, lead: CGFloat = 96) -> CGFloat

    static let tetherReach: CGFloat = Metric.gutter + Metric.columnListPadding  // 18
}
```

Pinned by `PanelLayoutTests`: `panelWidth(columnWidth: 316, spans: 3) == 968`, `spans: 2 == 642`; `contentWidth` > boardWidth at 1000, 1640 and 2560 for both spans; exactly `Column.done` opens left, and `boardOrder` always contains all five `.column` cases plus one `.panel`; `caretY` clamps to 26 and `height − 26` and is the identity between; `isDetached` is true at and past the 6pt inset on both edges and true for `nil`; `frameOffsetX` is never negative and uses `panelMinX` when flipped.

### `ElliotAppKit/DesignSystem.swift` — additions only

```swift
Metric.columnListPadding: CGFloat = 8    // names the literal at BoardView.swift:471
Metric.panelElevation: (radius: CGFloat, y: CGFloat, opacity: Double)
Metric.inspectorWidth                     // REMOVED

Type.hearsay      // italic proportional 12pt — the demoted "it said" face,
                  // the visual opposite of Type.fact
Type.labelSmall   // 10pt tracked proportional

Surface.washFaint(_ tint: Color)   // ~0.09, replacing InspectorView.swift:143-144's
                                   // wash(tint).opacity(0.6)
Surface.hairline                   // the 1pt rule inside a panel
Surface.well                       // the code / log ground; in dark it is darker
                                   // than the window, which .textBackgroundColor is not
```

10.5pt mono in the mockup collapses onto `Type.factSmall` (10pt); 11.5pt sans onto `Type.bodyProse` (12pt). No new accent — `BrandColor.consequences: [BrandColor]` in `ElliotModel` names the five so a sixth fails a test.

### `ElliotAppKit/AppModel.swift`

```swift
public private(set) var liveLog: [UUID: [StreamEvent]] = [:]   // still capped at 300
public var panelSpans: Int = 3          // reader preference, View menu
public var panelPane: PanelPane = .issue
public var logFilter: RunLogFilter = .all

func apply(_ update: SchedulerUpdate)   // was private; the cap and the accumulation
                                        // are unreachable from a test otherwise

/// Memoised per (cardID, body). `describe` survives, narrowed to CardView's
/// one-line running strip (CardView.swift:29).
func issueDocument(for card: Card) -> IssueDocument
```

### Views

- `DetailPanelView.swift` — container: top rail at `card.column.railTint`, header (title, close, column chip, repo, elapsed, next-step block, segmented `Picker` at 2 spans), body. `.frame(width: panelWidth)`, `.frame(maxHeight: .infinity, alignment: .top)`, `.zIndex(1)`, `Metric.panelElevation`, no `.clipShape` on the container (each pane clips itself), `.contentShape(Rectangle()).onTapGesture {}` to absorb stray taps, `.accessibilityLabel("Details for \(card.displayTitle), in \(card.column.displayName)")`.
- `CaretRail.swift` — the caret shape and the 2pt tether. `.allowsHitTesting(false)`, `.accessibilityHidden(true)`. Position animates on selection change only, gated on `reduceMotion`.
- `IssuePane.swift` + `MarkdownBlocks.swift` — one view per `IssueBlock` case. Each block is one combined accessibility element whose label leads with its kind.
- `RunsPane.swift` + `LogRows.swift` — one view per `RunLogRow` case, the filter `Picker`, and the verdict block. Each row is one combined element; label leads with the kind ("Tool use. Bash…", "Refused: WebFetch.", "It said…", "gh says…"); glyphs and ordinals hidden; timestamps in `.accessibilityValue`.
- `BoardView.swift` — `ForEach(PanelLayout.boardOrder(selected:), id: \.self)`, `.scrollPosition($boardScroll)`, the derived `.scrollDisabled`, and one geometry reporter in board coordinates feeding both the caret and `frameOffsetX`.
- `InspectorView.swift` — shrinks to the header and the editor takeover; the story/body and runs sections move to the two panes. `RunRow.liveLines` becomes `[StreamEvent]`.
</details>

## 🛠️ Implementation plan

- [x] Docs and one pre-existing gate, as their own commit: refresh `.claude/skills/repo-profile.md` (line 19's test count, line 86's `ElliotApp/AppModel.swift` path — moved in #74, line 100's "rules in a view are unprovable" claim, lines 26/29's `swift format --recursive -i` candidate, which `CLAUDE.md` forbids) and gate the ungated `.animation` at `AnalysisWindow.swift:430`. `grep -n 'ElliotApp/AppModel.swift\|unprovable\|format --recursive' .claude/skills/repo-profile.md` returns nothing, and `sed -n '430p' ElliotKit/Sources/ElliotAppKit/AnalysisWindow.swift` shows `reduceMotion ? nil :`
- [x] `ElliotModel`: `IssueMarkdown.swift` block model and `IssueMarkdownParser.swift`, plus three fixtures under `Fixtures/issues/`. `cd ElliotKit && swift test --filter IssueMarkdownParserTests` — non-zero count, totality per fixture, criteria count and order, task `(done, total)`, `#47` found in prose and not inside a fence
- [x] `ElliotModel`: `StreamEventDecoder.decodeAll` added, `decode` redefined as its `.first`, signature and doc comment untouched. `cd ElliotKit && swift test --filter StreamEventTests` — every pre-existing assertion still green plus one turn with a text block and a tool_use block yielding two from `decodeAll` and exactly the first from `decode`
- [x] `ElliotModel`: `RunLogRow.swift` — classifier, filter, `RunVerdict`, and `VerifiedOutcome.receiptText` (with `Consequence.receipt` rewired to it), plus four fixtures under `Fixtures/stream-json/`. `cd ElliotKit && swift test --filter RunLogRowTests` — inputs decoded through `StreamEventDecoder`, not hand-built; results fold by id not arrival order; orphan gets its own row; a tool use with no result yet has `outcome == nil`; `.errors` admits failing tool rows and denials and nothing else; `resultText` "Filed issue #47" with `.unverified` yields a `ghSays` with no digits
- [x] `ElliotAppKit`: `PanelLayout.swift` and the `Metric` additions. `cd ElliotKit && swift test --filter PanelLayoutTests` — the seven cases above, with `columnWidth` driven from the real formula at boardWidth ∈ {1000, 1640, 2560}
- [x] `ElliotAppKit`: the design tokens, and `BrandColor.consequences` in `ElliotModel` as the accent guard. `cd ElliotKit && swift test --filter DesignSystemTests --filter BrandColorTests` — five consequences by count and by hex, radius ladder still `nested < card < panel < column`
- [x] `ElliotAppKit`: retype `AppModel.liveLog` to `[UUID: [StreamEvent]]`, narrow `describe` to the card strip, memoise `issueDocument(for:)`, make `apply(_:)` internal, and retype `RunRow.liveLines` in `InspectorView.swift` in the same commit so the package still builds. `cd ElliotKit && swift test --filter AppModelTests` — the two `describe` assertions survive, the two "Log rendering" tests are rewritten as positive statements about which typed row each event produces, `liveLog` caps at 300 by feeding 301 `.runOutput` updates; then `cd ElliotKit && swift test` whole-suite green
- [x] `ElliotAppKit`: `IssuePane.swift` and `MarkdownBlocks.swift`, still rendering in the existing trailing slot. `./Scripts/build-app.sh && open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app`, add this checkout, Refresh once, select a card with a real issue body — criterion 15 in full, and a card with both a story and a body shows both
- [x] `ElliotAppKit`: `RunsPane.swift` and `LogRows.swift` with the verdict block, still in the trailing slot; new `RunsPaneLiveTests` in `ElliotAppKitTests`. `cd ElliotKit && swift test --filter RunsPaneLiveTests` — `Scripts/fake-claude.sh` emits a tool_use, a **successful** tool_result, a denial and a result; each reaches a distinct typed row while the run is still running, waiting on `FAKE_CLAUDE_READY` with `withTimeout`; then on screen, criteria 16 and 18
- [x] `ElliotAppKit`: `DetailPanelView.swift` at `panelWidth`, still at the trailing edge. `./Scripts/build-app.sh && open -n … dist/Elliot.app` — criterion 13's four symptoms with both measurements, criterion 6's rail tint across all five columns, and criterion 5's segmented switch by toggling the span preference
- [x] `BoardView.swift`: the structural move — `boardOrder` slots, `.zIndex(1)`, `ScrollPosition` framing through one `frame(on:)` for both `onChange` handlers, the derived `.scrollDisabled`, tap absorption on the panel, the non-travelling transition. `./Scripts/build-app.sh && open -n … dist/Elliot.app` at 1000pt, 1640pt and full screen, with a card selected in each of the five columns — criteria 2, 3, 11, 12, 14, and 13 again. Drag a card to an inert column to confirm drop regions are unchanged; **do not** drag Backlog → To Do, To Do → In Progress or In Review → Done, all three of which genuinely spawn an agent or merge (`RuleEngine.swift:107-113`). Seed the other columns with one Refresh instead (`GitHubImport.column(for:)`)
- [x] `CaretRail.swift` plus the geometry reporter in `CardView.swift` and `BoardView.swift`. `./Scripts/build-app.sh && open -n … dist/Elliot.app` — criteria 7, 8, 9, 10, and 13 again. Use `.onGeometryChange` or `.anchorPreference(.bounds)` in a `.background`/`.overlay`, never a bare wrapping `GeometryReader` and never `matchedGeometryEffect`
- [x] Reduce motion and the accessibility pass across `BoardView`, `DetailPanelView`, `LogRows`, `MarkdownBlocks`. `grep -nE '\.animation\(|withAnimation\(|\.transition\(' ElliotKit/Sources/ElliotAppKit/*.swift` with every hit gated, then criteria 20, 21 and 22 on screen with VoiceOver, and 13 one last time
- [x] `ElliotApp.swift`, `.claude/skills/repo-profile.md` and `CLAUDE.md`: the `defaultSize` comment at lines 35-37 is now false (2618pt of content at 3 spans in a 1640pt window), so either raise the size or say the board scrolls by design; add `BoardView.swift` and `DesignSystem.swift` to the conflict hot-spots as union merges; update the test count; record the on-screen checklist as this change's verification. `grep -n 'without the board scrolling' ElliotKit/Sources/ElliotApp/ElliotApp.swift` returns nothing, `grep -n 'NavigationStack' ElliotKit/Sources/ElliotApp/ElliotApp.swift` still returns hits, and criterion 23's greps hold
















