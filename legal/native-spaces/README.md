# Native Spaces attribution

Objective-C query, Mach-O resolution, bridged create/move/destroy and augmented gesture code in `Sources/NativeSpacesPrivate` is adapted from mikker/Dinky, fixed commit e05ae28f3e814bbae1cf171567be14e0dcba6548 (MIT, Copyright 2026 Mikkel Malmberg).

Dinky attributes the SkyLight declarations and window queries to asmvik/yabai (dd84572, MIT); augmented Dock gesture serialization and Mach-O lookup to y3owk1n/mimi (1107d3e, MIT); create operation keys to bobrwm/bobrwm (537627f, MIT). The license notices are included here and in app resources. Source comments naming those origins are preserved. No JankyBorders/GPL border code is included.

WinMuxX-Native changes: asynchronous Swift gesture timing and arrival checks; unfiltered occupancy queries for conservative deletion; runtime capability and selector checks; Space UUID identity; independent planning, journal, ownership, and model integration in Swift.
