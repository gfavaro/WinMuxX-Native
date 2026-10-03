# Experimental native Spaces implementation

The native backend replaces workspace corner parking with real macOS desktop associations. Existing logical WorkspaceIds, project layout trees, sidebar controls, commands and navigation history remain the model. Inherited inactive tabs still use their existing behavior; no Space is created per tab.

## Requirements and startup

macOS 27 or later, Accessibility permission for WinMuxX-Native, and “Displays have separate Spaces” enabled. Changing that setting requires signing out and back in. The bridge checks the runtime classes/selectors and both SkyLight dispatchers before managing windows. Missing capabilities pause management with a diagnostic; the app never silently falls back to virtual workspaces. The CLI `--native-spaces-status` only reads symbols and topology and performs no mutations or permission requests.

Startup maps every existing user desktop, including empty desktops and surviving app-owned slots, to a logical workspace. Saved associations are reused without duplication; startup desktops remain available even when empty, and adoption never claims ownership of external desktops. Newly created app-owned slots still follow N+1 collection. Native fullscreen Spaces are excluded. Subsequent refreshes adopt newly created external desktops but leave unbound app-owned staging slots for collection. Newly registered windows are routed using native Space membership before startup policy/rules. Mission Control switches update the logical viewport before refresh. Manual window moves between bound desktops update their logical tree; a missing/disconnected source is reconciled as a transfer instead of merging its global identity into another workspace. Hidden workspaces retain their observed display until explicitly summoned. Topology changes and redocking do not force them back to configured homes.

## Transfers and swaps

`NativeSpaceCoordinator` plans from snapshots and Space IDs/UUIDs rather than mutable Mission Control indices. Hidden transfers create an empty destination, journal each window's original association, dispatch a batch, and check each arrival before publishing the new binding. The outgoing visible workspace is preserved. Existing fullscreen or shared/all-desktop memberships stop cross-display transfers; stable native fullscreen windows remain untouched. Minimized windows are included without unminimizing them. Unregistered auxiliary occupants block swaps and collection.

Override swaps use A → temporary T, B → old A, A → old B. Each leg is confirmed and both final bindings are saved together. Layout trees stay attached to logical workspaces. The normal N+1 lifecycle is unchanged: an unbound hidden empty slot does not create a Space, and an unused app-owned slot can be collected once its logical workspace is pruned. Existing lifecycle exceptions remain. A staging desktop is a separate concern.

An asynchronous FIFO session gate serializes model/native work across affected displays. The caller stages logical changes and suppresses focus callbacks, native focus and optimistic sidebar highlights until arrival. Failure restores tree object identity, layout, minimized ownership, MRU order, focus and viewport histories. An unstructured operation task shields dispatched work from refresh cancellation; queued requests execute after it completes. Stable refreshes do not dispatch native mutations or rewrite the operation journal.

Dock activation posts one augmented swipe at a time with asynchronous delays and topology confirmation. It targets the physical display under the pointer; a temporary pointer warp is restored only if the user did not move it. A pointer leaving that display stops further swipes. No blocking main-thread polling/run-loop pumping is retained from Dinky.

## Persistence and recovery

`~/Library/Application Support/WinMux-Native/native-spaces.json` stores bindings, boot identity, owned Space UUIDs, original active Spaces, creation intent and per-window transfer progress. Intent is atomically written and synchronized before dispatch. A failed/interrupted transfer returns each still-matching window to its original desktop and restores bindings after confirmation. Window identity includes ID, PID and application launch date. Missing original Spaces/displays leave recovery pending and management paused; reconnect and use Enable to retry. The app does not force native fullscreen windows into a desktop to complete recovery.

`native-window-state.json` holds the native restart layout; the earlier virtual `window-state.json` is not loaded. The native snapshot remains available across operation intent and is refreshed after committed synchronization. Release/debug instances cannot share the state writer concurrently because `native-spaces.lock` is held exclusively. Boot changes invalidate numeric Space ownership/transactions.

Collection requires an app-owned UUID still matching the observed desktop, no binding, no exclusive occupants (including minimized/auxiliary windows), an inactive Space, and another user desktop on its display. Occupancy/topology is rechecked at dispatch. User-created/pre-existing Spaces are never automatically removed. Unknown UUIDs and ambiguous queries retain desktops. A crash before receiving a create result may leave an unclaimed orphan; recovery never guesses ownership. Collection failure retains ownership for a later retry without undoing a committed transfer. Normal quit leaves windows on their native desktops and waits for a dispatched operation to finish.

## Provenance and validation

The Objective-C bridge is adapted from Dinky commit `e05ae28f3e814bbae1cf171567be14e0dcba6548`, with its MIT notice and source-level mimi/yabai/bobrwm attribution preserved. Notices are in [legal/native-spaces](../legal/native-spaces/README.md) and bundled app resources. The Swift coordinator, journal and integration are specific to WinMuxX-Native.

Automated tests use a simulated WindowServer: real create/move/switch/destroy calls are never executed by the test suite. Tests cover transfer, three-leg swap, partial failure, dispatch without arrival, restart recovery, reused identities, fullscreen/shared windows, auxiliary occupants, N+1, collection, disk failure, cancellation, serialized sessions, logical rollback and command/refresh integration. Local build/signature and read-only capability/topology verification complement them. Physical multi-display behavior, gesture latency and private-call success require interactive validation; symbol presence and simulated tests do not establish those results. The app is not automatically installed or started during development verification.

The native starter/reference configuration uses `alt-1` through `alt-9` to select workspaces and `alt-0` for workspace 10. Existing custom configurations retain their own bindings.
