# Handoff notes

Notes from Haiku task runs, in the format from `docs/PLAN.md`. Newest first within each task.

## Opus review of phase A — 2026-10-13
State: A1–A10 accepted. Gate green: 147 tests, 3 skipped, no DIAG.
- A9: accepted. Answers: keeping a height typed during the fill is the right rule, keep it. The change inside the existing `Task` is fine (the stop rule is about adding new detached work). The route wording is fine. One fix: `Route.applyingElevations` rebuilt the route from id, name and points and would drop fields B5 adds; it now copies the route (cdc8a04).
- A4: accepted. Checked a tall OpenTopoMap export of a north–south track through Paris at full size. That check found an older bug, not Haiku's: every tile was drawn upside down inside its square, because `NSImage.draw(in:from:operation:fraction:)` ignores the flipped context. Fixed in adb56f8. After the fix, labels read correctly, the IMG Seine sits on the tile Seine, and the track follows Boulevard de Sébastopol.
- For B2: two exports of the same view drew the IMG roads in different colours (red, then grey). Check whether the TYP or draw order is chosen nondeterministically. In the same exports a pale IMG area fill washes over most of the tiles, which is the known area-fill item.
- Still with the user: A5 real offline export, A9 fill from a real DEM folder plus one undo, A10 virtual partner pace on the Edge.

## A10 — 2026-10-13 — Haiku
State: done
Commits: c2028ea
What was checked: the encoded course's record times are decoded with FITActivity and checked against distance ÷ 20 km/h (to within half a second); a speed of 10 km/h doubles the spacing; zero speed throws. An independent decoder run on a dumped 12-point course gave records 17 s apart (about 94 m per step) and a lap whose timestamp, elapsed time (187 000 ms), timer time and distance match the last record. Gate green. Nothing was sent to a device.
Open questions: none for Haiku. `FITActivityTests` used to expect one second per point; it now expects the distance-based time, as the plan asks.
Next step: the user loads a course to the Edge and checks that the virtual partner's pace is right at the 20 km/h default.

## A9 — 2026-10-13 — Haiku, for Opus review
State: done
Commits: fa454fe
What was checked: eight core tests (all pass; five fail against an overwriting stub). Gate green. The elevation fill was not run against a real DEM, since no DEM folder is set here.
Open questions:
- Stricter than the plan: a point keeps a height edited during the fill, even when the count and coordinates still match. Confirm this is wanted.
- The change sits inside the existing `Task` in `fillElevationsFromModel`. `Task.detached` is untouched. The stop rule names `Task.detached`, so please confirm the change is acceptable.
- The route error reads "The route changed while heights were being read; try again." The plan gave only the track text.
Next step: Opus reviews fa454fe, then the user fills heights from a real DEM folder and undoes once to confirm the undo step.

## A7 — 2026-10-13 — Haiku
State: done, decision closed
Commits: 3f22733, and this note
What was checked: `swift build -c release --product BaseCampApp` compiles. The release binary contains none of the hook flags, and launched with `--map-image` it writes no picture. The debug build still writes the `--select` picture, about the same size as before.
Decision: `--library` stays inside `#if DEBUG`. Its own comment calls it a testing aid, no doc describes it as a user feature, and nothing else in the repo uses it. The debug build keeps it, and the test scripts use it there. If it is ever wanted in release, remove the `#if DEBUG` around the first part of `libraryFileURL()` in `BaseCampApp.swift`.
Open questions: none.
Next step: none.

## A5 — 2026-10-13 — Haiku
State: done, one check not run as the plan asks
Commits: 9a72f99
What was checked:
- Offline, simulated by pointing the OpenTopoMap tile host at an unresolvable name (temporary, reverted). Before the change: no picture was written. After: a picture with the overlays, no tile detail, and the missing-tile message set.
- Online with OpenTopoMap after the change: tiles still drawn.
- Gate green.
Open questions:
- The plan asks for an export with the network off. `sandbox-exec` did not stop the app's URLSession requests, so that test was not run. The unresolvable host makes URLSession fail on the same path, but it is not a real network-off check.
- `URLCache` keeps tiles between runs, so an offline test has to use a layer with nothing cached. This is a note for future testers, not a bug.
Next step: the user switches Wi-Fi off once and saves a map image on OpenTopoMap, to confirm the real offline case.

## A4 — 2026-10-13 — Haiku, for Opus review
State: done
Commits: d3ebc89 (move the projection to core, no output change), 8dda86b (tall-area fix)
What was checked: core tests for a wide and a tall area (Web Mercator placement within 1 px, and no stretch). The tall-area test failed before the fix, with a stretch ratio of 0.0053 where 1.0 is needed. Picture: a 4.4 km north–south track through central Paris, OpenTopoMap base, 1600 × 1200, rendered before and after from fresh scratch libraries. Before: the picture is stretched. After: the track runs north–south across the Seine and the IMG roads follow the OpenTopoMap streets. The vertical extent is the same before and after; the longitude range is wider after. Gate green.
Open questions:
- Tile and overlay alignment was not measured against a known feature. The river colour mixes with the IMG overlays, so pixel sampling was not reliable. Opus may want to check one feature by eye at full size.
- The Apple base (snapshot path) was not pictured after the change. It uses the same projection for its overlays.
Next step: Opus reviews 8dda86b and checks one feature in a tall export at full size.

## A3 — 2026-10-13 — Haiku
State: done
Commits: 69624f6
What was checked: viewport clamp tests. The world-view picture renders, but its reported view was about ±60° latitude, inside the limits, so the picture does not reach the clamp. The tests cover the clamp.
Open questions: none.
Next step: none.
