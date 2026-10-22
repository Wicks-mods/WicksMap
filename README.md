# Wick's Map

> Scroll the world map from the world to a continent to a zone, and right-click to drop a waypoint. TBC Classic Anniversary and Forever.

Part of the **[Wick suite](https://github.com/Wicks-mods/WickSuite)**: precision addons built around a single fel-green-on-deep-purple aesthetic. Built on [WickCore](https://github.com/Wicks-mods/WickCore).

## What it does

- **Scroll to move between levels.** Scroll in over a continent on the
  world map and it opens; scroll in over a zone and that opens. Scroll out
  to go back up. Where a map can zoom, it zooms all the way first.
- **A smooth zoom that stays put.** Each step glides instead of jumping,
  with one spot held still, and a new level opens zoomed so that spot
  stays put.
- **Zoom in on yourself.** With the cursor over the part of the map you
  are in, the zoom closes in on you and brings you toward the middle.
  Point anywhere else, or hold Shift, and it zooms where the cursor is.
- **A zoom, not a cut.** The map you leave grows away around the one you
  arrive at, which comes in from its real place on the larger map. It
  takes under half a second, and can be turned off.
- **Terrain when you zoom in close.** Over the second half of a zone's
  zoom the minimap's terrain fades in under the map's pins (you, your
  party and the quest markers stay on top), about two and
  a half times as fine as the painted map. At the game's closest zoom it
  is all terrain, and the wheel keeps going, about as close as the
  minimap's closest zoom. It shows the ground as it is, explored or not,
  and can be turned off.
- **Right-click to drop a marker.** Right-click the marker again to take
  it away. Shift+right-click still goes up a level. A right-click on a
  continent puts the marker in the zone under the cursor.
- **On Forever, the game's own waypoint.** The marker shows on the map,
  on the minimap and in the world, with the distance to it.
- **On TBC, a pin and an arrow.** A pin on the map, and a small window
  with an arrow and the distance in yards that clears the marker when you
  arrive. The marker is kept between sessions.

It uses the game's own world map, so quest, flight point and party
markers all stay where they are. During a fight on Forever the wheel does
what it always did.

## Install

Requires **[WickCore](https://github.com/Wicks-mods/WickCore)**. Extract both
folders into `World of Warcraft\_anniversary_\Interface\AddOns\` for TBC
Classic Anniversary, or into the `Interface\AddOns\` folder of your Forever
install.

## Usage

Everything is on the world map and in the options under Wick's Mods. From
chat:

| Command | Effect |
|---|---|
| `/wmap` | Open the options |
| `/wmap 45.2 61.8` | A marker at those coordinates in the zone you are in |
| `/wmap clear` | Take the marker away |

`/wickmap` is the same command.

## License

Code is MIT. The Wick name, logomark and visual system are trademarks; see
[LICENSE](LICENSE).
