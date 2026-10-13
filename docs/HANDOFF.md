# Handoff notes

Notes from Haiku task runs, in the format from `docs/PLAN.md`. Newest first within each task.

## C2 — 2026-10-13 — Haiku, for Opus review
State: done for Opus review, except the GPX sensor reading, which waits for C1. The status row stays "partial".
Commits: 8a542f8 (part 1: fields, FIT reading, statistics); <part 2 hash> (part 2: inspector and profiles)
What was checked:
- Core tests in `Tests/BaseCampCoreTests/SensorDataTests.swift`: FIT record fields 3, 4, 7 and 13 are read; the
  "no reading" values (0xFF, 0xFFFF, 0x7F) become nil; average and maximum per series; a route's profile is only its
  elevation; the statistics list only the series the item has.
- Test order: `testRoutesProfileOnlyTheirElevation` and `testStatisticsListTheSeriesTheItemHas`, with `Route.profile(of:)`
  and `availableSeries`, were written in one step, so they were never seen failing first. Opus may want a red run.
- Gate: build clean, 218 tests, 3 skipped, 0 failures, no DIAG.
- Picture (scratch library with a track "Sensor ride", 40 points, with heart rate, cadence, power and temperature), inspector
  window from `run-window.sh`: the Profile section with the Show picker. Elevation has a 250–400 m axis; Heart rate has a
  100–200 bpm axis. The Statistics rows show average and maximum heart rate (144 and 194 bpm), cadence (85 and 91 rpm)
  and average power (227 W). For the capture only, the Profile and Statistics sections were moved above Edit, and the
  default series was set to heart rate. The file was restored from a backup, rebuilt, and checked against that backup.
- The map pane is blank in window captures, so the map is not in the pictures.
Open questions:
- The GPX sensor reading is not done. It is part of C1 (GPX extensions).
- The FIT field numbers come from the FIT profile (record fields 3, 4, 7, 13) and the invalid values from the same
  profile. Opus may want to check them against the SDK.
- Laps are not in this task.
Next step: Opus reviews part 1 and part 2. Then C4 (Haiku → Opus), which is the next Haiku task.

## Route editing fixes after user testing — 2026-10-14 — Opus
State: done (this commit). Gate green: 211 tests, 3 skipped, no DIAG. App bundle rebuilt.
User report: dragging on a route panned the map; a planned route did not appear under Routes; nothing happened on
clicking a stop; no right-click menu; "what is the inspector?".
- Dragging: MapKit's annotation drag never started for the user (it panned instead). Now a local mouse monitor
  (`MapRouteEditing.swift`) takes left mouse-downs on the selected route before MapKit: a stop (9 pt), a leg handle
  (8 pt) or the line itself (6 pt) is followed with a tracking loop, with dashed rubber bands to the neighbours. A
  drag moves the stop or inserts one; a click selects the stop. Elsewhere the event goes on to MapKit (pan, click).
- Stop selection: `LibraryStore.selectedStop`; the stop is drawn larger and filled on the map, and its row is
  highlighted and scrolled to in the inspector. The stop list now comes right after the Route section.
- Right-click (or Control-click): on a stop, Delete Point / Make Shaping (Via) Point; on the selected route's line,
  Insert Point Here; elsewhere, New Waypoint Here, New Route from Here, Extend <route> to Here.
- Route tool: "Plan Route" no longer plans a separate line that had to be added with "Add to Library" (the user
  never saw it in the library). As in BaseCamp, the first click creates "Route n" in the library with the chosen
  profile and selects it; each click adds a stop; `RouteRecalculator` routes the legs. The bar has the profile and
  limits, Undo, New Route, Done, and a status line. `RoutePlanner` lost `via`, `plan`, `planRoute`,
  `addPlannedRoute`; the planner map layer is gone. Steep sections left after the detour passes are no longer shown.
- Checked live with the local BRouter (scratch library): drag a stop, drag a handle, drag the line, click a stop,
  both context menus, the route tool (two clicks → Route 2, calculated, listed under Routes), and panning on empty map.
- Confirmed by the user on 2026-10-14: dragging, the route tool, stop clicks and the context menus work.
- Test tool note: synthetic drags need `mouseEventDeltaX/Y` set, or MapKit blanks its overlays; and the window may
  move between runs, so read its position from `listwin` each time.

## B5-map — 2026-10-13 — Opus
State: done (this commit). Gate green: 211 tests, 3 skipped, no DIAG. App bundle rebuilt.
- `RouteRecalculator` (app): after every library change (`ContentView`, `.task(id: store.revision)`) it works through
  the legs with `needsRecalculation`, one at a time, with the route's profile and its grade limit
  (`ConstrainedRouter`, heights from the DEM folder when it covers the leg, as the planner does). The result goes in
  with `LibraryStore.applyRecalculatedLeg` → `UndoHistory.amend`: no undo step of its own, so undo takes back the move
  and its recalculation together. A stale result (stops changed meanwhile) is refused by `Route.setLeg` and the leg is
  asked for again. A failure (BRouter down, profile deleted, no route) is kept per request (route, leg, stop
  positions, profile) and not retried until the stops change or the user presses Try Again in the inspector.
- Map: legs waiting for the router are drawn dashed (also in saved pictures). The selected route has a small handle
  in the middle of each leg; dragging it inserts a stop there (`insertRouteStop`). Option-click on empty map adds a
  stop after the end of the selected route (`extendRoute`). Handles are left out of saved pictures.
- Inspector: "Recalculating n leg(s)…", or "Some legs could not be recalculated" with Try Again; the leg line says
  "Not recalculated: <reason>". A deleted profile shows as "Deleted profile" in the Routing picker.
- Core: `UndoHistory.amend`, `Route.legsWaitingForRouter`, `legLine`, `legMidpoint`, `RouteLeg.calculated(line:...)`;
  four tests.
- Checked live, debug build, scratch library, local BRouter: two waiting legs were calculated in the background and
  saved (308 and 394 shape points); a leg with a deleted profile stayed dashed with Try Again; Option-click added a
  fourth stop with a dashed leg.
- Not checked: dragging the insert handle. Synthetic drags do not reach MapKit here (a stop drag does nothing either),
  so the handle uses the same annotation drag as the stops and the user should try both.
- The design said "drag the line"; handles do the same with MapKit's own annotation drag, which pans and clicks
  leave alone. Dragging the line itself would need taking over MapKit's mouse handling.
- The local BRouter must be running (start it from the planner bar); otherwise legs fail with the planner's message.
**B5c for Haiku:** a Route menu (or the inspector's Edit section) with: Recalculate Route (mark every leg
`needsRecalculation` when the route has a profile: add `Route.markAllLegsForRecalculation()` in core, one `edit`),
Insert Stop… is not needed (handles), Remove Stop is in the inspector. Keep it to Recalculate Route plus its test.

## Opus review of B5a and B5b — 2026-10-13
State: accepted, with three import changes (this commit). Gate green: 207 tests, 3 skipped, no DIAG.
- BaseCamp repeats a stop as the first `gpxx:rpt` of its leg (with `gpxx:Subclass` children), and sometimes the next
  stop as the last. Shape points equal to either stop of their leg are now dropped on import. Test with a
  BaseCamp-style route.
- A route with shaping markers but no `rpt` now keeps its markers when every point became a stop (up to 200 points).
- Test that an undeclared prefix inside `<extensions>` still imports, as the note said; it does.
- The doc comment of `coordinate(_:)` had been pushed onto `route(id:name:points:)`; put back.
- B5b: fine. A route whose profile was deleted shows an empty Routing picker; harmless, left.
Still for the user: import an exported route into BaseCamp and QMapShack; click through the stop controls and undo.
Haiku next: C2, C4, then C1. Opus next: B5-map.

## Opus review of B3-impl — 2026-10-13
State: accepted, with one change (this commit). Gate green: 194 tests, 3 skipped, no DIAG. (The note's "242 tests"
was a miscount; the suite had 193.)
- Backup failure: decided the other way. A backup that fails no longer blocks the save. The library is written
  anyway and `onError` gets a `LibrarySaver.BackupError`, once per session, shown as "The library was saved, but its
  backup could not be made." Losing edits is worse than missing a backup. New test; the old-file test now fails the
  write with a read-only folder instead of a blocked backup.
- Quit with a change pending: not tested by hand, as noted. `flush` runs on the same queue after any `schedule`, so
  the order holds. The user's normal use will show it.
- One-line JSON: fine. `python3 -m json.tool Library.json` formats it for reading.
Haiku next: B5a, then B5b, then C2 and C4.

## B5 design — 2026-10-13 — Opus
State: decided; core done (this commit). Haiku tasks B5a and B5b are ready; B5c waits for B5-map.

**Model** (`Sources/BaseCampCore/Route.swift`), as BaseCamp keeps routes:
- `Route.stops: [RouteStop]`: the points the user places. A stop has an id, an optional name, a coordinate, an
  optional height, and `isShaping` (a shaping point steers the route; a via point, the default, is also announced
  on the device).
- `Route.legs: [RouteLeg]`: always one fewer than the stops. A leg holds `shape` (the points strictly between its
  two stops), `method` (`direct` straight line, `calculated` by the router, `imported` from a file or an old
  library), the `profileID` it was calculated with, and `needsRecalculation`.
- `Route.profileID`: the routing profile that recalculates changed legs. Nil: changed legs stay straight.
- `Route.points` is read-only: the whole line, stops and shapes in order. Statistics, drawing, FIT courses and the
  elevation profile use it unchanged.
- Changes go through `moveStop`, `removeStop`, `insertStop`, `updateStop` (name and kind only), `setLeg` (a leg
  the router calculated, taken only while its two stops are unchanged), `replacingPoints` (same number of points,
  used for heights), `reversed`, `simplified` (shapes only; stops are kept, as BaseCamp keeps via points).
- A stop that moves, is removed or is inserted makes its legs straight and, when the route has a
  profile, `needsRecalculation`.

**From a list of points** (`Route(name:points:)`: GPX routes without shape points, version 1 libraries, track to
route): up to 200 points, every point is a stop and the legs are straight (routes clicked by hand). More, the ends
and the named points are stops, and the points between are imported legs (planned or downloaded routes, which
would otherwise get thousands of stops).

**Planned routes** (`Route.planned`): the clicked points are the stops; the planned line is cut where it passes each
stop (first point within 30 m after the previous cut, else the nearest), and each stop is moved onto the line.

**Library file version 2.** A route is stored as `stops`, `legs`, `profileID`. A version 1 file is read by turning
`points` into stops and legs as above. The first time the app opens a version 1 file it copies it, once, to
`Library-v1.json` next to it, because the next save writes version 2, which older builds cannot read. New optional
fields elsewhere (C2's sensor data on `TrackPoint`) need no version change: missing keys decode as nil.

**GPX (task B5a)**, Garmin's extensions as BaseCamp writes them:
- Namespaces on `<gpx>`: `xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3"`,
  `xmlns:trp="http://www.garmin.com/xmlschemas/TripExtensions/v1"`.
- One `<rtept>` per stop, with `ele` and `name` as now, then
  `<extensions>`, `<trp:ViaPoint/>` or `<trp:ShapingPoint/>`, and `<gpxx:RoutePointExtension>` holding one
  `<gpxx:rpt lat=".." lon=".."/>` per shape point of the leg that starts at this stop. The first and last stops are
  always written as via points, which Garmin requires.
- Import: `gpxx:rpt` inside a `rtept` becomes the shape of the leg after it, method `imported`; `trp:ShapingPoint`
  sets `isShaping`. A route with no `rpt` at all keeps today's path, `Route(name:points:)`.
- `gpxx:rpt` has no height, so shape heights are lost on a round trip. Say so in the commit; "Elevations from Model"
  puts them back.
- Tests: round trip of a planned route (stops, shaping flag, shape coordinates to 1e-7°); a file with `rpt`; a file
  without (unchanged behaviour); namespace prefixes other than `gpxx` (match on the namespace URI if the parser makes
  that easy, else on the local name).
- Check by the user: import an exported route into BaseCamp and QMapShack. Write it in the handoff note; do not open
  BaseCamp yourself for this.

**Inspector (task B5b):**
- The stops list (already there, with delete) gets: an editable name (one undo step per field, coalesced as the
  waypoint name is), a Via / Shaping picker (first and last stops fixed to Via), and the distance from the start.
- Between two stops, one secondary line for the leg: "Calculated (profile name)", "Straight", "Imported", or
  "Waiting to be recalculated".
- In the route details: a "Routing" picker, None (straight lines) or one of the profiles, which sets `profileID`. It
  does not recalculate anything by itself.
- New `LibraryStore` calls: `renameRouteStop`, `setRouteStopShaping`, `setRouteProfile`, each one `edit`.

**Map and recalculation (B5-map, Opus):** a recalculator that runs changed legs through `ConstrainedRouter` with the
route's profile in the background and puts them in with `setLeg` without a new undo step (`UndoHistory` gets a way
to replace the current value); drag the line to insert a stop; click past the end to extend; changed legs dashed.
Then B5c (Haiku): menu items over these calls.

## B3 design — 2026-10-13 — Opus
State: decided. Task B3-impl, owner Haiku → Opus review.

Today every change calls `LibraryFile.save` on the main thread, pretty-printed, and there are no backups. Do this:

1. **`LibrarySaver`**, new, in `Sources/BaseCampCore/LibrarySaver.swift` so it can be tested. A final class,
   `@unchecked Sendable`, all state behind one private serial `DispatchQueue`. This queue is allowed for this task.
   - `init(fileURL:backupFolder:idleDelay: = 0.5, maximumDelay: = 1.0, backupInterval: = 1800, keptBackups: = 5)`.
   - `schedule(_ library: Library)`: keeps the newest value. The write happens `idleDelay` after the last call, but
     never later than `maximumDelay` after the first unsaved change (so at least once a second while editing).
   - `flush() throws`: writes the pending value now, synchronously (`queue.sync`). Nothing pending: does nothing.
   - `onError: (@Sendable (Error) -> Void)?` for scheduled writes that fail; the value stays pending and is tried
     again at the next `schedule` or `flush`.
2. **Writing** (`LibraryFile.save`): encode with `.sortedKeys` only, no pretty printing. Write to
   `Library.json.saving` in the same folder, `FileHandle.synchronize()`, then `rename(2)` it over `Library.json`.
   On any failure, remove the `.saving` file and leave `Library.json` as it was. Reading is unchanged (both layouts
   are JSON).
   - At launch, a leftover `Library.json.saving` (a crash mid-write) is deleted, never read.
3. **Backups** in `Backups/` next to the library file (so a `--library` test file gets its own):
   - Before the first write of a session, copy the existing file to `Backups/Library-yyyyMMdd-HHmmss.json`.
   - After that, again before a write when the newest backup is older than `backupInterval`.
   - Keep the newest `keptBackups` by name; delete older ones. Touch nothing outside `Backups/` (`Library-v1.json`
     and `Library-unreadable-*.json` stay).
4. **Wiring** in `LibraryStore`: `save()` becomes `saver.schedule(library)`. Errors reach `errorMessage` on the main
   actor, once per run of failures: shown for the first failure, then again only after a write has succeeded.
   At quit, `BaseCampApp` already listens for `willTerminateNotification` (it stops BRouter there): also call a new
   `store.flushSaving()`, which calls `saver.flush()` and logs a failure to stderr.
5. **Tests** (core, temporary folders, short delays such as 0.05 and 0.2 s, waits with expectations):
   - 20 `schedule` calls in a burst give one or two writes, and the file holds the last library.
   - Calls every 0.05 s for 1 s with `maximumDelay` 0.3 give at least two writes during the burst.
   - `flush` writes at once; `flush` with nothing pending writes nothing.
   - A failing write (a directory where the file should be) calls `onError` and leaves no `.saving` file; the old
     file is unchanged when there was one.
   - A leftover `.saving` file is removed and not read.
   - Backups: one before the first write; none again within the interval; at most `keptBackups` kept, newest kept.
   - The written file has no pretty-printing newlines and loads back equal.
6. **Measure and note** in the handoff: encode and write time for a library of 50 tracks of 20 000 points, before
   (pretty) and after (compact), and both file sizes.
7. **Stop** if `UndoHistory` or the edit flow would have to change, or if the library file version would.

## Opus review of C3b, C3c, C7b — 2026-10-13
State: accepted. Gate green: 167 tests, 3 skipped, no DIAG. Checked a saved picture with a selected track on the Garmin base: the white halo shows on both sides of the line.
Found while checking, not from Haiku's work:
- Every map in the folder is drawn, stacked. At Lans-en-Vercors that is OFM SW, Utagawa France and three contour maps on top of each other, which looks wrong (Utagawa's forest over OFM's, olive streets over white ones). OFM SW alone is clean. G3 (the map list) moves ahead of G2.
- `Isere_contours_20m.img` decodes with spike lines across its contours. QMapShack draws it correctly, so it is a decoder bug: new task G0.
Haiku: no task is ready now. C1, C2 and C4 wait for B5.

## Opus review of C7 part 2 — 2026-10-13
State: accepted. Gate green: 167 tests, 3 skipped, no DIAG. Checked a PDF for T03 from `--report-pdf`: two A4 pages, map with the Garmin base, scale bar and statistics on page 1, profile on page 2.
- Answer: yes, make the profile taller on its own page (C7b, about 400 points).
- Letter paper: left to the user, as the note says.
- C3b and C3c are still to do, then C7b.

## C7b — 2026-10-13 — Haiku
State: done
Commits: 068596c
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

## B5b — 2026-10-13 — Haiku
State: done
Commits: 73b6393
What was checked:
- Six `RouteStopsTests`: the distance from the start to each stop follows the line, and the last stop's distance is the
  route's length; a route with no stops has none; the first and last stops cannot be shaping points, and setting the
  kind of a missing stop changes nothing; a leg is described as straight, calculated with its profile, imported, or
  waiting for recalculation.
- Picture of the inspector for a scratch route with every leg state (window capture, route selected). Each stop shows
  its name, via or shaping, distance and height. Under each stop, its leg: "Calculated (Mountain bike, max 15%)",
  "Imported", "Waiting to be recalculated", and "Straight". The routing picker shows the profile.
  The stop list is below the fold, and synthetic scrolling does not reach the app in this session. So for the picture
  I moved the list above the other sections for one build, and then restored the layout.
- Gate green: 205 tests, 3 skipped, no DIAG. The app bundle was rebuilt with `Tools/make-app-bundle.sh release`.
Decisions:
- The name field's placeholder is "Point N". The coordinate placeholder wrapped over five lines in the narrow
  inspector. A stop with no name shows its number.
- The name is set per keystroke, one undo step per stop, as waypoint names are. Nothing is trimmed while typing.
- The first and last stops show a disabled picker set to Via, and the model enforces that too (`Route.setShaping`).
- Choosing a routing profile only sets the route's profile. Nothing is recalculated; B5-map does that.
- Three store calls, each one `edit`: `renameRouteStop`, `setRouteStopShaping`, `setRouteProfile`.
Not checked:
- Clicking through the controls: typing a name, changing a kind, choosing a profile, and undo. There is no UI automation
  here, so please try these in the app. Rename a stop and undo once: the whole name should go back.
- A list with many stops: the list scrolls within 420 points. Not tried with many stops.
Next step: Opus reviews this commit. Then C2 and C4 (Haiku → Opus). B5c waits for B5-map.

## B5a — 2026-10-13 — Haiku, for Opus review
State: done
Commits: 717e19b
What was checked:
- Five `GPXRouteTests`: a planned route (start, shaping point, end, with shape points in both legs) round trips, with
  names, via and shaping flags, and shape coordinates to 1e-7 degrees; shape heights are absent after the round trip, and
  the legs come back imported. The writer's markers: two via points, one shaping point, five `gpxx:rpt`, and both Garmin
  namespaces declared on `<gpx>`. The first and last stops are always via points. A file with shape points under other
  prefixes (`g:`, `t:`) reads the same. A file without shape points reads as plain points, as before.
- Gate green: 199 tests, 3 skipped, no DIAG. The app bundle was rebuilt with `Tools/make-app-bundle.sh release`.
- Sample written with the real writer, a three-stop route with shape points in both legs:
  ```
  <rte><name>Sample way out</name>
    <rtept lat="45.5000000" lon="6.2500000"><name>Start</name><extensions><trp:ViaPoint/>
      <gpxx:RoutePointExtension><gpxx:rpt lat="45.5200000" lon="6.2600000"/><gpxx:rpt lat="45.5500000" lon="6.2700000"/></gpxx:RoutePointExtension>
    </extensions></rtept>
    <rtept lat="45.6000000" lon="6.3000000"><name>Pass</name><extensions><trp:ShapingPoint/>
      <gpxx:RoutePointExtension><gpxx:rpt lat="45.6300000" lon="6.3200000"/></gpxx:RoutePointExtension>
    </extensions></rtept>
    <rtept lat="45.7000000" lon="6.3500000"><name>End</name><extensions><trp:ViaPoint/></extensions></rtept>
  </rte>
  ```
Decisions and open questions:
- The reader now processes XML namespaces for every GPX file, so the Garmin extensions are matched by URI, whatever
  prefix a file uses. Element names are then local names. A file with an undeclared prefix still imports, so no file
  that the old reader took is refused.
- On import, the first and last stops are forced to via points, as on export. The file's own marker is not kept there.
- A route with shaping markers but no `rpt` is read as plain points, as the design says, so its shaping markers are lost.
- `gpxx:rpt` has no height, so shape heights are lost on a round trip. "Elevations from Model" puts them back.
- The shape points of the last stop have no leg after them, so they are dropped on import.
- Check by the user: import the sample route into BaseCamp and into QMapShack, and say what each shows. I have not
  opened BaseCamp.
Next step: Opus reviews this commit. Then B5b (Haiku, the inspector), then C2 and C4.

## B3-impl — 2026-10-13 — Haiku, for Opus review
State: done
Commits: eed7750
What was checked:
- Nine tests of `LibrarySaver` in temporary folders, with short delays: a burst of 20 changes gives one or two writes
  and the last value; steady changes give at least two writes within the maximum delay; `flush` writes at once and
  writes nothing when nothing is pending; a failed write is reported once and leaves no `.saving` file; a failed
  write leaves the old file as it was; a leftover `.saving` file is removed and not read; the first write backs up
  the existing file and later writes do not within the interval; only the newest five backups are kept; the file is
  compact and loads back equal. The `LibraryFile` tests still pass.
- Gate green: 242 tests passing, 3 skipped, no DIAG. The app bundle was rebuilt with `Tools/make-app-bundle.sh release`.
- App, on a scratch library (never the user's): an import wrote `Library.json` compact, with no newlines and no backup
  (nothing to copy yet). A second launch with one change made one backup, `Backups/Library-yyyyMMdd-HHmmss.json`,
  which equals the first version, and `Library.json` had the change. No `.saving` file was left.
- Measured in release: 50 tracks of 20 000 points (one million points).
  - Before (pretty printed): encode 2.17 s, write 0.07 s, file 224 MB.
  - After (compact, synced, atomic): encode 2.10 s, save 2.11 s (encoding included), file 94 MB.
  The encoding time is the same, but it now runs on the saver's queue, not the main thread.
Decisions and open questions:
- A backup that fails blocks the save, and the failure is reported. The alternative is to save anyway and report only
  the backup failure. Opus, decide which.
- The quit flush (`flushSaving` in the `willTerminate` handler) is wired in, and `flush` is tested. I did not exercise
  a quit with a change still pending, since the timing is too tight to reproduce by hand.
- The library file is now one line of JSON. Anyone who reads it by hand will need a formatter.
- The save uses only one queue: `LibrarySaver`'s own serial queue, as the design allows. Nothing else changed in
  concurrency, `UndoHistory`, the edit flow or the file version.
Next step: Opus reviews this commit. Then B5a (Haiku → Opus) and C2 and C4 (Haiku → Opus), which are unblocked.

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
