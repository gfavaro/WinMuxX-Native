# Global pool validation — native build 13

## Single secondary desktop — native build 18

Build 18 (`d6081b9b`) fixes the carrier when a manually created secondary desktop is selected. Its workspace is absorbed into the global pool, its windows move into the existing carrier, and empty secondary extras are deleted after synchronization. Deletion intent is persisted without claiming external ownership; UUID, membership, current desktop, carrier and origin guards are rechecked before removal. Unreconciled content defers cleanup with a diagnostic, and fullscreen Spaces are excluded.

`make check` passed 793 Swift tests and 13 Python tests. Regression coverage verifies removal of empty external secondary extras, preservation of primary/fullscreen desktops and unknown content, and absorption of an occupied selected extra while returning the outgoing workspace home.

The installed, signed build consolidated the user's two ordinary secondary desktops to the existing active carrier (578), removing the empty former carrier (424). All six main-origin UUIDs and all four application windows were preserved. Five secondary selections before restart and five afterward reused the same sole secondary desktop; restart preserved the topology. The first sequence revealed Safari attached to a different logical workspace by the final probe; it was restored to its original workspace, and the second sequence explicitly verified logical owners after every selection with no change. The cause of that first observation remains unestablished. Machine-specific before/after snapshots are in the ignored `.release-native/secondary-consolidation-build18.json`.

## Repeated swaps and occupied-origin recovery — native build 17

Extended build-16 validation exercised 12 expanded Override activations, including six with Safari and ChatGPT sharing a workspace, plus four cancellations. Native membership probes, homes, active viewports and desktop count matched at the end of each group. The repeat loops used a temporary always-expanded configuration, restored byte-for-byte afterward.

A subsequent restart exposed a separate failure: an occupied hidden workspace could be pruned before AX discovered its windows, retiring its original home and allocating a new one when the saved tree was restored. Build 17 (`a626f31b`) retains physically occupied native placements/origins while their logical tree is empty; an occupant-query failure also prevents unsafe pruning. A regression test covers startup-like undiscovered windows and confirms genuinely empty owned origins remain eligible for collection. `make check` passed 790 Swift tests and 13 Python tests.

The signed build 17 was installed and two launches preserved the occupied hidden origin's UUID, all other homes, order, carriers, active workspaces, desktop count and all four native window memberships. An additional expanded Override round trip on the secondary sidebar passed with the normal compact/resting configuration, and the initial active viewports were restored. Restart assertions compare persistent project/name and native UUID identities; per-session logical IDs may legitimately be rekeyed. Local observations are in the ignored `.release-native/override-stress-build17.json`. Coordinate mouse injection remains unavailable for these panels through Computer Use, so these checks establish accessibility button activation, not physical pointer interception.

## Expanded Override follow-up — native build 16

Build 16 (`85eb62f3`) keeps a temporarily expanded sidebar open while its Override confirmation is pending and releases the collapse lock on confirmation, cancellation or view removal. Expanded confirmations have a Cancel action. The underlying section activation button is removed while the confirmation is shown, and decorative overlay layers do not intercept pointer events.

During build-15 reproduction, the temporary expansion collapsed between opening the confirmation and activating Override, invalidating its accessibility element. With `always-expanded` temporarily enabled, expanded swaps succeeded in both directions. That configuration change was restored byte-for-byte. Build 16 was tested with the original compact/resting configuration: the secondary expanded confirmation remained visible across independent inspections, Override swapped the active viewports, and Cancel dismissed the confirmation without changing native placements. Independent probes verified all four application windows, fixed homes and unchanged Space count; the initial active workspaces were restored. `make check` passed 789 Swift tests and 13 Python tests. The signed build was installed. Raw coordinate input remains unavailable for these panels in Computer Use, so physical pointer validation remains a limitation.

## Compact Override follow-up — native build 15

Build 15 (`52f7a90a`) fixes the confirmation control overflowing the collapsed sidebar: the compact variant uses a swap icon that fits the row, keeps the accessible name `Override`, and makes the whole label frame clickable. The expanded variant retains the text button and also accepts clicks throughout its padded area.

The reported no-op was not reproduced through accessibility button activation in build 14: two swaps on the secondary sidebar succeeded and native membership probes confirmed their arrivals. Its screenshot did show a clipped confirmation/button, motivating the interaction fix. Build 15 was installed with its local signature verified, and Computer Use confirmed the compact control fits. Secondary-sidebar swaps in both directions succeeded; an isolated reverse-swap check preserved fixed homes and Space count, exchanged the active viewports, and verified all four application windows' actual memberships. `make check` passed 789 Swift tests and 13 Python tests. A raw coordinate-click attempt on the secondary display was rejected by Computer Use's window-position resolution; physical pointer behavior therefore still needs user confirmation.

## Numbering follow-up — native build 14

Build 14 (`a8b444d1`) fixes inherited numeric names being displayed as desktop numbers: internal names `1, 5, 6, 3` now display as global workspaces `1, 2, 3, 4`, matching numeric selection. Custom sidebar labels remain unchanged. Menu command targets also use the global index for inherited numeric names.

An unowned principal desktop whose UUID was previously retired is adopted again, preventing an unmapped desktop from creating a Mission Control numbering gap. Owned staging desktops remain excluded. This recovery path has regression coverage; the extra empty desktop observed before the live update disappeared through the normal transient-workspace lifecycle before final validation.

`make check` passed 789 Swift tests and 13 Python tests. Live build-14 checks confirmed all four global selections, two rounds through workspaces 2–4 on the secondary monitor, the Alt+2–4 binding handlers, and restoration of the initial active workspaces. Independent native window-membership probes matched logical placements throughout, with unchanged origin UUIDs and desktop count. A graceful restart preserved order, homes, carrier, active workspaces and topology. The sidebar was inspected through Computer Use and displayed `1, 2, 3, 4`; clicking an in-use workspace displayed its expected Override action. Physical keyboard interception remains unverified.

The settled topology now has four principal origins and one secondary carrier. No manual deletion or rearrangement of Spaces was needed. The secondary carrier's Mission Control desktop number is its physical position across displays; it does not change to the global workspace number currently presented there.

Validated on 2026-10-04, macOS 27.2, with a built-in main display and an external display, separate Spaces enabled, and Accessibility/screen-capture permissions granted. App code: `6581dd46`; earlier global-pool implementation begins at `8d99fbd9`. The local signed build is 0.5.6-13.

`make check` passed: 786 Swift tests and 13 Python tests. Simulated coverage includes migration/backup, stable global numbering, reusable carriers, three-leg swaps, rollback, pending-intent restart recovery, disk failure, unknown occupants, fullscreen preflight, N+1, reboot ownership reset, rekeying, Mission Control override and preferred-display absence/return.

## Live checks

The installed app was exercised with Safari, ZapFast and Ghostty. Window arrivals were checked independently with `SLSCopySpacesForWindows`, rather than inferred from the logical model. Local machine-specific observations are saved in the ignored `.release-native/global-pool-live-validation.json`.

| Check | Result |
| --- | --- |
| Numeric window move into a hidden global workspace and back | Confirmed native arrival at origin and carrier |
| Three secondary selection round trips | Outgoing windows returned home; incoming windows reused the same carrier |
| Selecting an already-visible workspace from the other monitor | Focus changed; native placement did not |
| Three rapid explicit summon round trips | Source fallback stayed active; logical window ownership stayed correct |
| Sidebar Override | Visible workspaces swapped; origin UUIDs stayed fixed; temporary Space was collected |
| Restart | Homes, placements, memberships, active desktops and Space count survived |
| Configured Alt+4/Alt+5 handlers via `trigger-binding` | Selected the same global numbers from either monitor |
| Signature, identities, isolation, updates | Local signature verified; native bundle ID/socket/config/data; no update feed or automatic updates |
| Original checkout | Tracked and untracked file hashes matched the pre-validation fingerprint |

The settled topology held five main-display origins and one secondary carrier. Ordinary selection and the rapid summon cycles preserved their UUIDs and Space count. Pre-existing/retained empty origins remained available. A newly used N+1 origin may be allocated once; an unused transient origin can later be collected through the original workspace lifecycle.

## Fixes found during live validation

The occupant guard now distinguishes document/modal/attached content from desktop chrome, dimmers and non-cycling utility surfaces. The native app's own sidebar, preferences and warning panels do not become workspace content. Untracked application content still blocks reassignment or collection.

Hidden windows are validated through WindowServer ownership plus the process launch date; CoreGraphics can omit their window records. Transitions cancel queued focus/frame work and wait for AX queue barriers. Delayed AX focus from an outgoing hidden workspace cannot reselect it, and an explicit move focuses the incoming workspace when it hides the previous focus. A transient AX window-ID lookup failure preserves the existing tree while WindowServer confirms that the owning process still has the window.

Run only one workspace manager during validation. The original WinMuxX was briefly running during investigation and was closed before the final checks; its source checkout was not modified. No pushes were made to upstream, whose local push URL remains `DISABLED`.

## Remaining live validation

Physical keyboard interception was not established by app-targeted CUA key injection; the configured binding handlers were verified directly. Physical display disconnect/reconnect during a transition, forced-crash recovery, and native fullscreen/minimized transitions still need interactive checks. Those paths have simulated coverage, which does not establish their live behavior. The experimental private bridge remains limited to the supported macOS version.
