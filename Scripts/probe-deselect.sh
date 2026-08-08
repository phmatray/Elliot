#!/bin/bash
# Drives the board's "click a column's empty space to deselect" gesture and says
# whether the selection cleared.
#
#     Scripts/probe-deselect.sh <pid> [label] [caption] [right-arrow-steps]
#
# `swift test` cannot see hit testing, so this gesture has no test and never
# will. It has been moved three times — onto the board container, onto the row's
# background, onto `ColumnView` (all #79) — and reported dead a fourth time
# (#158). This script is what tells those apart, so it is committed rather than
# retyped from memory.
#
# ⛔ **The click is a real `CGEvent`, through `Scripts/realclick.swift`, and
# that is the entire point of this script existing.** `osascript -e 'tell
# application "System Events" to click at {x, y}'` is *not* a mouse click: it
# presses the accessibility element at that point. A view with
# `.accessibilityAction` answers while its `.onTapGesture` never runs, and a
# view with neither returns a plausible descriptor and does nothing. #158 was
# filed on that reading — measured here, seven states, the deselect worked in
# every one and the AX press had reported all seven as broken.
#
# The read-out is the **Details** toolbar button. It is
# `.disabled(model.selectedCard == nil)`, so its `enabled` flag is a faithful
# proxy for the selection that needs no test hook in the app.
#
# ⚠️ Target the process by `unix id`, never by `process "Elliot"`. Three Elliots
# are routinely running — this worktree's, another worktree's, and the main
# checkout's — and driving by name hits whichever System Events resolves first.
# That happened during #152. Inside the process, name the **window**: a stray
# click can open Repositories or Preflight, and then `window 1` is not the board.
#
# ⚠️ Other agent sessions on this machine steal the front mid-run. Frontmost is
# re-asserted immediately before the click, and a click that lands outside the
# window is refused rather than reported — an off-window click reads exactly
# like a dead gesture.
#
# Set-up — a scratch store, so nothing can move a card in a real repository:
#
#     rm -rf /tmp/elliot-deselect && mkdir -p /tmp/elliot-deselect
#     ./Scripts/build-app.sh
#     open -n --env ELLIOT_HOME=/tmp/elliot-deselect dist/Elliot.app   # migrates
#     # …quit it, then seed with `uuidgen` ids — a non-UUID id wedges the board
#     # on "Still starting" for ever while the status bar reads "Ready." — and
#     # point the repo at a throwaway `git init` directory so Preflight blocks
#     # it and no transition can spawn an agent. Relaunch, then:
#     ps -eo pid,command | grep "$PWD/dist/Elliot.app/Contents/MacOS/Elliot" | grep -v grep
#     Scripts/probe-deselect.sh <that pid> "detail open, analysis shut"
#
# Worth driving all of: the four panel states (detail open/shut × analysis
# open/shut, toggled from the toolbar's own Details and Analyse buttons); a
# column seeded with ~15 cards so its list genuinely scrolls; and the **last**
# column, where the panel opens leftwards — reach it with the arrow-steps
# argument so the board scrolls it into view first.
#
# Two knobs, because "empty space" is not the same place in the two cases:
#   CLICK_DX / CLICK_DY  offsets from the list's top-left corner.
# The default aims 80pt up from the list's bottom edge, which is the empty area
# below the last card in a short column. A full column has no such area — there
# the empty space is the `Metric.columnListPadding` strip beside the cards and
# the 6pt gaps between them, so use `CLICK_DX=4 CLICK_DY=400`.
#
# Exit 0 means the click cleared the selection, 1 means it did not, 3 means the
# measurement was refused rather than taken.
set -uo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,63p' "$0"
    exit 64
fi

PID="$1"
LABEL="${2:-run}"
CAPTION="${3:-Backlog}"
STEPS="${4:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AX="tell application \"System Events\" to tell (first process whose unix id is $PID)"
DETAILS="to tell toolbar 1 of window \"Elliot\" to get enabled of (first button whose description is \"Details\")"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
    osascript -e 'delay 1'
}

front
osascript -e "$AX to key code 53" >/dev/null    # esc — start from a known-deselected board
osascript -e 'delay 1'
osascript -e "$AX to key code 125" >/dev/null   # down — selects the first card
osascript -e 'delay 1'
step=0
while [ "$step" -lt "$STEPS" ]; do              # right — walk to a further column
    osascript -e "$AX to key code 124" >/dev/null
    osascript -e 'delay 1'
    step=$((step + 1))
done
BEFORE=$(osascript -e "$AX $DETAILS")
if [ "$BEFORE" != "true" ]; then
    echo "$LABEL | ⚠️  nothing selected after ↓ — the board did not hold key focus, measurement refused"
    exit 3
fi

# Find the column by its **caption**, never by index: the analysis panel is
# pinned before Backlog, so every scroll area's index moves with the panel state
# while the caption does not.
CAPPOS=$(osascript -e "$AX to tell scroll area 1 of group 1 of window \"Elliot\" to get position of (first static text whose value starts with \"$CAPTION\")")
CAPX=$(echo "$CAPPOS" | cut -d, -f1 | tr -d ' ')
POS=$(osascript -e "$AX to tell scroll area 1 of group 1 of window \"Elliot\" to get position of every scroll area" | tr -d ' ')
SIZ=$(osascript -e "$AX to tell scroll area 1 of group 1 of window \"Elliot\" to get size of every scroll area" | tr -d ' ')
WIN=$(osascript -e "$AX to get {position, size} of window \"Elliot\"" | tr -d ' ')

GEO=$(CAPX="$CAPX" POS="$POS" SIZ="$SIZ" awk 'BEGIN {
    n = split(ENVIRON["POS"], p, ","); split(ENVIRON["SIZ"], s, ",");
    cx = ENVIRON["CAPX"];
    for (i = 1; i <= n; i += 2) {
        if (p[i] > cx - 30 && p[i] < cx + 30) { print p[i], p[i+1], s[i], s[i+1]; exit }
    }
}')
if [ -z "$GEO" ]; then
    echo "$LABEL | no list found under caption '$CAPTION' (capX=$CAPX, scroll areas at $POS)"
    exit 3
fi

set -- $GEO
X=$(( $1 + ${CLICK_DX:-$(( $3 / 2 ))} ))
Y=$(( $2 + ${CLICK_DY:-$(( $4 - 80 ))} ))

# A column scrolled out of the viewport still reports its frame, off-screen.
# Clicking there hits the desktop, or another application, and comes back
# looking exactly like the gesture doing nothing.
WX=$(echo "$WIN" | cut -d, -f1); WY=$(echo "$WIN" | cut -d, -f2)
WW=$(echo "$WIN" | cut -d, -f3); WH=$(echo "$WIN" | cut -d, -f4)
if [ "$X" -lt "$WX" ] || [ "$X" -gt $((WX + WW)) ] || [ "$Y" -lt "$WY" ] || [ "$Y" -gt $((WY + WH)) ]; then
    echo "$LABEL | ⚠️  ($X,$Y) is outside the window ($WX,$WY ${WW}x${WH}) — '$CAPTION' is not scrolled into view, measurement refused"
    exit 3
fi

front
swift "$HERE/realclick.swift" "$X" "$Y"
osascript -e 'delay 1'
AFTER=$(osascript -e "$AX $DETAILS")

echo "$LABEL | list=($1,$2 $3x$4) click=($X,$Y) | selected before=$BEFORE after=$AFTER"

# The claim is "the click cleared the selection", so say so in the exit code.
[ "$AFTER" = "false" ]
