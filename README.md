# HighCamp

A Mac app for planning rides and hikes and managing a Garmin Edge, in the spirit of Garmin BaseCamp, with
additions. It reads Garmin `.img` maps such as OFM and Utagawa, plans routes, keeps a library of
waypoints, routes and tracks, and talks to an Edge over USB (MTP).

HighCamp is an independent project, not made, endorsed or supported by Garmin (see `NOTICE.md`).

## What it does

- **Garmin maps**: draws `.img` maps with their own styles (TYP), names, point icons and relief shading from the
  heights the maps carry; several maps and contour overlays at once, as QMapShack's map list. Apple Maps and online
  tile maps (IGN, OpenTopoMap and others) as well.
- **Library**: waypoints, routes and tracks in My Collection, organised in lists and nested list folders as in
  BaseCamp; import and export GPX, KML, TCX, FIT and CSV; a list exports as one GPX file named after it.
- **Planning**: routes from stops, calculated by HighCamp's own BRouter (installed from Settings, with the map data
  your routes need) or brouter.de, with routing profiles; steep climbs judged on terrain heights, with tunnels and
  bridges levelled; steep stretches marked on the map; legs kept straight where the router has no path.
- **Heights**: elevation profiles and statistics; heights from a folder of elevation models (GDAL) or from the maps
  themselves; high-resolution DEMs gathered along a single track.
- **Garmin Edge**: sends courses (FIT, laid out as Garmin Connect writes them) and maps; shows the Edge's courses,
  activities, saved locations and GPX files next to the library; sends a list as GPX; deletes stale files.
- **Pictures and reports**: saved map pictures and printed reports with the maps' names, icons and shading.

## Building

Needs macOS 14 or later, Swift 5.10 (Xcode or the command-line tools) and two Homebrew libraries. Routing on this Mac
also needs a Java runtime (such as Temurin) for BRouter, which HighCamp installs itself:

```sh
brew install gdal libmtp
swift build
Tools/make-app-bundle.sh release      # build/HighCamp.app, for this Mac
Tools/package-release.sh              # build/package/: a zip that runs on other Macs, and its source archive
```

The tests run with `swift test`. Those that read a real map need one: set `IMG_TEST_PATH` to a Garmin `.img` file.

## Licence

GPL version 3. Parts are ported from QMapShack (GPL-3.0-or-later) and GPXSee (GPL-3.0-only), with attribution in
each file and in `NOTICE.md`; because of GPXSee, the program as a whole is under version 3 of the GPL.
