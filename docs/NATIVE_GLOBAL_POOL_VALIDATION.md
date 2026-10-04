# Global pool validation — native build 13

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
