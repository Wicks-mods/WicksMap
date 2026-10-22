# Changelog

## 0.1.0 - unreleased

The first release.

### Added

- Scrolling the world map moves between levels: in over a continent opens
  it, in over a zone opens that, out goes back up. Where a map zooms, the
  game's own zoom runs to its end first.
- A short zoom between levels, drawn from the game's own map art, with the
  smaller map coming in from its place on the larger one. Can be turned
  off.
- Right-click the world map to drop a marker, and right-click it again to
  take it away. Shift+right-click still goes up a level.
- On Forever the marker is the game's own tracked waypoint, shown on the
  map, the minimap and in the world.
- On TBC the marker is a pin on the map and a small window with an arrow
  and the distance in yards, kept between sessions and cleared on arrival.
- `/wmap x y` drops a marker at coordinates in the zone you are in;
  `/wmap clear` takes it away.
