# Handoff notes

Notes from Haiku task runs, in the format from `docs/PLAN.md`. Newest first within each task.

## G2: point icons and names — 2026-10-15 — Opus
State: icons and names done (941b0c3 TYP points, a647437 icons, this commit names). Gate: core 295, 3 skipped.
- TYP points (QMapShack's parsePoint): day icon, label size and colour, type name. OFM: 125 types, mostly
  16-25 px; shop-like types are marked unlabelled.
- Icons: points of the level drawn, over every map, pixel for point; places left out (their names are drawn);
  no style icon: a small dot; a style icon that is fully transparent: not drawn. OFM's finest level has about
  13,000 points in 3 x 4 km of Grenoble (2,900 benches), so `MapPOI.shown` keeps the most important point per
  24-point square of the world at the zoom (labelled and named first). Squares depend only on position, so tiles
  agree, and a coarser zoom's square holds four of the next one's.
- Names: named points whose style labels them, among those shown at the view's zoom rounded down (so each name
  has its icon whichever whole zoom MapKit draws). Text right of the icon, in the style's size and colour;
  passes, summits, glaciers, national parks above street names (280), the rest under them (80); at most 400.
- `MapPlace.displayName` keeps words without a vowel in capitals (LCL, BNP Paribas).
- Checked: --render-tile at scale 1 (Grenoble z15-17; Chartreuse passes and Le Grand Som); new debug hook
  `--point-names Z/X/Y --maps A.img` prints the names the pane would write (Grand Som tile: "Le Grand Som
  (2026M)", "Col des Aures (1631M)"; Grenoble: cafés, bakeries, banks, a hotel).
Not seen on screen: the names as annotations (the user was at the machine).
Incident: a command chain ran the debug binary after a failed build, so the old binary, without the new hook,
opened the app window for about 10 minutes (killed). The library file was last written before it (10:53), so
it was not changed. Run hooks only after `swift build ... | tail -1 | grep -q 'Build complete'`, with
`--library` set to a scratch file and a time limit (`perl -e 'alarm 60; exec @ARGV' ...`).

## Route stops take heights from their legs — 2026-10-15 — Opus
State: done (this commit). Gate: core 287 tests, 3 skipped, no DIAG.
Follow-up to the course ascent fix. Read back from the Edge (`EdgeProbe fetch-course`), Test Route 1 had no
altitude at 9 of 1,072 records: the start, the end and 7 stops.
- A stop without a height takes one from the nearest shape point with a height on each side, interpolated by
  distance (`Route.fillHeight(ofStop:)`). Done when a route is made or read (so existing routes get heights
  when the library loads; written on the next save) and when a recalculated leg is put in. Not across straight
  legs. A stop's own height is kept, including one filled in from the first leg back.
- `setLeg` and the recalculator's `Request` compare stops by `isSamePlace(as:)` (id and coordinate), so a
  height filled in, a rename or a via/shaping change no longer makes a pending answer stale.
Not seen on screen (the user was at the machine): the inspector should now show heights at the stops.

## Course ascent on the Edge — 2026-10-15 — Opus
State: done (this commit). Gate: core 280 tests, 3 skipped, no DIAG.
User report: Test Route 1 sent to the Edge showed the right distance but 30,746 m of ascent instead of 885.
Cause: stops placed, inserted or moved by hand have no height (`moveStop` clears it, `setLeg` keeps only the
router's points between the stops), so the course had a "no value" altitude (0xFFFF) at every stop between
heights on the legs. The Edge counts those as real heights, so every stop was a spike.
- `FITCourse.encode` now gives every record a height when any point has one: interpolated along the distance
  between the nearest heights, the nearest one at the ends. No heights at all are still written as no value.
- The lap carries total ascent and descent (fields 21 and 22), counted as the app counts them, so the Edge can
  show the app's figure. Same encoder for File > Export FIT course.
- Tests: a hand-edited route (stops without heights, calculated legs with them), no heights, lap ascent.
Not done: the stops themselves still have no height in the library (the inspector and GPX export show none).
Giving a stop the height of the router's line at it would change the stop, which `setLeg` uses to spot stale
answers, so it needs care. Not checked on the device by Claude (never written to it): the user re-sends.

## Track DEMs: high-resolution profiles from a folder of tiles — 2026-10-14 — Opus
State: done (e809ca8 core and DEM, this commit app). Gate: 345 tests in four bundles (core 277), 3 skipped, no
DIAG. Not seen on screen (the user was at the machine); the pipeline was timed on the user's whole DEM folder.
User request: from a folder of high-resolution DEM tiles (their QMapShack/DEM: IGN RGE ALTI 5 m and 1 m `.asc`
in Lambert-93 without .prj, EU-DEM 25 m), make "local" DEM data along a track for an exact profile, as their
Python scripts (extract_tiles_for_track.py: hard links of the tiles a GPX crosses) did.
- Settings > Track DEMs: tile folder (default: the DEM model folder), corridor 50/100/200/500 m (default 100)
  (`dem.tileFolder`, `dem.corridor`).
- Track and Route menus: Build / Rebuild / Remove Track DEM; the profile pane shows "Build Track DEM" when there
  is none, progress while building, and a Points | DEM n m switch when there is one (`display.profileFromDEM`).
- `TrackDEMStore`: the tile index is kept beside the library ("DEM tile index.json"; unchanged files reused:
  4,804 tiles in 1.8 s first, much less after); a track DEM is "Track DEMs/<item id>/" with VRTs per projection
  and resolution, finest first ("1 - 1 m.vrt", "2 - 5 m.vrt", "3 - 25 m.vrt") plus "track DEM.json". The VRTs
  reference the tiles (no copy); QMapShack can open them. The library file is unchanged.
- DEM profile: every max(2 m, finest resolution) along the line (at most 40,000 samples), same distances as the
  line's profile, so cursor, picked stretch, delete and split still line up. 13 km across the Vercors: 6,495
  samples in 0.44 s. Replace Elevations from Model uses the track DEM when the item has one.
- Tiles without a projection are taken as Lambert-93 when the name says LAMB93/L93 or the coordinates fit.
Not done: the inspector's small profile still uses the points; a track DEM is not removed when its item is
deleted (harmless, a few kB of VRT).

## Sharper Garmin tiles on 1× screens — 2026-10-14 — Opus
State: done (this commit). Gate: 338 tests, 3 skipped, no DIAG.
User report: OFM looks blurry when towns start showing streets, unlike IGN. The user's screen is 1× (5120×1440).
Cause: at z14 OFM draws thousands of minor streets (v2 type 0x10000, named) as 1-pixel olive lines, and main
streets as white lines with a 3-pixel olive edge; smoothed, a 1-pixel line off the pixel grid becomes two pale
pixels. Lines up to 2 pixels (and borders up to 3) are now drawn without anti-aliasing when the tile is drawn at
1× (`crisp:` in `GarminPainter.draw`); at 2× (Retina) smoothing stays. Compared with --render-tile at --scale 1
against IGN's tile: clearly sharper. Softer Colours left as it is (off is much heavier). `--render-tile` takes
`--scale` and `--soft 0`.
Not done: MapKit still stretches tiles up to about 1.4× between zoom steps, which softens any tile, IGN's too.

## Map detail moves whole map levels — 2026-10-14 — Opus
State: done (this commit). Gate: 338 tests in four bundles, 3 skipped, no DIAG.
The Detail setting (Lowest -2 … Highest +2) was added to the wanted bits, but OFM's levels are two bits apart, so
one step changed the map at some zooms only. `[GarminMapLevel].drawnLevel(forBits:steps:)` (BaseCampIMG, tested)
takes the level the zoom calls for and moves it by whole levels, within the map's levels; past the coarsest level
nothing is drawn unless the steps reach it. Used by the drawing, the place names and the street names; overlays
still use their finest level.

## Street names; Apple's map no longer shows while Garmin tiles load — 2026-10-14 — Opus
State: done (3135695, d4aeecf, this commit). Gate: 335 tests in four bundles (core 273), 3 skipped, no DIAG.
- The Garmin overlay now replaces Apple's map (`canReplaceMapContent`), so Apple's map no longer flashes through
  while tiles load. Tiles the full Garmin maps do not cover (5 × 5 test points) get an Apple map snapshot of exactly
  that tile underneath (`FallbackTiles`, MKMapSnapshotter, NSCache). The user said Apple's map is fine where the
  Garmin maps have nothing; an OpenStreetMap fallback (3135695) was replaced by this. Names in snapshots may be cut
  at tile edges. The render-tile hook now spins the main run loop, which the snapshotter needs.
- Lines carry their label (`GarminGeometry.labelOffset`, `labelInNET`; v2 lines' label after the coordinates).
  `GarminLabels` reads road names through NET1 (offset << net1 shift; 0x400000 = none).
- `MapFeatureCache.namedLines`: named lines on the drawn level, filtered by `MapFeatureReader.nameKind` (roads,
  streets, tracks, water; not railways, tram/bus/cycle/hiking route lines, boundaries, contours).
- Core `StreetLabels.place`: pieces of one name joined end to end (not into hairpins: the halves of a dual
  carriageway turn back at their ends), a name at the middle of each stretch long enough, repeated about every
  500 points, turned along the line (never upside down). Central Grenoble at z16: 1,791 pieces → 94 names, 60 ms
  in debug.
- Drawn from 4.5 m per point (about z15) as turned text annotations, priority 100-260 (under every place name).
Not seen on screen yet: the user was at the machine, so the debug window was not opened. To check: zoom to
z15-16 in a town with the Garmin base map.

## G2 first part: place names; RGN v2 offsets fixed — 2026-10-14 — Opus
State: done (6ccda55 fix, this commit names). Gate: 329 tests in four bundles (core 267), 3 skipped, no DIAG.
User report: no text on the OFM maps (Apple's names showed while tiles loaded, then were covered); BaseCamp and
QMapShack drop town names at some zooms, and the user always wants the main places named.
- Bug fixed (6ccda55): the RGN header's v2 sections are offset then length at 0x1D/0x21 (areas), 0x39/0x3D
  (lines), 0x55/0x59 (points). The reader read 0x21/0x25 and 0x3D/0x41, so lengths were zero and every
  extended-type line and area was skipped: in OFM over 2,000 lines per cell near Grenoble, all styled by its TYP.
- `GarminLabels` (LBL string table: 6-bit, 8-bit with Windows code pages, UTF-8; POI names via LBL6), points
  (`GarminIMG.points(of:in:)`: plain, indexed and v2), both ported from QMapShack. NET road names not ported.
- Place names (`MapPlace` in core; `MapFeatureCache.places`): cities and villages (types 0x01xx-0x11xx with a
  name), read from every coarser level, the level drawn and two finer ones. Rank = the coarsest level a place is
  on (the map maker's importance; OFM: Grenoble and suburbs on level 3, villages 2, hamlets 1); ties by type.
  Same name within 3 km merged. Capital names shown in title case with small French words kept small.
- Drawn as MapKit annotations in a new bottom layer `.places`: text with a white halo, larger for higher ranks;
  `collisionMode .rectangle`, `displayPriority` 300 + 150 × rank + tie-break (below `.required`, so waypoints win).
  MapKit hides the less important of two overlapping names, so the main places always show. Read 250 ms after
  the map settles; only when the base is the Garmin maps and a map draws at that zoom.
- Debug hook `--render-tile Z/X/Y OUT.png --maps A.img [--relief S]`: draws one tile without a window.
- Seen in the debug app around Grenoble at three zooms (window captures; screen locked for most of it).
Not done: road names along lines (NET), POI icons and names (summits, huts), area names; names in saved pictures.
Incident: two debug launches took focus from the user's Airmail for a moment (the check that the user was away
ran but did not stop the script). Check the frontmost app before each launch, and stop when it is not loginwindow.

## Double-click to show an item on the map — 2026-10-14 — Opus
State: done (this commit), built; not checked by mouse (the user was using the app). Double-clicking a row of the
sidebar list or table frames the map on the whole item (`LibraryStore.zoomToSelection`, also View > Zoom to
Selection ⌘L). Via `contextMenu(forSelectionType:primaryAction:)`, so single clicks still select at once; the
rows' context menu has Zoom to Selection too.

## G4: the maps' own heights, relief shading — 2026-10-14 — Opus
State: shading done (dd8e815 reader, this commit shading). Gate: 323 tests in four bundles (core 265), 3 skipped,
no DIAG. Note: earlier HANDOFF entries quote only the core bundle's count.
- `GarminDEM` (BaseCampIMG) reads a subfile's DEM part: levels (layer 0 only), tile table, JPEG-LS tiles; heights
  in metres (feet converted), "no height" pixels as nil. Ported from GPXSee, GPL-3.0 only: NOTICE says so, and
  that the program as a whole is therefore distributed under GPL-3. `fill(_:latitudes:longitudes:level:)`
  samples a whole grid, fetching each tile once (134² points: 22 ms debug, 1.8 ms release).
- Checked against the user's EU-DEM folder (gdallocationinfo) at Grenoble, Voreppe, Chamrousse, Belledonne:
  within 12 m. OFM tiles carry four levels (0.00083°, 0.00083°, 0.00111°, 0.0037° per pixel).
- `ReliefShading` (core): Horn slopes in true metres, Lambert light from 315°/45°, GPXSee's lightening and
  square root, black with alpha. Exaggeration grows with the grid spacing (√spacing × 0.9, 1.5...12). Box blur.
- `GarminReliefRenderer` (app): per Web Mercator tile, a 128-point grid (+3 margin), blurred by 2, drawn over the
  full maps and under the overlays (contours stay crisp), only where a full map draws something, from z8.
  `MapReliefCache` actor keeps opened maps and up to 96 DEM parts.
- Map menu > Garmin maps > Relief Shading: Off, Light 0.3, Medium 0.45 (default), Strong 0.65
  (`map.reliefStrength`). Part of `GarminMapConfiguration`, so changing it redraws the tiles.
- Seen in the debug app around Grenoble at z12 and z15 (window captures only).
Not done: saved pictures and printed reports (`MapImageExport`) do not draw the shading yet; the maps' heights are
not yet used for Elevations from Model, waypoint heights or the planner (rest of G4). Once, at launch, the map
showed only the Garmin land colour at z10 with shading on; it did not happen again in three more launches.

## Toolbar tooltips, activities icon — 2026-10-14 — Opus
State: done (this commit). SwiftUI's `.help` on the buttons of the toolbar's item group never reached AppKit (the
accessibility help of every toolbar item was empty, checked with System Events). `ToolbarTooltips` holds the texts;
`ToolbarTooltipInstaller` sets them on the NSToolbarItems by label, again on each window update. After the fix all
ten items report their help. The Edge Activities icon is `figure.mixed.cardio`, not a bicycle: activities are not
only rides.

## Picked-stretch averages, select a line on the map — 2026-10-14 — Opus
State: done (this commit). Gate: 259 tests, 3 skipped, no DIAG. Checked by mouse on two 3,000-point scratch tracks.
- Profile readout: the cursor values on the first line, the picked stretch on the second, now with its average grade
  (height change end to end over the length) and its average value, weighted by distance (mean height, or mean heart
  rate, cadence, … for the sensor series). Core: profile `average(over:)` and `averageGrade(over:)`, 2 tests.
- Clicking a track or route line on the map (within 6 points) selects it, as in BaseCamp, unless the route tool or
  the measure tool is on. `MapLine.item` names the item a line draws. The sidebar list scrolls to an item selected
  elsewhere and drops the collection or name filter that would hide it.

## Profile pane, shared cursor, picked stretch on the map — 2026-10-14 — Opus
State: done (this commit). Gate: 257 tests, 3 skipped, no DIAG. Checked by mouse on a 3,000-point loop track.
User report: the profile was too small for fine work; the stretch picked on the profile was not shown on the track;
the cursor marks between profile and track were glitchy.
What changed:
- Core `LineMeasure` (Track/Route `.measure`): distances along the line as the profile measures them, the place at a
  distance (interpolated), the section of a distance range, and the distance of a place on a given segment.
  `Track.split(atDistance:)`; profile `value(at:)`, `grade(at:window:)`, `thinnedForDrawing(limit:)` (keeps the
  lowest and highest point per bucket). Tests: LineMeasureTests (8).
- The profile cursor is now a distance (`LibraryStore.profileCursor`, metres), not a coordinate. The map marker is
  placed between points, so it moves smoothly, and a loop that passes a place twice is no longer ambiguous. The
  cursor stays when the pointer leaves the chart (it used to vanish, so Split at Profile Position could never be
  clicked). Split cuts at the cursor's distance. Cleared when the selection changes.
- Both charts draw the cursor as a line and a dot.
- Hovering over the selected track or route on the map (within 8 points) moves the cursor too.
- The picked stretch is drawn on the map in magenta, over the selected line (new layer `profileRange`).
- Profile pane under the map (`ProfilePane`), for the selected track or route: drag the handle to resize (height
  kept, `display.profileHeight`); scroll up/down over the chart to zoom around the cursor, sideways to pan; Zoom
  In/Out, Zoom to Picked, Show All; Delete Selected Points, Clear, Split Here; a readout with distance, height,
  grade over 100 m, the sensor value, and the picked stretch's length, ascent and descent. Toolbar button
  "Profile" and View > Show/Hide Profile (⌥⌘P), kept in `display.profilePane`.
- Layout: the map, the route tool's bar, the profile and the device bar are a plain VStack. SwiftUI's VSplitView
  and the earlier bottom safe-area inset both left a toolbar-high gap above the profile.
Not done: the inspector keeps its small profile as well.

## Opus review of C1 and the C4 range — 2026-10-14 — Opus
State: both accepted, with fixes in this commit. Gate: 249 tests, 3 skipped, no DIAG.
C1 fixes:
- Colour values: the 16 DisplayColor names now use the classic 16-colour palette they come from (Windows' and Qt's
  named colours, which QMapShack uses), e.g. DarkRed #800000, DarkGray #808080, LightGray #C0C0C0, not web values.
- Address order: the writer put PostalCode before Country. BaseCamp's own file (Bretagne 2023.GPX) and the schema
  have City, State, Country, PostalCode. Fixed. The schema allows two StreetAddress lines: they are now read as one
  street of two lines and written back as two elements. Test added.
C4 range, checked by mouse on a scratch track (200 points, 11 km):
- Bug found: Swift Charts sets the range binding to nil when the mouse is released, so the band vanished and
  Delete Selected Points never became enabled. The picture with `--profile-range` could not show this. Fixed: nil
  from Charts is ignored; the stretch is cleared by a new Clear button, by deleting it, or by selecting another item.
- After the fix: dragging 2-5 km leaves the band; hovering still marks the map; Delete removed 56 points (200 to
  144); Undo Delete Points brought back all 200 in one step.
Lesson for pictures: a launch hook that sets state can hide a bug in how the state is set by the user.
Tool note: two processes are named BaseCampApp when the user's app bundle is running. Target System Events by unix
id, never by process name.

## C4 range — 2026-10-13 — Haiku, for Opus review
State: done, for Opus review. The drag itself was not checked, because the sandbox cannot drive a mouse drag. Opus checks it.
Commits: 28227d6 (distance values back to metres), 5298213 (range selection, delete, menu, hook)
What was checked:
- Core: `UnitFormat.distanceMeters(fromValue:_:)` converts back to metres in metric, statute and nautical (one test). The removal was tested earlier, in `PointFilterTests`.
- Picture, from a scratch copy of the track "Sensor ride" (9.82 km): with the DEBUG hook `--profile-range 2 4`, the elevation profile shows a band from 2 to 4 km, from the lowest to the highest point. "Delete Selected Points" is enabled below the chart. The layout was changed for the picture only, and restored from a backup.
- Gate: 248 tests, 0 failures, no DIAG. The release bundle was rebuilt.
Not checked (for Opus):
- The drag. The chart has both `chartXSelection(value:)` (the hover) and `chartXSelection(range:)` (the drag). Check that hover still marks the map while a range exists.
- The delete, in the running app: not clicked. The button and the Track menu item both call `LibraryStore.deleteProfileRange()`, which makes one "Delete Points" edit and clears the range. Undo should bring the points back in one step.
- Routes: the profile of a route is not pickable.
Notes:
- The picked stretch is stored in metres (`LibraryStore.profileRange`), so it stays right when the units change. It is cleared whenever the selection changes.
- It works for any series, because the axis is distance for every series.
- The band and the delete use the same distances as the profile plots (`Track.pointDistances`).
- `--profile-range FROM TO` (kilometres) is a DEBUG launch hook, for pictures only.
Open questions: none.
Next step: Opus checks the drag, the hover with a range present, and delete with undo, by mouse.

## C1 — 2026-10-13 — Haiku, for Opus review
State: done, for Opus review. The real-file test for the sensor fields waits for a BaseCamp GPX with sensor data.
Commits: bf6b16a (colours), f891991 (waypoint address and proximity), dd32c49 (sensor fields)
What was checked:
- Colours, `GPXColourTests` (6). On Bretagne 2023.GPX the reader gives tracks Blue 3, DarkBlue 4, DarkRed 1, Red 4, and the route Magenta 1. An independent XML count of the same file gives the same numbers.
- Waypoints, `GPXWaypointExtensionTests` (5). On Bretagne 2023.GPX (13 waypoints, 12 addresses, 1 phone number) and Loire 2024.gpx (9 waypoints, 9 addresses) the reader's counts match an independent XML count exactly. No file here has a proximity.
- Sensors, `GPXSensorTests` (7), with made-up readings. The real BaseCamp exports on this Mac have no sensor tags, so the sensor fields are not checked against a real file yet.
- Gate after each part: 235, 240 and 247 tests, 0 failures, no DIAG. The existing library file tests pass with the new optional `Waypoint` fields.
Notes:
- The RGB values for the 16 DisplayColor names are the usual web values, for example DarkBlue #00008B and Green #00FF00. BaseCamp's own values are not published, so check a shade in BaseCamp before relying on it.
- Power is written as `power:PowerInWatts` (PowerExtension v1), and read from that or from a plain `power` element.
- Hr, cad and atemp are written in TrackPointExtension v1, in the order atemp, hr, cad.
- A route read from GPX now keeps its colour. Before, it was dropped.
Open questions:
- The real-file test for the sensor fields: a BaseCamp GPX with heart rate, cadence, temperature or power. Please send one. An excerpt is shown to you before it is added as a fixture.
Next step: Opus reviews bf6b16a, f891991 and dd32c49. Then the C4 range selection, which is the next Haiku task.

## Opus review of C2, C4, B5c and the C1 questions — 2026-10-14 — Opus
State: C2, C4 (filter part) and B5c accepted, with three small fixes in this commit. C1 unblocked.
Checked: the diff 64c4299..aa41f62. FIT record fields 3 (heart_rate, uint8), 4 (cadence, uint8), 7 (power,
uint16) and 13 (temperature, sint8), and their invalid values, match the FIT profile. Optional fields decode from old
files (test present). Filtering keeps each segment's ends and each point's readings. Gate: 229 tests, 3 skipped, no DIAG.
Fixes:
- `Statistics.swift`: the doc comment of `ActivityStatistics` had moved onto `SeriesSummary`. Put back.
- `PrintReport.swift`: the area's base was in metres while the line was in the chosen units (wrong in feet; older bug,
  touched by C2). The base is now converted too.
- Recalculate Route now works for a route without a profile (an imported GPX route). It takes the route tool's
  profile, as BaseCamp recalculates with the current activity. The item is enabled for any selected route with legs.
  `LibraryStore.markRouteForRecalculation(_:fallbackProfile:)`.
Not a fix, noted: the Track menu items are not disabled when no track is selected; they do nothing then (as before).
Decisions:
- C1 colour: (a), not (b). BaseCamp's `DisplayColor` names are a fixed palette of 16 (Black, DarkRed, DarkGreen,
  DarkYellow, DarkBlue, DarkMagenta, DarkCyan, LightGray, DarkGray, Red, Green, Yellow, Blue, Magenta, Cyan, White;
  plus Transparent, read as no colour). Map each name to its exact RGB on read, and write the nearest name. A colour
  that came from a name gives back the same name, so (b)'s extra field buys nothing. No model change.
- C1 address and proximity: as recommended. Optional `address` (street, city, state, postal code, country, phone) and
  optional `proximity` in metres on `Waypoint`, decoded with `decodeIfPresent`. Read and write both
  (`gpxx:WaypointExtension`, Garmin's published GpxExtensions v3 schema); proximity is written only when set.
- C1 sample: do the work now against the published schemas (TrackPointExtension v1/v2: `hr`, `cad`, `atemp`; power as
  `pwr:PowerInWatts`, and also a plain `power` element as other apps write it), with made-up coordinates in the
  tests. Read by namespace under any prefix, as B5a does. Writing: `gpxtpx` v1 for hr, cad, atemp, and the power
  extension for power. The user is asked for a real file; add an excerpt test when it comes, shown to the user first.
  The plan's rule (not invented as the *only* test) is kept by that later test.
- C4 range: (a), drag across the profile. Swift Charts has `chartXSelection(range:)` on macOS 14, next to the
  hover selection already used. Draw the band (a `RectangleMark`), and add "Delete Selected Points" to the Profile
  section and the Track menu, calling `Track.removingPoints(distanceIn:)` in one undo step. The range is in display
  units: convert back to metres. Elevation series only is fine for now, any series is better. Haiku writes it; Opus
  checks the drag by mouse, since the sandbox cannot drive it.
- C4 presets: menu items are fine.
Next step: Haiku: C1 (with the GPX part of C2), then the C4 range. Opus: G4.

## C2 device check — 2026-10-13 — Haiku
State: done (a check only; no code changed)
Commits: none
What was checked:
- An Edge 1040 in MTP mode was read, not written to. The two newest rides, from 2026-10-11, were copied off it.
- An independent decoder (Python, from the public FIT format) and the app's reader (`FITActivity.read`, in a temporary test that was then removed) agree on the heart rate:
  - Ride 2026-10-11 14:12: the app has 2,847 points with heart rate, 98–172 bpm, mean 136.05. The decoder finds 2,848 records. The one missing from the app has the invalid position 0x7FFFFFFF, which the track format can't hold. The device's session summary says average 136, maximum 172.
  - Ride 2026-10-11 10:36: the app has 6,897 points, 76–157 bpm, mean 109.43. The decoder finds 6,897 records. The device's summary says 109 and 157.
- In a debug build on a scratch library, the ride was imported through the Activities sheet. The track shows 2,847 points, and the profile chart shows heart rate.
Open questions:
- A record with an invalid GPS position loses its heart rate, because a track point needs a position. Should the track keep such readings? Not changed here.
Next step: none for C2 from this check. C1 still waits for a BaseCamp GPX with sensor data.
Opus answer (2026-10-14):
- Accepted. The check against the device summaries is the real-data test C2 needed for FIT.
- Readings without a position stay dropped. A track point needs a position, it was 1 record of 2,848, and the
  heart-rate figures still match the device summary. Revisit only if laps or a time-based chart need them.
- C1 does not wait for the sample. See "Opus review of C2, C4, B5c and the C1 questions" above: build C1 now against
  the published schemas, and add the real-file test when the user sends one.

## C1 — 2026-10-13 — Haiku, for Opus review
State: blocked. Nothing is written for C1. It needs a sample and two decisions first.
Commits: none
What was checked (paths and tag counts only; no file was changed or copied):
- 243 GPX files under Documents, Downloads and Desktop. 142 have `gpxx:DisplayColor`. None has `gpxtpx:` (heart rate, cadence, temperature, power) or `gpxx:Proximity`.
- `BaseCamp_Export/All_BaseCamp.gpx` (84 MB) has no Garmin extensions at all. Its creator is "BaseCamp internal extractor for QMapShack", so it is not a BaseCamp export of extensions.
- Bretagne 2023.GPX has 13 `DisplayColor` values (Red, Blue, DarkBlue, DarkRed, Magenta), 12 `gpxx:Address` blocks and 1219 `gpxx:rpt`. St Brieuc - Roscoff.GPX, Loire 2024.gpx and Queyras.GPX are similar.
- The reader already reads `gpxx:rpt` (B5a). Nothing else in C1 is read or written yet.
Open questions:
1. A sample. No file here has sensor data, so the GPX reader cannot be checked against a real answer. The plan says to ask, not to invent one. Please send a GPX that BaseCamp wrote from a ride with heart rate, cadence, temperature or power. Coordinates in a committed test fixture would be yours, so I suggest a trimmed excerpt (about 20 points), shown to you before it is added.
2. Track and route colour. BaseCamp writes `DisplayColor` as one of a fixed set of names. Our colours are RGB. Options:
   (a) Map each name to RGB on read, and to the nearest name on write. Simple, but other colours come back as a different name.
   (b) Keep the BaseCamp name beside the RGB value, and write the name back if the colour has not changed. Exact round trip, one more field.
   Recommendation: (b).
3. Address and Proximity. `Waypoint` has no address or proximity fields. Option: an optional address (street, city, state, postal code, country, phone) and an optional proximity in metres, both decoded with `decodeIfPresent` so old files still load. Recommendation: this. Proximity has no sample in any file here, so it is left unwritten until a sample has it.
Next step: Opus decides questions 2 and 3, and the user sends the sample for question 1. Then C1 is a Haiku task again. It also completes the GPX part of C2.

## B5c — 2026-10-13 — Haiku
State: done
Commits: 8259c03
What was checked:
- Core, `Tests/BaseCampCoreTests/RouteRecalculateTests.swift` (3 tests). Marking every leg keeps every shape, so the old line stays until the router answers. A route without a profile, and a route without legs, changes nothing and returns false.
- App, on a scratch copy of the library (route "Loop": 5 stops, a Mountain bike profile, 4 legs, one leg waiting), with the debug build:
  - The Route menu is between Collection and Track. "Recalculate Route" is enabled with the route selected.
  - Clicking it marked and recalculated all four legs. Each leg's shape changed (127, 121, 143 and 94 points). Each method is now "calculated", and the stops are unchanged. The window capture shows every leg as "Calculated (Mountain bike, max 15%)".
- Gate: 229 tests, 3 skipped, 0 failures, no DIAG.
- The release bundle was rebuilt with `Tools/make-app-bundle.sh release`.
Notes:
- The menu item is disabled unless the selected item is a route with a profile and legs.
- Recalculate also clears the route's earlier failures (`RouteRecalculator.retry`), so legs the router refused are asked again.
- While legs wait, their old shape stays on the map, dashed, as the existing waiting logic draws them.
Open questions: none.
Next step: none for B5c.

## C4 — 2026-10-13 — Haiku, for Opus review
State: partial. Filtering by time or distance is done. Deleting a range by profile selection has its core function, but no way to select the range yet, because that is a design choice.
Commits: 98ebfbb
What was checked:
- Core tests, `Tests/BaseCampCoreTests/PointFilterTests.swift` (8 tests). The tests were written first and failed to compile, then the code was added.
  - `pointDistances` equals the distances the elevation profile plots, point by point, across two segments.
  - Removing a distance range drops the points inside it. A segment left empty is dropped. A range with no points returns nil.
  - Thinning every 30 s keeps points 0, 3, … 30 of 31 (one per 30 s). Thinning every 250 m keeps 0, 3, … 18, and 20 (the last point of the segment). Each segment keeps its first and last points. Points without times are kept. Heart rate stays with its point.
- Gate: build clean, 226 tests, 3 skipped, 0 failures, no DIAG.
- Picture (scratch library, track "Sensor ride"): the Edit section shows Filter Points after Simplify.
- In the running app, through the Track menu (clicked by System Events): a scratch track of 60 points, 5 s apart, with Every 10 s kept 31 points, as predicted (every second point, and the last). The saved scratch file shows 31.
- Not checked: the Edit section's Filter Points button (it calls the same store action as the Track menu), and undo of a filter. Undo follows the existing `edit`, which records a step only when the library changes.
Open questions:
- How the user selects the range for "Delete a range by profile selection". Options:
  (a) drag across the elevation profile, as BaseCamp does, then Delete (menu item). This needs one gesture and shows the band.
  (b) two marks set from the profile cursor, as "Split at Profile Position" uses it today.
  Recommendation: (a). It matches BaseCamp. It needs a click-through, because the sandbox cannot drive mouse drags on the chart. The core is ready: `Track.removingPoints(distanceIn:)` takes the profile's distance range, so the chart only has to report a range.
- Filter presets are menu items: every 5, 10 or 30 s, and every 10, 25 or 50 m. Opus may prefer a text field.
- The filter applies to tracks only. Routes have no times or readings, and are left as they are.
Next step: decide the range selection (a) or (b). Then wire the delete to the chart and add a picture of the band.

## C2 — 2026-10-13 — Haiku, for Opus review
State: done for Opus review, except the GPX sensor reading, which waits for C1. The status row stays "partial".
Commits: 8a542f8 (part 1: fields, FIT reading, statistics); d8b0aa8 (part 2: inspector and profiles)
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
