-- Wick's Map
-- Core.lua: the addon object, its settings, the map helpers the other two
-- files share, the slash command, the launcher and the options page.
--
-- Wick's Map does not draw a map of its own. It teaches the game's world
-- map a few things: the mouse wheel moves between levels (the world, a
-- continent, a zone, a city) with a glide between them (Zoom.lua), the
-- ground itself shows close in (Terrain.lua), and a right-click offers
-- pins of your own (Pins.lua) and a waypoint (Marker.lua).
--
-- One rule runs through all of them: nothing of ours is ever written into
-- the game's map tables. On Forever a value of ours in their table taints
-- everything of theirs that reads it. So the map is read (where the canvas
-- sits, how far it is zoomed) and drawn over by frames of our own, the
-- wheel is a post-hook that runs after the game's own handler, and the
-- right-click comes in through the canvas click handlers, the place the
-- map keeps for addons. The one thing that has to be the game's own call
-- is changing the map, so on Forever the wheel leaves the map alone during
-- a fight.

local ADDON, ns = ...

local Core = WickCore
if not Core then
    -- WickCore is missing or switched off. The TOC asks for it with
    -- OptionalDeps so this still loads and can say what is wrong, in the
    -- one line the whole suite shares.
    local need = _G.WicksNeedCore
    if not need then
        need = {}
        _G.WicksNeedCore = need
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function()
            table.sort(need)
            print(("|cff4FC778Wick's Mods|r: %s %s WickCore, which is not installed or not switched on. It is in the same download as the rest of the suite: |cffD4C8A1wicksmods.com|r")
                :format(table.concat(need, ", "), #need == 1 and "needs" or "need"))
        end)
    end
    need[#need + 1] = "Wick's Map"
    return
end
ns.Core = Core
-- The harness, and anyone scripting the addon, reaches it by this name.
_G.WicksMap = ns

local Chrome = Core.Chrome
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
ns.version = GetMeta and GetMeta(ADDON, "Version") or "0.1.0"

local A = Core:NewAddon(ADDON, {
    title    = "Wick's Map",
    version  = ns.version,
    savedVar = "WicksMapDB",
    defaults = {
        -- Account-wide: how the map behaves is the player's habit, not
        -- one character's.
        global = {
            wheel      = true,   -- the wheel moves between map levels
            anchor     = true,   -- glide each zoom step, keeping one spot in place
            onPlayer   = true,   -- that spot is you when the cursor is over where you are
            animate    = true,   -- zoom between levels rather than cut
            terrain    = true,   -- the minimap's terrain past the painted map's detail
            rightClick = true,   -- right-click opens the pin and waypoint menu
            arrow      = true,   -- the arrow to our own marker
            autoClear  = true,   -- take the marker away on arrival
            arrowWin   = {},     -- where the arrow window sits
            pins       = {},     -- your pins: { id, mapID, x, y, title, icon, note }
            nextPin    = 1,
            continentPins = true, -- show pins on continent maps too
            -- marker = { mapID, x, y } while one of our own is down
        },
    },
})
ns.A = A

-- The saved table is read through here every time, never kept: WickCore
-- may swap in the client's own table at login.
function ns.DB() return A.db and A.db.global end

function ns.Dirty()
    if Core.Store and Core.Store.Dirty then Core.Store:Dirty() end
end

-- ============================================================
-- Map helpers
-- ============================================================

-- The game's world map, once it exists and is the canvas kind both
-- clients build (a scroll container holding the map art).
function ns.WorldMap()
    local wm = rawget(_G, "WorldMapFrame")
    if wm and wm.ScrollContainer and wm.GetMapID then return wm end
end

-- The frame the map art is drawn on. It moves and grows as the game
-- zooms and pans within a map.
function ns.Canvas(wm)
    wm = wm or ns.WorldMap()
    if not wm then return nil end
    return (wm.GetCanvas and wm:GetCanvas()) or wm.ScrollContainer.Child
end

-- Where the map art sits right now, in the units of one of our frames,
-- measured from that frame's top left with y running down. Only read,
-- never set: the game owns the canvas.
function ns.CanvasRect(frame)
    local canvas = ns.Canvas()
    if not (canvas and frame) then return nil end
    local l, t = canvas:GetLeft(), canvas:GetTop()
    local fl, ft = frame:GetLeft(), frame:GetTop()
    if not (l and t and fl and ft) then return nil end
    local cs, fs = canvas:GetEffectiveScale(), frame:GetEffectiveScale()
    local w, h = canvas:GetWidth() * cs / fs, canvas:GetHeight() * cs / fs
    if not (w > 0 and h > 0) then return nil end
    return { x = (l * cs - fl * fs) / fs, y = (ft * fs - t * cs) / fs, w = w, h = h }
end

-- The frame levels the map's pins use. They are fixed numbers from 2000
-- up (MapCanvas_PinFrameLevelsManager), not relative to the map: the
-- explored areas a zone draws over its art are the lowest, and every icon
-- sits above them. Our layers are placed against these, read once.
function ns.PinLevels(wm)
    local explore, top = 2001, 3000
    local mgr = wm and wm.GetPinFrameLevelsManager and wm:GetPinFrameLevelsManager()
    if type(mgr) == "table" then
        local ok, v = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_MAP_EXPLORATION")
        if ok and type(v) == "number" then explore = v end
        local m = rawget(mgr, "maxLevel")
        if type(m) == "number" then top = m end
    end
    return explore, top
end

-- Whether the wheel may change the map now. Changing it is a call into
-- the game's map code from ours, and on a client with secret values that
-- leaves their map code running in our taint until it next changes on its
-- own. Out of a fight that is harmless; in one it is not worth the risk,
-- so the wheel goes back to zooming the way it always did.
function ns.CanChangeMap()
    if not (Core.Client and Core.Client.hasSecrets) then return true end
    return not Core.Restrict:AnyActive()
end

local function vector(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y, GetXY = function(v) return v.x, v.y end }
end
ns.Vector = vector

-- A point on a map as a point in the world: the continent it is on and
-- its world position, in yards.
function ns.WorldPos(mapID, x, y)
    local M = rawget(_G, "C_Map")
    if not (M and M.GetWorldPosFromMapPos and mapID) then return nil end
    local ok, cont, pos = pcall(M.GetWorldPosFromMapPos, mapID, vector(x, y))
    if ok and cont and pos then return cont, pos end
end

-- A world position as a point on another map of the same continent.
function ns.MapPos(cont, pos, mapID)
    local M = rawget(_G, "C_Map")
    if not (M and M.GetMapPosFromWorldPos and cont and pos and mapID) then return nil end
    local ok, _, mp = pcall(M.GetMapPosFromWorldPos, cont, pos, mapID)
    if ok and mp then return mp:GetXY() end
end

-- The same spot on a map one level down. The world map has no world
-- position of its own (it spans continents), so where that fails the
-- child's place on the parent says where the spot falls.
local function down(mapID, childID, x, y)
    local cont, pos = ns.WorldPos(mapID, x, y)
    local cx, cy = ns.MapPos(cont, pos, childID)
    if cx then return cx, cy end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, childID, mapID)
    if ok and minX and maxX > minX and maxY > minY then
        return (x - minX) / (maxX - minX), (y - minY) / (maxY - minY)
    end
end

-- A click on a map too large to hold something (the world, a continent)
-- goes down to the map under it, at the same spot, until it reaches a
-- zone that accept(mapID) takes. nil where nothing will.
local MAP_ZONE = 3
function ns.Descend(mapID, x, y, accept)
    for _ = 1, 4 do
        local info = C_Map.GetMapInfo(mapID)
        local small = info and (info.mapType or MAP_ZONE) >= MAP_ZONE
        if small and accept(mapID) then return mapID, x, y end
        local ok, child = pcall(C_Map.GetMapInfoAtPosition, mapID, x, y)
        if not (ok and child and child.mapID and child.mapID ~= mapID) then break end
        local cx, cy = down(mapID, child.mapID, x, y)
        if not cx then break end
        mapID, x, y = child.mapID, cx, cy
    end
    if accept(mapID) then return mapID, x, y end
end

function ns.MapName(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or "?"
end

-- ============================================================
-- Hooking the map
-- ============================================================

function ns:Attach()
    if self.attached then return end
    local wm = ns.WorldMap()
    if not wm then return end
    self.attached = true
    if ns.Zoom then Core.safe(ns.Zoom.Attach, ns.Zoom, wm) end
    if ns.Terrain then Core.safe(ns.Terrain.Attach, ns.Terrain, wm) end
    if ns.Marker then Core.safe(ns.Marker.Attach, ns.Marker, wm) end
    if ns.Pins then Core.safe(ns.Pins.Attach, ns.Pins, wm) end
end

-- The world map is part of the game's interface from the start on both
-- clients. Should it ever load on demand, it is picked up when it does.
A:On("ADDON_LOADED", function(name)
    if name == "Blizzard_WorldMap" and A.enabled then ns:Attach() end
end)

-- ============================================================
-- Slash command: the fallback, and the coordinate form
-- ============================================================

local HELP = {
    "/wmap  opens the options",
    "/wmap pin Herbs  pins the spot you are standing on (the name is optional)",
    "/wmap pins  lists your pins",
    "/wmap 45.2 61.8  sets a waypoint at those coordinates in the zone you are in",
    "/wmap clear  takes the waypoint away",
    "Scroll the world map to move between the world, a continent and a zone. Right-click it for pins and waypoints.",
}

function ns:Command(msg)
    msg = Core.trim(msg or "")
    local lower = msg:lower()
    if msg == "" or lower == "options" or lower == "config" then A:OpenOptions() return end
    if lower == "help" or lower == "?" then
        for _, line in ipairs(HELP) do A:Print(line) end
        return
    end
    local pinTitle = msg:match("^[Pp][Ii][Nn]%s*(.*)$")
    if pinTitle and lower ~= "pins" then
        ns.Pins:PinHere(Core.trim(pinTitle))
        return
    end
    if lower == "pins" then
        local list = ns.Pins:All()
        if #list == 0 then A:Print("no pins yet. Right-click the world map, or /wmap pin where you stand.") return end
        for _, p in ipairs(list) do
            A:Print(("%s%s|r  %s  %.1f, %.1f"):format(Chrome:Esc("fel"), p.title or "Pin", ns.MapName(p.mapID), p.x * 100, p.y * 100))
        end
        return
    end
    if lower == "clear" then
        if ns.Marker:Has() then ns.Marker:Clear() else A:Print("no waypoint is set.") end
        return
    end
    local x, y = msg:match("^(%d+%.?%d*)[%s,]+(%d+%.?%d*)$")
    x, y = tonumber(x), tonumber(y)
    if x and y then
        local mapID = C_Map.GetBestMapForUnit("player")
        if not mapID then A:Print("there is no map for where you are.") return end
        if x > 100 or y > 100 then A:Print("coordinates run from 0 to 100, as the map shows them.") return end
        ns.Marker:Set(mapID, x / 100, y / 100)
        return
    end
    A:Print("not sure what you mean. /wmap help shows what it knows.")
end

A:RegisterSlash(function(_, msg) ns:Command(msg) end, "/wmap", "/wickmap")

-- ============================================================
-- Lifecycle, launcher, options page
-- ============================================================

function A:OnEnable()
    ns:Attach()
    if ns.Marker then ns.Marker:Restore() end

    self:RegisterLauncher({
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        onClick = function(addon, button)
            if button == "RightButton" then
                if ns.Marker:Has() then ns.Marker:Clear() end
            else
                addon:OpenOptions()
            end
        end,
        tooltip = function(tt)
            tt:AddLine(Chrome:TitleMarkup("Wick's Map"))
            local line = ns.Marker:Describe()
            local c = Chrome.Colors.text
            if line then
                tt:AddLine("Waypoint: " .. line, c[1], c[2], c[3])
            end
            local n = #ns.Pins:All()
            tt:AddLine(n == 0 and "No pins yet. Right-click the world map to add one."
                or (n == 1 and "1 pin" or (n .. " pins")), 0.56, 0.53, 0.44)
            tt:AddLine(" ")
            tt:AddLine("Left-click: options   Right-click: clear the waypoint", 0.5, 0.5, 0.5)
        end,
    })

    self:RegisterOptions(function(page)
        local O = Core.Options
        local function check(label, key, y, after)
            return O:Check(page, label, function() return ns.DB()[key] == true end,
                function(v) ns.DB()[key] = v and true or false; if after then after(v) end end, y)
        end

        local y = O:Heading(page, "Scrolling", 0)
        y = check("Scroll the world map to move between levels", "wheel", y)
        y = O:Note(page, "Scroll in over a continent to open it, and in again over a zone to open that. Scroll out to go back up. Where the game lets a map zoom, it zooms all the way first.", y)
        y = check("Glide the zoom", "anchor", y)
        y = O:Note(page, "Each step glides instead of jumping, with one spot held still, and a new level opens zoomed so that spot stays put. Off, the game's own jumps are left as they are and each level opens whole.", y)
        y = check("Zoom in on yourself", "onPlayer", y)
        y = O:Note(page, "With the cursor over the part of the map you are in (your continent, your zone), the zoom closes in on you and brings you toward the middle. Point anywhere else, or hold Shift, and it zooms where the cursor is.", y)
        y = check("Zoom between levels instead of cutting", "animate", y)
        y = check("Show the terrain when zoomed in close", "terrain", y, function() ns.Terrain:Refresh() end)
        y = O:Note(page, "Zoomed in on a zone, the minimap's terrain fades in under the map's pins, and the wheel goes on past the game's closest zoom. It shows the ground as it is, explored or not.", y)
        if Core.Client and Core.Client.hasSecrets then
            y = O:Note(page, "During a fight the wheel does what it always did. The map changes again once you are out of combat.", y)
        end

        y = O:Heading(page, "Pins and waypoints", y - 6)
        y = check("Right-click the world map for pins and waypoints", "rightClick", y)
        y = O:Note(page, "Add a pin to keep a place, with a name, a note and an icon, or set a waypoint to head there. Hover a pin to read it, left-click it to head there, right-click it to change it. Shift+right-click still goes up a level.", y)
        y = check("Show pins on continent maps too", "continentPins", y, function() ns.Pins:Changed() end)
        y = check("Show an arrow pointing to the waypoint", "arrow", y, function() ns.Marker:Refresh() end)
        y = O:Note(page, "A small window with the direction and the distance in yards, named for the pin you are heading to. Drag it by its title; right-click it to clear the waypoint.", y)
        y = check("Clear the waypoint when I reach it", "autoClear", y)
        if ns.Marker:Native() then
            y = O:Note(page, "The waypoint is the game's own, so it also shows on the world map and the minimap.", y)
        end
        y = O:Button(page, "Clear the waypoint", function() ns.Marker:Clear() end, y - 4, 150)
    end)
end
