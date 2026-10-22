# Changelog

## 0.1.0 - unreleased

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
- Right-click the world map to drop a marker, and right-click it again to
  take it away. Shift+right-click still goes up a level.
- On Forever the marker is the game's own tracked waypoint, shown on the
  map, the minimap and in the world.
- On TBC the marker is a pin on the map and a small window with an arrow
  and the distance in yards, kept between sessions and cleared on arrival.
- `/wmap x y` drops a marker at coordinates in the zone you are in;
  `/wmap clear` takes it away.
