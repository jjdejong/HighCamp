# Work plan: Haiku tasks with Opus handoffs

Written 2026-10-13 from a code review of the state at commit `18731ea`.
Each task has an owner:

- **Haiku**: do it, test it, commit it.
- **Haiku → Opus review**: Haiku does it; Opus reviews the commit before the next task in the same area.
- **Opus**: Haiku must not start it. Haiku may prepare the listed inputs.

Status is kept in the table at the end. Update it in the same commit as the work.

## Rules for every task

1. **Test first.** For logic in `BaseCampCore`, `BaseCampIMG` or `BaseCampDEM`, write a failing test, then fix it. If the logic sits in the app target (`LibraryStore` etc.), move it into `BaseCampCore` first, as its own commit, so it can be tested.
2. **One task, one commit** (or a few small ones). The message says what changed and why, and ends with the attribution lines from the session instructions.
3. **Before each commit:**
   - `swift build --product BaseCampApp`
   - `IMG_TEST_PATH="/Users/jjj/Documents/SynologyDrive/QMapShack/maps/OFM-EU2026_SW_GPS.img" swift test`, all passing
   - `grep -rn DIAG Sources Tests` returns nothing
   - `git status` shows only intended files
4. **Visual changes need a picture.** For anything drawn (map, export, report), produce a PNG with the test hooks (`--map-image`, `--report-png`, or `screencapture -l <window id>`), look at it, and say in the commit body what was checked.
5. **Never:**
   - write to the Garmin device
   - delete or change the user's library (`~/Library/Application Support/BaseCampClone/Library.json`)
   - delete the `BaseCampApp` defaults domain
   - change `defaults` keys without restoring them
   - use decompiled Garmin code (clean-room rule)
6. **Stop and hand off** when any of these happens. Write a handoff note (format below) instead of pushing on:
   - the task needs a design choice the plan does not settle
   - the fix touches concurrency, actors, `Task.detached`, or MTP
   - a test fails twice for reasons not understood
   - more than about 300 changed lines, or more than 5 files outside the ones listed
   - the output "looks plausible" but cannot be checked against a known answer

### Handoff note format

Append to `docs/HANDOFF.md` and commit it:

```
## <task id> — <date> — <Haiku|Opus>
State: done / partial / blocked
Commits: <hashes>
What was checked: <tests, pictures>
Open questions: <the decision needed, options seen, recommendation>
Next step: <one concrete step>
```

---

## Phase A: small correctness fixes (Haiku)

### A1. Collections keep items through combine, split and convert. Owner: Haiku
- **Problem:** `LibraryStore.combineSelectedTracks`, `combineSelection(withTrack:)`, `splitSelectedTrackAtCursor` and `convertSelection` create items with new IDs. Collections keep the old IDs and miss the new ones.
- **Do:**
  - Add `Library` methods in `BaseCampCore` that replace an item and update collections in one step:
    - combine: the result goes where the first item was
    - split: both pieces go where the original was
    - convert: the new item takes the old one's place
  - Call `pruneCollections()` after every removal.
  - Make `LibraryStore` use these methods.
- **Accept:** core tests for each of the three operations, with the item in a collection before and the right item in it after.

### A2. Minimum zoom span. Owner: Haiku
- **Problem:** `MapKitView.Coordinator.fit` with one coordinate gives a zero-size rect, so the map zooms to maximum.
- **Do:** enforce a minimum span of about 1 km in the fit. Put the rect maths in a pure function in core and test it.
- **Accept:** test; `--select <one waypoint> --map-image` shows streets, not a single building.

### A3. Clamp viewport bounds. Owner: Haiku
- **Problem:** `reportViewport` can report latitudes beyond ±90 and longitudes beyond ±180.
- **Do:**
  - Clamp latitudes to ±85.05 and longitudes to ±180 in a pure core function used by `reportViewport`.
  - Do not attempt the 180° meridian.
- **Accept:** tests on the clamping; a world-view `--map-image` still renders.

### A4. Export aspect ratio. Owner: Haiku → Opus review
- **Problem:** `ImageProjection.init` (`MapImageExport.swift`) only adds height. When the area is taller than the picture, it must add width instead.
- **Do:**
  - Widen in whichever direction is short, and update `bounds` east and west accordingly.
  - Make `ImageProjection` internal (not private) so the test target can reach it, or move the pure maths to core.
- **Accept:**
  - tests for both shapes (wide area, tall area): a coordinate's position matches Web Mercator to within 1 px
  - one PNG of a tall selection (a north–south track) with the overlay on the roads

### A5. Tile errors do not abort the export. Owner: Haiku
- **Problem:** in `MapImageExport.fetchTiles`, a thrown network error ends the whole export.
- **Do:** catch per tile and leave the tile blank. Report the count of missing tiles in `store.errorMessage` only if more than half are missing.
- **Accept:** the code compiles; an export with network off still writes a PNG, with overlays on white.

### A6. GPX import skips bad points. Owner: Haiku
- **Problem:** in `GPX.swift`, one point with a missing or invalid lat/lon aborts the file.
- **Do:**
  - Skip that point (or waypoint) and count the skips.
  - Return the count, for example with `GPX.read(_:) -> (Library, skipped: Int)` or a separate result type. `LibraryStore.importFiles` shows "N points were skipped" when the count is above zero.
  - Also create the two `ISO8601DateFormatter`s once (static), not per point.
- **Accept:**
  - tests: a file with one bad `trkpt` among good ones imports the good ones
  - a 100k-point synthetic file imports in under 2 s in release (measure once, note it in the commit)

### A7. Test hooks only in debug builds. Owner: Haiku
- **Do:** wrap the launch-argument hooks in `BaseCampApp.swift` and `ContentView.swift` (`--library`, `--open`, `--select`, `--show`, `--map-image`, `--report-png`, `--new-collection`) in `#if DEBUG`. `--library` may stay if it is documented as a user feature; ask in a handoff note if unsure.
- **Accept:** debug build behaves as before; `swift build -c release --product BaseCampApp` compiles.

### A8. Unique collection names. Owner: Haiku
- **Do:** in `createCollection`, pick the lowest "Collection N" not already used. Put the logic in core and test it.

### A9. Elevation fill must not overwrite edits. Owner: Haiku → Opus review
- **Problem:** `LibraryStore.fillElevationsFromModel` computes on a copy, then replaces the whole item, which loses edits made meanwhile.
- **Do:**
  - Compute heights per point index.
  - Apply them inside `edit` to the current item only if the point count and coordinates are unchanged; otherwise report "The track changed while heights were being read; try again."
  - Put the apply step in core and test it.

### A10. FIT course timing. Owner: Haiku
- **Problem:** `FITCourse.encode` advances timestamps 1 s per point, which breaks the Edge's virtual partner.
- **Do:** compute timestamps from cumulative distance and an assumed speed, as a parameter with default 20 km/h. Also set the lap total timer and elapsed time from it.
- **Accept:** a test decodes the encoded file's record timestamps and checks the spacing against distance ÷ speed. **Do not send it to the device.** Opus or the user does the on-device check.

---

## Phase B: Opus only (Haiku prepares inputs where listed)

### B1. One device queue and safe transfers. Owner: Opus
- **Scope:**
  - All MTP access goes through one serial actor with one open connection.
  - Partial files are removed after a failed or cancelled upload.
  - A "Replace" path for courses: delete, then upload, with the delete only after the new file is written under a temporary name and verified, if MTP rename allows; otherwise warn the user.
  - A free-space check before map upload.
- **Haiku may:** list every call site of `MTPConnection` and `DeviceStore.*` in a handoff note. No code changes.

### B2. Map layer split. Owner: Opus
- **Scope:**
  - Replace the single `MapScene` diff with separate layers (IMG features, library lines, pins, planner, cursor and measure), each updated only when its own input changes, so hovering the profile does not rebuild 60k paths.
  - Check whether IMG area fills are hidden under tile base maps (`.aboveRoads` vs the tile overlay at `.aboveLabels`).
- **Haiku may:** record timings before the change (time from profile hover to redraw, using a temporary log) in a handoff note, then remove the log.

### B3. Library saving. Owner: Opus (design), Haiku (implementation after design)
- **Scope:**
  - Debounced background save, at least once a second while editing and on quit.
  - Rolling backups (last 5).
  - Crash-safe atomic writes.
  - Possibly a non-pretty encoder for large libraries.
- Opus writes the design in `docs/HANDOFF.md`; Haiku implements it as task B3-impl.

### B4. Planner DEM work off the main thread. Owner: Opus
- `RoutePlanner.planRoute` opens the DEM folder and samples points on the main actor. Move this to a background context without sharing GDAL handles across concurrent tasks. Decide model caching per folder.

### B5. Routes as stops plus a recalculated shape. Owner: Opus (design and core), then Haiku tasks
The largest change.
- **Opus decides:**
  - the model, for example `Route.vias` plus `Route.shape` plus routing-profile reference
  - the library file version 2 and its migration
  - GPX mapping (`rtept` = via, `gpxx:rpt` = shape)
  - the editing interactions (drag line to insert via, drag via, delete via, recalculate)
- **Opus then splits it** into Haiku tasks (migration tests, GPX mapping, inspector list, menu items) and keeps the map interaction for itself.

### B6. Release packaging. Owner: Opus
- Signed release `.app` with bundled libmtp, GDAL and PROJ data, rpath fixes, and a GPL source offer.

---

## Phase C: features (Haiku after Opus has set the shape)

### C1. Garmin GPX extensions, read and write. Owner: Haiku → Opus review
- Precondition: B5 model decided.
- Read and write:
  - `gpxx:RouteExtension`, `gpxx:TrackExtension` (DisplayColor)
  - `gpxx:WaypointExtension` (Proximity, Address)
  - `gpxx:rpt` route shaping points
  - `gpxtpx:TrackPointExtension` (hr, cad, atemp; power as `pwr` where present)
- Tests from real BaseCamp exports. **Ask the user for a sample file** in a handoff note; do not invent one as the only test.

### C2. Activity sensor data. Owner: Haiku → Opus review
- Add optional heart rate, cadence, power and temperature to `TrackPoint` (library file migration as decided in B3/B5).
- Read them from FIT records and from GPX (C1).
- Add statistics: average and maximum of each.
- Add a chart selector in the inspector. Laps are a later task.

### C3. Waypoint symbols and item colours on the map. Owner: Haiku
- Draw a small symbol per waypoint symbol (SF Symbols mapping table in one file).
- Per-track and per-route colour, stored in the model and edited in the inspector.
- PNG check required.

### C4. Track point editing and filtering. Owner: Haiku → Opus review
- Delete a range of points by profile selection.
- Filter by time interval or distance (keep a point every N s / N m).
- Moving single points comes after B2 (map layers).

### C5. Items table. Owner: Haiku
- A sortable table (name, type, length, date, ascent) as an alternative sidebar view.

### C6. IMG points and labels. Owner: Opus
- Decoder work from QMapShack sources (GPL port with attribution). Raise the 6,000-line loader cap at the same time.

### C7. Print improvements. Owner: Haiku
- Scale bar; more than one page for long items.

---

## Status

| Task | Owner | State | Commit | Notes |
|---|---|---|---|---|
| A1 | Haiku | done | f3cb911, 4c797b9 | |
| A2 | Haiku | done | a79ee4c | |
| A3 | Haiku | done | 69624f6 | |
| A4 | Haiku → Opus | reviewed | d3ebc89, 8dda86b, adb56f8 | accepted; tile flip fixed in review |
| A5 | Haiku | done | 9a72f99 | offline check by user; see HANDOFF |
| A6 | Haiku | done | 96a2d8d | |
| A7 | Haiku | done | 3f22733 | `--library` debug-only; decided in HANDOFF |
| A8 | Haiku | done | ba2332a | |
| A9 | Haiku → Opus | reviewed | fa454fe, cdc8a04 | accepted; DEM check by user |
| A10 | Haiku | done | c2028ea | on-device check by user (not sent to the device) |
| B1 | Opus | done | 8247d30 | Replace checked on the Edge with EdgeSend; in-app dialog by user |
| B2 | Opus | done | 7ffe83e, b87aa68 | hover 61 → 2.5 ms; area fills only on Apple bases |
| B3 | Opus → Haiku | todo | | |
| B4 | Opus | todo | | |
| B5 | Opus → Haiku | todo | | |
| B6 | Opus | todo | | |
| C1–C7 | see above | blocked | | after B5 / B2 |

Suggested order for Haiku: A8, A2, A3, A6, A1, A7, A5, A10, A4, A9. These run from the smallest to the ones that need review.
