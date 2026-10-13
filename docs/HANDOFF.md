# Handoff notes

Notes from Haiku task runs, in the format from `docs/PLAN.md`. Newest first within each task.

## Opus review of C7 part 2 — 2026-10-13
State: accepted. Gate green: 167 tests, 3 skipped, no DIAG. Checked a PDF for T03 from `--report-pdf`: two A4 pages, map with the Garmin base, scale bar and statistics on page 1, profile on page 2.
- Answer: yes, make the profile taller on its own page (C7b, about 400 points).
- Letter paper: left to the user, as the note says.
- C3b and C3c are still to do, then C7b.

## C7b — 2026-10-13 — Haiku
State: done
Commits: this commit (the hash goes in the status table in the next commit)
What was checked:
- PDF from `--report-pdf` for the Ride track: page 2 has the title and the profile about 400 points high, at the same
  width as before. Page 1 is unchanged, with no profile. A report that fits on one page keeps the 170-point chart,
  since that path passes 170 and nothing else changed.
- Gate green (167 tests); release build compiles.
Notes: the chart height is now a parameter of `ProfileChart`. Page 1 uses 170 and page 2 uses 400.
Next step: none of the Haiku tasks is ready now. C1, C2 and C4 wait for B5.

## C3c — 2026-10-13 — Haiku
State: done
Commits: ea02d0b
What was checked:
- Saved picture (`--map-image`), the same framing unselected and selected: a red track with no halo when unselected, and
  with a white halo about four points wider when selected. Compared at three times magnification. Both use the same
  map position, since the selection includes the two corner waypoints that frame the library.
- On screen: the app window with the red track selected shows the white halo along both sides of the line, at three
  times magnification.
- Gate green (167 tests); release build compiles.
Notes:
- The export now uses each line's own width. It used to draw every line 3 points wide, so the report's route line, which
  is 4 points wide, now prints at 4 points. The on-screen map already used the width.
- Halos are drawn before all the selected lines, so one selected item's halo never covers another selected line.
- Selected items keep their colour, so a selected track or route is no longer drawn red. Selection is marked only by the halo.
Next step: C7b (a taller profile on page 2).

## C3b — 2026-10-13 — Haiku
State: done
Commits: 5922795
What was checked:
- Export picture (`--map-image`, Apple base) of the five symbol waypoints from `symbols.gpx`: the summit, food, flag and
  unknown-name pins show their glyphs, and the waypoint with no symbol keeps its dot. Markers are centred on their
  coordinates, as on the map.
- Report PNG for the Ride track, with two waypoints inside its map (water source, food) and one outside (summit): the two
  inside show their symbols, and the one outside is not drawn.
- Gate green (167 tests); release build compiles.
Notes:
- The report map now shows the library's waypoints that lie in its area. Before this, the report drew only the track,
  so waypoints never appeared on a report. Waypoints outside the area are not listed. Say if they should be.
- Exports draw every pin with the map's `MarkerImage`, so planner pins (the numbered via points and the steep marks) look
  the same in a picture as on the map. Label-only pins are still skipped in exports, as before.
Next step: C3c (the selection halo), then C7b.

## C7 (page breaks) — 2026-10-13 — Haiku
State: done
Commits: bc1a6cc (scale bar), and the page-break commit that records this note
What was checked:
- `ReportLayout` tests (4): the page height in report points for an A4 page with 18-point margins, a wide paper not
  enlarging the report, the profile moving to page 2 when the report is taller than a page, and staying when it fits.
- The Ride track, with `--report-png` and `--report-pdf` (a new debug hook: it saves a PDF through the print path,
  without the dialog). Page 1: title, map, scale bar and statistics. Page 2: "Ride: elevation profile" and the chart.
  The PDF has two A4 pages, rendered with PDFKit, upright and not cut.
- A route without heights: one PNG, with no split and no profile.
- Gate green (167 tests); release build compiles.
Open questions and limits:
- The split is decided on the default paper (NSPrintInfo.shared). If the print dialog picks a different paper, such as
  Letter, the split is not re-decided. Check Letter once by hand.
- If page 1 alone is taller than a page, it is cut and not split again. Its only variable part is the statistics list,
  which has up to about ten rows, so this is unlikely on A4.
- The chart on page 2 is still 170 points high. Decide whether it should be taller on its own page.
Next step: check the print dialog on Letter; then C3b and C3c, which are ready.

## Opus review of C3, C5, C7 — 2026-10-13
State: accepted. Gate green: 163 tests, 3 skipped, no DIAG.
- C5 (2a26c42): accepted; checked on screen with 20 tracks (columns, sorting, filter, List/Table control). The handoff note was missing; the commit message carries it.
- C3 (2b4a79c, 5d80925, c454ae4): accepted. The colour is optional, so old library files load, and it carries through combine, split, convert, reverse, simplify and duplicate. Follow-ups added as C3b (symbols in saved pictures) and C3c (a selection highlight that keeps the item's colour).
- C7 (bc1a6cc): the scale bar is accepted. Decision on page breaks: option (b). Title, map and statistics on page 1; the elevation profile on page 2 when page 1 would overflow. No per-kilometre table (that would be a new feature).
- Reminder for Haiku: replace "this commit" in the status table with the hash, and write a handoff note for every task.

## B2 — 2026-10-13 — Opus
State: done
Commits: 7ffe83e (feature order), b87aa68 (layers)
What changed:
- The map scene is the Garmin features plus five layers (coverage, library, planner, measure, cursor). Each redraws only when its own content changes. Overlays are inserted by rank, so the stacking is fixed: base tiles, contours, Garmin areas (on Apple maps), Garmin lines, coverage, library, planner, measure, cursor. Selected routes and tracks are drawn last within the library.
- The library layer is cached by `LibraryStore.revision` (bumped on every library change) and the selection.
- The road colours that changed between exports came from dictionary order. The Garmin groups are now one per type and style, in the map's own order (TYP draw order for areas, type order for lines, as QMapShack). 0x4A and 0x4B are never filled.
- Area fills on tile bases: they were hidden on screen (tiles are above the area level) but filled at 70% in the saved picture, which washed it out. Decision: fill Garmin areas only on Apple's maps, on screen and in the picture. Tile maps carry their own land cover.
Timings (20 tracks of 5000 points, 3917 Garmin paths, 38 cursor moves, temporary log, removed): cursor move to map updated 61 ms before, 2.5 ms after.
What was checked: IMG tests for the draw order (synthetic and real map); two OpenTopoMap exports of the same Paris view look the same; on screen, Apple base with Garmin areas, and IGN with contours, stack as listed.
Not checked: dragging a route point and the planner after the change (clicks do not reach the window from here). Both go through the same layer code as the library and are rebuilt when their content changes.
Next step: the user drags a route point and plans a route once, to confirm they still draw and update.

## B1 — 2026-10-13 — Opus
State: done
What changed:
- `MTPDevice` (BaseCampMTP) is the only way the app reaches the device: an actor on a private serial dispatch queue (libmtp blocks, so not the shared thread pool). It keeps one connection, closes it after 10 s idle so other apps can use the Edge, and closes it after any error that may mean the device has gone. Errors about the request (exists, no space, cancelled, folder missing) keep it. `status()` retries once with a new connection, for a device unplugged and plugged back.
- `MTPLink` holds the raw operations; `MTPConnection` implements it over libmtp. `MTPTransfers` holds the checked operations, so they are tested against a fake device (`Tests/BaseCampMTPTests`, 20 tests).
- Uploads: check free space first (file + 1 MB), and delete whatever arrived under the name after a failed, thrown, cancelled, short or mismatched send.
- Replace for courses, with no MTP rename (devices differ on it): upload under `NAME.xxxxxxxx.tmp` and check it, delete the old file, upload under NAME and check it, delete the temporary copy. A checked copy of the old or the new course is on the device at every step. In the app, sending a course whose file name exists asks "Replace the course on the Edge?".
- `EdgeSend --replace FILE FOLDER` does the same from the command line.
What was checked: the fake-device tests (partial, corrupted, thrown, cancelled, missing, existing, no space, the replace failure cases, no overlap across 20 concurrent calls, one connection, reopen after error, idle close). On the Edge 1040: a plain send of an existing name is refused without sending; `EdgeSend --replace` replaced BCCLONE_TEST_20261013.fit (401 → 757 bytes), left no .tmp, and the other 20 courses, QMS_MTP_Test_20261012.fit included, are unchanged. The app status bar reads the Edge through the new queue.
Not checked: the in-app Replace dialog (clicks do not reach the window from here), and cancelling a real map copy (it would write a large file to the Edge).
Next step: the user sends a course twice from the inspector and chooses Replace once.

## Opus review of phase A — 2026-10-13
State: A1–A10 accepted. Gate green: 147 tests, 3 skipped, no DIAG.
- A9: accepted. Answers: keeping a height typed during the fill is the right rule, keep it. The change inside the existing `Task` is fine (the stop rule is about adding new detached work). The route wording is fine. One fix: `Route.applyingElevations` rebuilt the route from id, name and points and would drop fields B5 adds; it now copies the route (cdc8a04).
- A4: accepted. Checked a tall OpenTopoMap export of a north–south track through Paris at full size. That check found an older bug, not Haiku's: every tile was drawn upside down inside its square, because `NSImage.draw(in:from:operation:fraction:)` ignores the flipped context. Fixed in adb56f8. After the fix, labels read correctly, the IMG Seine sits on the tile Seine, and the track follows Boulevard de Sébastopol.
- For B2: two exports of the same view drew the IMG roads in different colours (red, then grey). Check whether the TYP or draw order is chosen nondeterministically. In the same exports a pale IMG area fill washes over most of the tiles, which is the known area-fill item.
- Still with the user: A5 real offline export, A9 fill from a real DEM folder plus one undo, A10 virtual partner pace on the Edge.

## C3 — 2026-10-13 — Haiku
State: done, with follow-ups
Commits: 2b4a79c (waypoint symbols), 5d80925 (colour model), and the commit that draws the colours
What was checked:
- Symbols: the map pane of the running app with five waypoints (summit, food, flag, unknown name, no symbol). The first three show their glyphs, the unknown name shows the pin, and the one without a symbol keeps the plain dot.
- Colour: an export of a scratch library with a green track, a purple route, and a track with no colour. The green and purple lines are drawn in their colours, and the uncoloured track keeps the default orange. The export had to be changed to read the colour (it drew every line in the default colour before).
- Inspector: the Colour section for the green track, with the swatch and an enabled "Use Default Colour".
- Gate green (163 tests); release build compiles.
Open questions and follow-ups:
- The image export draws waypoints as plain dots, so its pictures do not show the symbols. The on-screen map does.
- The ColorPicker itself was not clicked through, since there is no UI automation here. The store action uses the same edit and undo path as the waypoint fields.
- GPX does not carry colours yet. C1 reads `DisplayColor`, so the colour will come from files then.
- A selected track or route is still drawn red, so a red item looks the same when it is selected.
Next step: none of the Haiku tasks is ready now. C1, C2 and C4 wait for B5. C7 waits for a decision on the page breaks (see the C7 note above).

## C7 — 2026-10-13 — Haiku
State: partial: the scale bar is done; the page breaks are open
Commits: this commit (scale bar and the report's layout)
What was checked: three tests of the round-length rule (the largest 1, 2 or 5 times a power of ten within a fraction; never above it; nothing for zero or less). Gate green (153 tests). Release build compiles. Report PNG for the Ride track (report at 2×): a "500 m" bar under the map. The map is about 4 km across: the track is about 1.5 km east–west and the projection widens the picture to 4:3, so 500 m is about 13% of the width, as expected.
Open questions: a report is about 950 points tall, and printing fits it to one page (verticalPagination .fit), so a long item comes out small. "More than one page for long items" needs page breaks, and the plan does not say where they go. Options:
- (a) Automatic pagination. Simple, but a page can end in the middle of the map or a statistics row.
- (b) Break only between sections: title, map and statistics on page 1, and the elevation profile on page 2 when page 1 would overflow. Recommended.
- (c) Also a per-kilometre table on later pages for long items. That is new content, so it needs a decision of its own.
Next step: choose (a), (b) or (c). With (b), Haiku measures the page height (A4 less the print margins) and places the break; the report PNG then shows page 1 and page 2.

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
