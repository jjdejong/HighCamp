# Notices

HighCamp is free software, licensed under the GNU General Public License version 3 or later.
See `LICENSE`.

HighCamp is an independent project, not made, endorsed or supported by Garmin. Garmin, BaseCamp and Edge are
trademarks of Garmin Ltd. or its subsidiaries; they are named only to say which software HighCamp works like and
which devices it works with.

## Code from other projects

- The Garmin map readers in `Sources/BaseCampIMG/` are ported from QMapShack, Copyright (C) 2008-2014
  Oliver Eichler and contributors, licensed under the GNU General Public License version 3 or later:
  - `GarminIMG.swift`: `src/qmapshack/map/CMapIMG.cpp`, `src/qmapshack/map/CMapIMG.h`,
    `src/qmapshack/helpers/Platform.h`.
  - `GarminRGN.swift`: `src/qmapshack/map/CMapIMG.cpp`, `src/qmapshack/map/garmin/CGarminPolygon.cpp`,
    `src/qmapshack/map/CMapIMG.h`.
  - `GarminTyp.swift`: `src/qmapshack/map/garmin/CGarminTyp.cpp`, and the polygon draw order from
    `src/qmapshack/map/CMapIMG.cpp`.
  - `GarminLabels.swift`: `src/qmapshack/map/garmin/IGarminStrTbl.cpp`, `CGarminStrTbl6.cpp`,
    `CGarminStrTbl8.cpp`, `CGarminStrTblUtf8.cpp`, and the LBL header from `src/qmapshack/map/CMapIMG.h`.
  - The point decoding in `GarminRGN.swift`: `src/qmapshack/map/garmin/CGarminPoint.cpp`.
  Each file names its source in the header.
- The reader of the maps' own heights, `Sources/BaseCampIMG/GarminDEM.swift`, is ported from GPXSee, Copyright (C)
  Martin Tůma, licensed under the GNU General Public License version 3 only: `src/map/IMG/demfile.cpp`,
  `demfile.h`, `demtile.h`, `demtree.cpp`, `jls.cpp`, `jls.h`. The relief shading follows GPXSee's
  `src/map/hillshading.cpp`. Because GPXSee is GPL-3.0 only, the program as a whole is distributed under
  version 3 of the GPL; the rest of the code stays available under version 3 or later.

- The table of BaseCamp's waypoint symbol numbers, `Sources/BaseCampCore/MapSourceSymbols.swift`, is GPSBabel's
  (`garmin_icon_tables.h`), Copyright (C) 2003-2007 Robert Lipe, licensed under the GNU General Public License
  version 2 or later.
- The reader of BaseCamp's own library, `Sources/BaseCampCore/BaseCampDatabase.swift`, was written from the layout of
  the user's own BaseCamp files, with GPSBabel's description of MapSource's GDB format as a guide. No Garmin code was
  used.

## Map and data sources

- Apple Maps (MapKit), used under Apple's terms.
- IGN Plan V2 and IGN contour lines: IGN, under the Etalab open licence v2.0.
- OpenTopoMap: map data © OpenStreetMap contributors (ODbL); rendering © OpenTopoMap (CC-BY-SA).
- OpenStreetMap: © OpenStreetMap contributors (ODbL).
- BRouter routing (MIT licence, github.com/abrensch/brouter): not included. When the user asks, HighCamp downloads a
  BRouter release from GitHub and map data tiles from brouter.de (from OpenStreetMap, © OpenStreetMap contributors,
  ODbL) into its own folder, and talks to the server over HTTP.
- libmtp, for USB transfers with the Garmin Edge: LGPL-2.1, linked dynamically.
