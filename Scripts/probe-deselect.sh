#!/bin/bash
# Drives the board's "click a column's empty space to deselect" gesture and says
# whether the selection cleared.
#
#     Scripts/probe-deselect.sh <pid> [label] [column-caption]
#
# `swift test` cannot see hit testing, so this gesture has no test and never
# will. It has been rebuilt three times — on the board container (#79), on the
# row's background (#79 again), on `ColumnView` (#79), and inside the column's
# list (#158) — and two of those looked correct in review. This script is what
# tells the four arrangements apart, so it is committed rather than retyped.
#
# The read-out is the **Details** toolbar button. It is
# `.disabled(model.selectedCard == nil)`, so its `enabled` flag is a faithful
# proxy for the selection that needs no test hook in the app.
#
# ⚠️ Target the process by `unix id`, never by `process "Elliot"`. Three Elliots
# are routinely running — this worktree's, another worktree's, and the main
# checkout's — and driving by name hits whichever System Events resolves first.
# That happened during #152.
#
# ⚠️ The `cua-driver` daemon holds neither Accessibility nor Screen Recording,
# but the **shell** does: `osascript` clicks and key presses are delivered. A
# blank accessibility tree here would mean a permissions problem, not an empty
# window.
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
# Drive all four panel states — detail open/shut × analysis open/shut, toggled
# from the toolbar's own Details and Analyse buttons — plus a column seeded with
# ~15 cards so its list genuinely scrolls. That last one is the case a
# `.scrollDisabled(contentHeight <= viewportHeight)` fix cannot reach.
#
# Two knobs, because "empty space" is not the same place in the two cases:
#   CLICK_DX / CLICK_DY  offsets from the list's top-left corner.
# The default aims 80pt up from the list's bottom edge, which is the empty area
# below the last card in a short column. A full column has no such area — there
# the empty space is the `Metric.columnListPadding` strip beside the cards, so
# use `CLICK_DX=4 CLICK_DY=400`.
set -uo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,50p' "$0"
    exit 64
fi

PID="$1"
LABEL="${2:-run}"
CAPTION="${3:-Backlog}"
AX="tell application \"System Events\" to tell (first process whose unix id is $PID)"
DETAILS="to tell toolbar 1 of window 1 to get enabled of (first button whose description is \"Details\")"

osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
osascript -e 'delay 1'

osascript -e "$AX to key code 53" >/dev/null    # esc — start from a known-deselected board
osascript -e 'delay 1'
osascript -e "$AX to key code 125" >/dev/null   # down — selects the first card
osascript -e 'delay 1'
BEFORE=$(osascript -e "$AX $DETAILS")

# Find the column by its **caption**, never by index: the analysis panel is
# pinned before Backlog, so every scroll area's index moves with the panel state
# while the caption does not.
CAPPOS=$(osascript -e "$AX to tell scroll area 1 of group 1 of window 1 to get position of (first static text whose value starts with \"$CAPTION\")")
CAPX=$(echo "$CAPPOS" | cut -d, -f1 | tr -d ' ')
POS=$(osascript -e "$AX to tell scroll area 1 of group 1 of window 1 to get position of every scroll area" | tr -d ' ')
SIZ=$(osascript -e "$AX to tell scroll area 1 of group 1 of window 1 to get size of every scroll area" | tr -d ' ')

GEO=$(CAPX="$CAPX" POS="$POS" SIZ="$SIZ" awk 'BEGIN {
    n = split(ENVIRON["POS"], p, ","); split(ENVIRON["SIZ"], s, ",");
    cx = ENVIRON["CAPX"];
    for (i = 1; i <= n; i += 2) {
        if (p[i] > cx - 30 && p[i] < cx + 30) { print p[i], p[i+1], s[i], s[i+1]; exit }
    }
}')
if [ -z "$GEO" ]; then
    echo "$LABEL | no list found under caption '$CAPTION' (capX=$CAPX, scroll areas at $POS)"
    exit 1
fi

set -- $GEO
X=$(( $1 + ${CLICK_DX:-$(( $3 / 2 ))} ))
Y=$(( $2 + ${CLICK_DY:-$(( $4 - 80 ))} ))

# `click at` returns the element it hit, which is the whole diagnosis: a
# `scroll area … of scroll area …` is the column's list swallowing the tap.
HIT=$(osascript -e "tell application \"System Events\" to click at {$X, $Y}" 2>&1)
osascript -e 'delay 1'
AFTER=$(osascript -e "$AX $DETAILS")

echo "$LABEL | list=($1,$2 $3x$4) click=($X,$Y) | selected before=$BEFORE after=$AFTER | hit: $HIT"

# The claim is "the click cleared the selection", so say so in the exit code.
[ "$BEFORE" = "true" ] && [ "$AFTER" = "false" ]
