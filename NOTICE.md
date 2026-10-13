# Notices

BaseCamp Clone is free software, licensed under the GNU General Public License version 3 or later.
See `LICENSE`.

## Code from other projects

- The Garmin map readers in `Sources/BaseCampIMG/` are ported from QMapShack, Copyright (C) 2008-2014
  Oliver Eichler and contributors, licensed under the GNU General Public License version 3 or later:
  - `GarminIMG.swift`: `src/qmapshack/map/CMapIMG.cpp`, `src/qmapshack/map/CMapIMG.h`,
    `src/qmapshack/helpers/Platform.h`.
  - `GarminRGN.swift`: `src/qmapshack/map/CMapIMG.cpp`, `src/qmapshack/map/garmin/CGarminPolygon.cpp`,
    `src/qmapshack/map/CMapIMG.h`.
  - `GarminTyp.swift`: `src/qmapshack/map/garmin/CGarminTyp.cpp`.
  Each file names its source in the header.

## Map and data sources

- Apple Maps (MapKit), used under Apple's terms.
- IGN Plan V2 and IGN contour lines: IGN, under the Etalab open licence v2.0.
- OpenTopoMap: map data © OpenStreetMap contributors (ODbL); rendering © OpenTopoMap (CC-BY-SA).
- OpenStreetMap: © OpenStreetMap contributors (ODbL).
- BRouter routing: used over HTTP; the BRouter jar and data are not included.
- libmtp, for USB transfers with the Garmin Edge: LGPL-2.1, linked dynamically.
