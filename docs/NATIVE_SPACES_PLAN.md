# Approved native Spaces plan

## Preparation (this stage)

Create an independent public gfavaro/WinMuxX-Native repository, preserve Git ancestry and starting local recovery/appearance/investigation changes, and isolate app/CLI/socket/configuration/data/preferences/login identities. Provide a local signed build without automatic installation or updates. Keep build/test CI; remove inherited synchronization and release publication. The current app continues using virtual workspaces. No native Spaces private calls, creation, or window movement are added here.

## Next stage: global workspaces over local Spaces

Workspace identity and layout remain global. Physical macOS Spaces belong to individual displays; track workspace identity, associated Space ID, and display separately. Ordinary selection of a workspace already visible elsewhere focuses that display. Explicit summon/override requests transfer the workspace to the requested display rather than allowing reconciliation to send it back to a configured home.

For hidden workspace transfer, prepare an empty owned Space on the destination, transfer windows, confirm each association, bind and activate only after confirmation. Preserve the previously visible workspace. Retire the old Space only after confirming it is empty and owned by the app.

Swap visible workspaces between displays through an empty temporary Space: A to T, B to A's old Space, A from T to B's old Space. Confirm every step and commit bindings/history together after success. Compare this approach with direct exchange of window lists in a later prototype. Preserve logical layout/floating/focus state. Never treat dispatch success as proof of window arrival.

N+1: offer the next empty logical workspace after the populated workspaces and materialize its owned Space when needed. Leaving N+1 without opening a window must not accumulate app-owned desktops. Preserve the current lifecycle exceptions for visible workspaces, configured persistent workspaces, minimized windows, the last workspace of a project, and retained empty slots. A temporary staging Space for swap is a separate implementation concern. Keep at least one desktop on every connected display. Do not delete user-created Spaces, even when empty; do not automatically remove unowned desktops with windows.

Use asynchronous incremental planning from observed topology snapshots, serialize operations on involved displays, support retarget/cancellation without abandoning an in-flight system mutation, and confirm arrival by observation. Persist operation intent, per-window progress, bindings and recovery state. Recover partial transfers and swaps after failures/restarts/disconnects; preserve minimized, fullscreen and auxiliary windows conservatively and reconcile redocking without relying solely on periodic samples. Native recovery must not import virtual state automatically.

Tabs and new tab behavior are outside this implementation scope. Inherited tab functionality is not extended by preparation.

## Fixed reference and attribution

Reference: mikker/Dinky commit `e05ae28f3e814bbae1cf171567be14e0dcba6548`. Read [the reviewed components and limitations](DINKY_NATIVE_SPACES_REVIEW.md), including source permalinks and MIT license link. Future incorporation must retain Dinky's copyright/license and source-level notices for mimi, yabai and other origins. No external code is incorporated now. Symbol availability alone does not establish compatibility or successful operations; validate capabilities and fallback behavior per macOS version in the next stage.
