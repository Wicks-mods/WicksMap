# Changelog

## 0.1.0 (2026-10-23)

The first release.

### Added

- Scrolling the world map moves between levels: in over a continent opens
  it, in over a zone opens that, out goes back up. Where a map zooms, the
  game's own zoom runs to its end first.
- Each zoom step glides instead of jumping, with one spot held still, and
  a new level opens zoomed so that spot stays there. Can be turned off.
- With the cursor over the part of the map you are in, the zoom closes in
  on you and brings you toward the middle; anywhere else, or with Shift
  held, it zooms where the cursor is. Can be turned off.
- A short zoom between levels, drawn from the game's own map art, with the
  smaller map coming in from its place on the larger one. Can be turned
  off.
- Zoomed in on a zone, the minimap's terrain tiles fade in under the map's
  pins, on the Eastern Kingdoms, Kalimdor and Outland. At the game's
  closest zoom it is all terrain, and the wheel goes on past that step,
  about as close as the minimap's closest zoom; scrolling on once there
  leaves the view where it is. Can be turned off.
- Pins of your own: right-click the world map to add one with a name, a
  note and a raid marker icon. Kept between sessions on every character,
  shown on their zone and smaller on the continent. Hover to read one,
  left-click to head there, right-click to change or delete it.
  Shift+right-click still goes up a level.
- Left-click a pin to head for it: it glows, and a small window with an
  arrow and the distance in yards points the way, clearing on arrival.
  Left-click again to stop; deleting the pin stops it too.
- The same menu sets a waypoint anywhere, with the same arrow. On Forever
  it is the game's own waypoint, also shown on the world map and the
  minimap; on TBC a marker of ours on the map. One place to head for at a
  time.
- `/wmap pin [name]` pins where you stand and `/wmap pins` lists them;
  `/wmap x y` sets a waypoint at coordinates in the zone you are in and
  `/wmap clear` takes it away.
