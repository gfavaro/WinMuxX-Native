# Global workspace pool

This replaces the per-display numbering/association model of native builds 1–5.

The original macOS main display (identified by UUID, not the focused screen) hosts one origin desktop per workspace. Secondary displays reuse one presentation desktop each. Hidden workspaces occupy their origin; a workspace active on a secondary occupies that display's presentation desktop and leaves its origin reserved and empty. The logical ID, project, layout tree, custom label and global number are independent of its current location.

Global numbers follow the origins' order on the pool display, excluding fullscreen, presentation and staging Spaces. Option+digits and numeric selection/window-movement commands use the same global lookup on every display. Sidebar/project groups retain global numbers. Selecting a workspace already active elsewhere focuses that display; summon relocates it, and sidebar override swaps active workspaces. Selecting a borrowed origin through Mission Control is an explicit override.

Switching a secondary first returns its outgoing workspace to its own origin, then moves the incoming workspace into the reusable presentation desktop. Visible swaps use three confirmed legs through a temporary secondary desktop. Origins are never exchanged. Ordinary repeated selection does not allocate more desktops. N+1 remains logical until used; newly allocated unused origins may be collected after the original lifecycle releases them. Pre-existing origins remain retained.

## Migration and persistence

`native-spaces.json` version 2 adds the preferred/effective pool display, ordered global identities, origin associations, presentation references, retained entries, active assignments and retired UUIDs. Physical references never imply ownership: ownership remains independently recorded. Before migration the app saves `native-spaces.v1-backup.json`. Existing native journals are recovered first; the virtual WinMux state is never imported.

Existing main-display desktops become origins. Workspaces already on secondary displays receive additional origins without moving the currently visible windows. Populated hidden secondary desktops are moved to their own origins after AX discovery. Empty hidden secondary desktops are preserved outside the pool. New native desktops on the pool display are adopted; temporary/retired desktops are excluded. Auxiliary occupants, ambiguous memberships and incompatible native fullscreen transfers block dispatch.

Every operation persists its original pool/placements, previous active desktops and per-window intent before native effects. Window ID, PID and launch date must still match. Arrival is independently observed before publishing placements, viewport/history and layout changes. A partial failure restores the previous physical and logical state, or leaves explicit recovery pending. MainActor session serialization protects model/native transitions and focus callbacks. AX focus/frame queues are cancelled and drained before native effects; transient AX discovery failures retain independently confirmed live windows.

When the preferred display disappears, the coordinator resolves existing origin UUIDs on the remaining main display and preserves the pool's identities. When it returns, origins already returned by macOS are reused; other origins are rebuilt in pool order while secondary active workspaces keep their current presentation desktop. Missing or ambiguous physical sources stop the affected transition; unresolved transactions pause management until recovery can be confirmed. Unowned retired desktops are retained and never reimported as duplicates.

`doctor` reports each global number, internal name, origin Space/display and current Space/display, plus presentation slots, pending recovery and deferred collection. Numeric IDs are transient; UUIDs determine physical identity.

## Verification

Simulated tests cover migration, repeated presentation reuse, fixed origins, three-leg swap, partial failure, restart intent, disk failure, unknown occupants, fullscreen preflight, N+1, reboot ownership reset, ID rekeying, global commands, Mission Control override, and pool-display absence/return. Real validation must separately confirm transfers, swaps, membership arrivals, restart, stable Space counts and unchanged unrelated desktops. Physical disconnect/reconnect during an operation and real crash recovery are not established by simulated results.

Live results and remaining checks for native build 13 are recorded in [the validation report](NATIVE_GLOBAL_POOL_VALIDATION.md).
