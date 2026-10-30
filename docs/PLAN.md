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
- **Design done** (HANDOFF, "B3 design"). B3-impl, owner Haiku → Opus review: `LibrarySaver` in core with a serial
  queue, compact atomic writes with fsync, backups, flush at quit. This task may add that queue as designed; any other
  concurrency change is a stop condition as usual.

### B4. Planner DEM work off the main thread. Owner: Opus
- `RoutePlanner.planRoute` opens the DEM folder and samples points on the main actor. Move this to a background context without sharing GDAL handles across concurrent tasks. Decide model caching per folder.
- Done by the way (checked 2026-10-15): `planRoute` went with B5; heights for routing, Elevations from Model and
  waypoints come from `HeightSources`, and track DEM profiles from `TrackDEMStore`, each opening its own model in a
  detached task, so no GDAL handle is shared. No cache per folder: a whole lookup, models opened, takes 0.2 to 0.5 s.

### B5. Routes as stops plus a recalculated shape. Owner: Opus (design and core), then Haiku tasks
The largest change.
- **Opus decides:**
  - the model, for example `Route.vias` plus `Route.shape` plus routing-profile reference
  - the library file version 2 and its migration
  - GPX mapping (`rtept` = via, `gpxx:rpt` = shape)
  - the editing interactions (drag line to insert via, drag via, delete via, recalculate)
- **Opus then splits it** into Haiku tasks (migration tests, GPX mapping, inspector list, menu items) and keeps the map interaction for itself.
- **Decided and core done** (HANDOFF, "B5 design"): `Route` is `stops` (`RouteStop`, via or shaping) plus `legs`
  (`RouteLeg`: shape, method, profile, needs-recalculation), with `points` as the whole line. Library file version 2;
  version 1 files are read and a copy kept as `Library-v1.json`. Tasks that follow:
  - **B5a. GPX routes with stops and shape.** Owner: Haiku → Opus review. Export and import `gpxx:rpt` shape points
    and `trp:ViaPoint` / `trp:ShapingPoint`, as set out in the design.
  - **B5b. Stops in the inspector.** Owner: Haiku. Rename a stop, via or shaping, distances, leg state, route profile.
  - **B5-map. Recalculating and editing on the map.** Owner: Opus. Background recalculation of changed legs, drag
    the line to insert a stop, extend the route, changed legs drawn dashed.
  - **B5c. Route menu.** Owner: Haiku, after B5-map. Recalculate Route, Insert Stop at Cursor, and the like.

### B6. Release packaging. Owner: Opus
- Signed release `.app` with bundled libmtp, GDAL and PROJ data, rpath fixes, and a GPL source offer.
- Done 2026-10-15: `Tools/package-release.sh` writes `build/package/`: the app with 177 Homebrew libraries copied in
  and relinked (`Tools/bundle-libraries.py`), GDAL's data and PROJ's database (not its optional grids) in Resources,
  found through `GDALSetup`; licences and a list of the libraries with their source addresses in
  `Resources/Licenses`; LICENSE, NOTICE.md and an About-window credit; a zip (54 MB) and the source archive beside
  it. Signed ad hoc: there is no Developer ID, so it is not notarized and each Mac asks once before opening it.
  Runs on macOS 26 or later, the version Homebrew built the libraries for. Checked with Homebrew blocked by a
  sandbox: heights from the DEM folder (PROJ) and the maps came out as before.

---

## Phase G: the Garmin map as BaseCamp draws it (Opus, first priority)

The user asked for a BaseCamp clone; BaseCamp draws the Garmin map itself as the map. G1 replaced the IMG overlay
on other base maps. Compare each step with BaseCamp showing the same area (observe its window only; never its code).

### G1. Garmin base map. Owner: Opus. Done (577e13a, 6ae12af)
- Tiles drawn from the IMG maps in the map folder: areas in TYP draw order with bitmap patterns, lines in
  QMapShack's two passes, bordered and patterned lines; inherited levels skipped; a detail setting.

### G2. Labels and point icons. Owner: Opus
- LBL subfile: names of points, lines and areas (QMapShack's CGarminStrTbl). Line labels along roads, area and
  point labels, POI icons from the TYP point section. Replaces C6.

### G3. Map list, as QMapShack's (not BaseCamp's one map at a time). Owner: Opus
- A list of the `.img` maps in the map folder, each with: on or off; a stacking order (drag to reorder, later maps
  drawn on top, so a contour-only map can overlay a base map); a zoom range in which it is drawn (QMapShack's
  "visible between scales"); and an opacity for overlays. Kept between launches.
- Default: only the first full map on, so overlapping maps (OFM W and SW) are not drawn twice.
- Overlay maps (TRE header flag 0x02 at the POI flags byte, QMapShack's `isTransparent`, as contour maps set it) are
  drawn without a background and default to a close zoom range, where their finest level is used. (G0 blamed the
  zigzags on rough coarse levels; they were a decoder bug, fixed 2026-10-13, so the overlay defaults can be relaxed.)
- No `.gmap` support: the user's maps are published as `.img` too, with the same data (decided 2026-10-13).

### G4. The map's own elevations (DEM subfile), as BaseCamp uses them. Owner: Opus
- QMapShack ignores the DEM part of IMG maps (its heights come only from a separate DEM list); BaseCamp uses it.
  Every OFM tile has one (369 in SW, 332 in W); Utagawa France has 437.
- Decoder for the DEM subfile, from open references only: mkgmap (writes it) and GPXSee (reads it), both GPL;
  attribution in NOTICE.md as for QMapShack. Test against heights from the user's DEM folder at known points.
- Uses: relief shading under the Garmin base map; heights for "Elevations from Model", waypoint heights and the
  planner's steep-climb check where the map has them, with the DEM folder as fallback (or first, by setting).

### G5. Zoomed-out view. Owner: Opus
- Use the product's basemap (overview) tiles when zoomed out past the detailed tiles' levels.
- Closed 2026-10-15 by the user's choice: the user's maps (OFM, Utagawa) carry no overview map, only detailed tiles
  (coarsest levels 18 and 17 bits, drawn from about zoom 9 to 10), search indexes and the style. Further out, Apple
  Maps is drawn instead, which reads well there. Drawing the coarsest level further out was tried at zooms 6 to 8: a
  tangle of thick lines without names, 1 to 3 s a tile. An overview `.img` put in the maps folder would be drawn at
  its own levels by the map list, with no new code.

---

### G6. The device's contents next to the library. Owner: Opus
- As BaseCamp lists a device, and as the user's QMapShack branch loads a Garmin over MTP: the Edge's courses,
  activities and GPX files listed under the library, drawn on the map, selectable with inspector and profile,
  read-only, with Copy to Library.
- Done 2026-10-15: `DeviceStore` reads Garmin/Courses, Garmin/Activities and Garmin/GPX after the device connects,
  one file at a time, keeping copies in "Device Files" next to the library so a device connected again only has new
  or changed files read (123 files in about 15 s the first time). Items get ids from their file (`UUID(stableFrom:)`)
  so a selection survives a reload. Courses take the name in the file. Sidebar: a section per folder, collapsible,
  with an eye to show it on the map (activities off by default; a selected item is always drawn, in teal).
- Deleting from the device, asked for by the user: Delete, or "Delete from Device…" in the sidebar menu and the
  inspector, asks first, naming each file (a GPX file goes with all its items), then deletes the files with
  `MTPTransfers.delete`, which checks each is gone, and reads the device again.
- Saved locations: Garmin/Locations/Locations.fit (FIT type 8), message 29, read by `FITLocations` from the public
  FIT protocol (QMapShack reads only course points). Shown as a "Saved Locations" section; not deleted from the app,
  since one file holds them all. The user's Edge has none at present, so only tests with built files check them.

### G7. BaseCamp's organisation of My Collection. Owner: Opus
- Asked for by the user: "recreate BaseCamp's exact item organization". Learned from BaseCamp's own interface text
  (its en.lproj strings, not its code): My Collection holds every item; list folders hold lists and folders, never
  items; names unique within a folder; Unlisted Data; removing a list or folder keeps its items, or deletes those in
  no other list; Duplicate List with or without copying items; in a list, Remove from List or Delete from My
  Collection; in My Collection, deleting deletes from all lists; new items go into the selected list, and with a
  folder selected the user picks a list in it; an item shows the lists it is in.
- Done 2026-10-15: `ListFolder` and list `folderID` in core (older files load with lists at the top);
  `LibraryNode` selection; `LibraryTreeView` (tree, context menus, drag items onto lists and lists or folders into
  folders), `LibraryDialogs`, Lists menu; the map draws the selected node's items. Not from the strings, so
  unconfirmed: that BaseCamp's map shows only the selected list. Not done: Smart Lists.
- Export and send, asked for by the user: File › Export writes the selected node (list, folder, Unlisted Data, My
  Collection) as GPX, KML or CSV named after it; "Send … to Device" writes it as one GPX into Garmin/NewFiles (the
  Edge's GPSData input, as the user's QMapShack branch uploads), checked on the device, asking before replacing a
  file still waiting there. The Edge takes it in when unplugged.

### G8. The device as the user's QMapShack branch reaches it on macOS. Owner: Opus
- Asked for by the user, 2026-10-30: port what their QMapShack work (`CDeviceAccessLibMtp`, `CDeviceWatcherMac`,
  commit 1e2b91f2 of their branch) does better; keep HighCamp's checked transfers, replace staging, free-space check,
  idle close and single device actor.
- 1, listings: a failed folder listing is an error, not an empty folder (it made a delete look checked and a taken
  name look free); folder listings are remembered for the walk down and forgotten after a failure, with one retry;
  names match ignoring case; the storages are read when the connection opens and by `status()`, not for each piece of
  work. `EdgeProbe load` times a read like the app's: on the Edge 1040, 117 files (34 MB), listing 0.92 → 0.67 s,
  in all 5.2 → 4.9 s; the transfer itself is most of it.
- 2, finding the device: Garmin USB devices (vendor 0x091e) through libusb hotplug (`GarminUSBWatcher`), never
  `LIBMTP_Detect_Raw_Devices()`, which opens every unknown USB device; `MTPConnection.open(_:)` opens the one device,
  with libmtp's flags for it or after `LIBMTP_Check_Specific_Device()`. `DeviceTracker` decides when: a device
  already plugged in at launch at once, a new one 3 s after it appears (a booting Edge shows up for a moment),
  failures retried after 2.5, 5, 10, 20 and 40 s, then given up until it is plugged in again or Refresh is clicked.
  One device is open at a time. The status bar follows plugging in and out; Refresh reads the open device again.
  The command-line tools open the first Garmin device the same way; `EdgeProbe watch` prints plug events.
- 3, memory cards: `MTPDevice` keeps the storages with a Garmin folder, the one with Garmin/GarminDevice.xml first
  (the main one); `perform` gives the main one, `performOnStorages` all. Courses, activities, GPX files and maps are
  read from each, and deleted from the one they are on; sends go to the main one. A card's file copies are kept in
  "<kind>-<storage id>". Checked with the Edge 1040 (one storage, GarminDevice.xml on it); no device with a card
  was at hand, so the card is checked with the fake device only.
- Not taken from QMapShack: transfers through file descriptors (HighCamp reads each upload back instead), and
  stopping a transfer when the app quits.

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
- Moved to G2.

### C7b. Taller profile on its own page. Owner: Haiku
- When the elevation profile moves to page 2, draw it about 400 points high instead of 170, keeping the same width.
  On page 1 it stays 170. PDF check with `--report-pdf`.

### C3b. Waypoint symbols in saved pictures. Owner: Haiku
- `MapImageExport` draws waypoints as plain dots. Draw the same marker images as the map (`MarkerImage`), so pictures
  and printed reports show the symbols. PNG check.

### C3c. Selection highlight. Owner: Haiku
- A selected route or track is redrawn in red, so a red item looks unselected. Keep the item's colour and mark the
  selection with a wider pale halo under the line (white, about 4 points wider), on the map and in saved pictures.
  PNG check with a red track selected and unselected.

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
| B3 | Opus | done | | design in HANDOFF |
| B3-impl | Haiku → Opus | reviewed | eed7750 | accepted; a failed backup no longer blocks the save |
| B4 | Opus | done | (this commit) | already off the main thread since B5 and G4; no model cache needed (see B4) |
| B5 | Opus | done | 1d2f670 | design in HANDOFF; core: stops and legs, library file v2 |
| B5a | Haiku → Opus | done | 717e19b | GPX stops and shape; reviewed; user to check the import in BaseCamp and QMapShack |
| B5b | Haiku | done | 73b6393 | stops in the inspector: name, via or shaping, distance, leg state, routing profile |
| B5-map | Opus | done | a4050b2 | background recalculation, dashed waiting legs, insert handles, Option-click extends |
| B5c | Haiku | reviewed | 8259c03 | Route menu: Recalculate Route; reviewed; routes without a profile take the route tool's |
| B6 | Opus | done | (this commit) | Tools/package-release.sh: bundled libraries and data, ad hoc signature, zip and source archive; macOS 26+, not notarized (see B6) |
| G1 | Opus | done | 577e13a, 6ae12af | Garmin base map; overlay removed |
| G2 | Opus | done | 6ccda55, 0a0de0a, 7e938c4, 941b0c3, a647437, 836b62a, c984702, 6a0a74d, d555220, a297d17, (this commit) | place, street, point and area names, point icons, POI type choice (and which show below zoom 15), seen in the app; saved pictures and printed reports draw the icons and names too |
| G3 | Opus | done | bbfd0a3, 423ba46 | map list sheet; overlays use their finest level; default: first full map on |
| G0 | Opus | done | | was a decoder bug after all: the y "same sign" flag was read from the x bit when x was signed, so lines zigzagged (contours and roads); fixed 2026-10-13 with a test |
| G4 | Opus | done | dd8e815, d77e4a1, (this commit) | DEM reader (GPXSee port) and relief shading on the Garmin maps; maps' heights for Elevations from Model, new waypoints and the route recalculator (DEM folder first, setting for maps first); shading in saved pictures and printed reports |
| D1 | Opus | done | e809ca8, (this commit) | track DEMs from a folder of high-resolution tiles (user request); profile from the track DEM, in the pane and the inspector; a bar brings back a hidden profile pane; progress and result over the map, inspector section |
| G5 | Opus | done | (this commit) | closed without code: no overview map in the user's files; Apple Maps fills in when zoomed out (see G5) |
| G6 | Opus | done | (this commit) | device courses, activities and GPX files in the sidebar and on the map, read-only, Copy to Library; checked with the user's Edge 1040 |
| G7 | Opus | done | 705fd92, (this commit) | lists in nested list folders, Unlisted Data, BaseCamp's remove/delete choices, new items into the selected list; Smart Lists not done |
| BC1 | Opus | done | a059357 | File > Import BaseCamp Library: waypoints, tracks, routes (stops as via points, BaseCamp's line kept), lists and list folders; smart lists and track notes left out |
| BC2 | Opus | done | ada6f51 | library file v3: track points and route leg shapes in "Library Lines", a file per item, written only when changed; backups are folders. BaseCamp library: file 135 → 0.9 MB, save 2.5 → 0.02 s, read 2.5 → 0.06 s (release) |
| IC1 | Opus | done | 34617e4 | app icon: the user's picture (Artwork/AppIcon-source.png) on the macOS icon grid (Artwork/AppIcon.png); make-app-bundle.sh builds AppIcon.icns from it |
| G8 | Opus | done | 72ffe44, efb2515, 08efab3 | listings checked and remembered; the device found by USB hotplug, Garmin only; every storage with a Garmin folder (see G8) |
| BR1 | Opus | done | (this commit) | user report: BRouter "gone". A BRouter left by a killed test run held the port, so HighCamp's own could not start. Now Java runs under a shell that ends it when HighCamp's process is gone, and a BRouter already answering at the local address is used |
| C3 | Haiku | reviewed | 2b4a79c, 5d80925, c454ae4 | accepted; follow-ups C3b, C3c |
| C5 | Haiku | reviewed | 2a26c42 | accepted; table next to the list; `--sidebar table` hook (debug) |
| C7 | Haiku | reviewed | bc1a6cc, 69350e5 | accepted; follow-up C7b |
| C7b | Haiku | reviewed | 068596c | profile on page 2 is 400 points high; 170 on page 1 |
| C3b | Haiku | reviewed | 5922795 | saved pictures and reports draw the map's markers, with symbols |
| C3c | Haiku | reviewed | ea02d0b | selected items keep their colour, with a white halo under the line |
| C1 | Haiku → Opus | reviewed | bf6b16a, f891991, dd32c49 | accepted with fixes (palette, address order); the real-file sensor test waits for the user's GPX |
| C2 | Haiku → Opus | reviewed | 8a542f8, d8b0aa8 | reviewed and accepted; GPX sensor reading is done with C1 |
| C4 | Haiku → Opus | reviewed | 98ebfbb, 28227d6, 5298213 | accepted; range kept after release (fix), Clear button; checked by mouse with undo |
| C6 | — | moved | | to G2 |

Suggested order for Haiku now: see the open rows; C1's real-file test when the user's GPX arrives. Phase A is done. Phase G is Opus only; Haiku does not touch the map renderer or the IMG decoder.
