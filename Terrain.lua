-- Wick's Map
-- Terrain.lua: past the painted map's detail, the ground itself.
--
-- A zone's painted map is one image about a thousand pixels wide. Zoom in
-- far and it is that image blown up. The minimap is drawn from finer
-- images, one 256 pixel tile for every 533 1/3 yards, so close in, those
-- tiles (Tiles.lua lists them) fade in over the painted map. They sit
-- above the painted art and the explored areas, and under every pin, so
-- quests, flight points and the player arrow stay on top.
--
-- The terrain comes in over the second half of the game's own zoom on a
-- zone and is all there is at its closest step. Past that the wheel goes
-- on, in our own steps, until a terrain pixel is about as big as the
-- minimap's closest zoom makes it (Zoom.lua drives the wheel; DeepCap
-- here says how far). How far in a view is gets measured against the
-- zone's own map even on a continent: a continent zoomed in until a zone
-- fills the frame shows what that zone's map would show at the same
-- size, so going up a level never turns the terrain on by itself.
--
-- Like everything else here it only reads the game's map: where the
-- canvas sits and how far it is zoomed. The layer is ours, hung inside the
-- map's canvas at a frame level between the art and the pins.

local ADDON, ns = ...
if not WickCore then return end

local Terrain = {}
ns.Terrain = Terrain

local TILE      = 1600 / 3   -- yards on a side of one tile
local GRID      = 64         -- tiles on a side of a continent's grid
local TILE_PX   = 256        -- pixels on a side of one tile's image
local FADE_START = 0.5       -- how far through a zone's zoom the terrain starts (all there at 1)
local MIN_RANGE = 1.5        -- a map that zooms less than this is taken to zoom this far
local DEEP_MAX  = 2.5        -- our zoom stops where a terrain pixel is this many screen pixels
local MAX_TILES = 64         -- more than this in view and the terrain stays out

-- [continent] = { [col * GRID + row] = file id }
local tiles = {}

local function decode()
    for cont in pairs(tiles) do tiles[cont] = nil end
    for cont, runs in pairs(ns.TILE_RUNS or {}) do
        local t = {}
        for i = 1, #runs - 3, 4 do
            local col, row, n, id = runs[i], runs[i + 1], runs[i + 2], runs[i + 3]
            for k = 0, n - 1 do t[col * GRID + row + k] = id + k end
        end
        tiles[cont] = t
    end
end
Terrain.tiles = tiles
Terrain.Decode = decode

-- ============================================================
-- Where a map sits in the tile grid
-- ============================================================
-- Columns count east and rows count south from the grid's corner, the
-- world origin in the middle: column = 32 - west / TILE, row = 32 -
-- north / TILE. Which component of a world position is which is found by
-- asking where three corners of the map are, so nothing rests on the
-- order the client hands them back in.

local geometry = {}

local function measure(mapID)
    local cont, a = ns.WorldPos(mapID, 0, 0)
    local _, b = ns.WorldPos(mapID, 1, 0)
    local _, c = ns.WorldPos(mapID, 0, 1)
    if not (cont and a and b and c) then return false end
    local ax, ay = a:GetXY()
    local bx, by = b:GetXY()
    local cx, cy = c:GetXY()
    -- The component that changes along the top edge runs east and west.
    local ewIsX = math.abs(bx - ax) > math.abs(by - ay)
    local westL, westR = ewIsX and ax or ay, ewIsX and bx or by
    local northT, northB = ewIsX and ay or ax, ewIsX and cy or cx
    -- Going east a west coordinate falls and going south a north one
    -- does. One that rises is the same axis counted the other way.
    if westR > westL then westL, westR = -westL, -westR end
    if northB > northT then northT, northB = -northT, -northB end
    local g = {
        cont = cont,
        u0 = GRID / 2 - westL / TILE, u1 = GRID / 2 - westR / TILE,
        v0 = GRID / 2 - northT / TILE, v1 = GRID / 2 - northB / TILE,
        yards = math.abs(westL - westR),
    }
    if not (g.u1 > g.u0 and g.v1 > g.v0) then return false end
    local layers = C_Map.GetMapArtLayers(mapID)
    g.artWidth = layers and layers[1] and layers[1].layerWidth or 1002
    return g
end

local function geometryOf(mapID)
    local g = geometry[mapID]
    if g == nil then
        g = measure(mapID)
        geometry[mapID] = g
    end
    return g or nil
end
Terrain.GeometryOf = geometryOf

-- The scales the game zooms a map between, worked out the way the canvas
-- works them out (CreateZoomLevels), for a map other than the one shown.
local function zoomRange(mapID, sc)
    local layers = C_Map.GetMapArtLayers(mapID)
    local L1 = layers and layers[1]
    if not (L1 and (L1.layerWidth or 0) > 0 and (L1.layerHeight or 0) > 0) then return nil end
    local base = math.min(sc:GetWidth() / L1.layerWidth, sc:GetHeight() / L1.layerHeight)
    local lo, hi = (L1.minScale or 1) * base, (L1.maxScale or 1) * base
    for _, L in ipairs(layers) do hi = math.max(hi, (L.maxScale or 1) * base) end
    return lo, hi
end

-- How far in the view is, on the best map there is for the spot in its
-- middle: the map's own if it is a zone or smaller, otherwise the zone
-- under that spot. 0 is that map whole, 1 the game's closest zoom on it,
-- and past 1 is our own zoom. Counted in steps of scale, as the zoom is.
local MAP_ZONE = 3
local function depth(sc, mapID, g, x, y)
    local s = sc:GetCanvasScale()
    local lo, hi, sRef
    local info = C_Map.GetMapInfo(mapID)
    if info and (info.mapType or MAP_ZONE) < MAP_ZONE then
        local ok, zone = pcall(C_Map.GetMapInfoAtPosition, mapID, x, y)
        local zg = ok and zone and zone.mapID ~= mapID and geometryOf(zone.mapID)
        if zg and zg.cont == g.cont then
            lo, hi = zoomRange(zone.mapID, sc)
            -- The scale the zone's own map would need to show this view.
            sRef = s * g.artWidth * zg.yards / (zg.artWidth * g.yards)
        end
    end
    if not sRef then
        lo, hi, sRef = sc:GetScaleForMinZoom(), sc:GetScaleForMaxZoom(), s
    end
    if not (lo and hi and lo > 0 and sRef > 0) then return 0 end
    return math.log(sRef / lo) / math.log(math.max(hi / lo, MIN_RANGE))
end

-- How many physical pixels one unit of a frame covers.
local function pixelsPerUnit(frame)
    local h = 768
    if GetPhysicalScreenSize then
        local _, ph = GetPhysicalScreenSize()
        if ph and ph > 0 then h = ph end
    end
    return frame:GetEffectiveScale() * h / 768
end

-- ============================================================
-- The layer
-- ============================================================

function Terrain:Layer(wm)
    if self.layer then return self.layer end
    -- Inside the map's own canvas. The game draws everything in its scroll
    -- frame as one group, art and pins together; a frame of ours outside
    -- it lands over all of it whatever its level. In here, by level, it
    -- sits just over the explored areas (the art's top layer) and under
    -- every pin, and it pans and zooms with the map by itself.
    local canvas = ns.Canvas(wm)
    local explore = ns.PinLevels(wm)
    local layer = CreateFrame("Frame", nil, canvas)
    layer:SetAllPoints(canvas)
    layer:SetFrameLevel(explore + 1)
    layer:EnableMouse(false)
    layer:SetAlpha(0)
    layer:SetScript("OnUpdate", function() Terrain:Update() end)
    self.layer = layer
    self.shown, self.pool = {}, {}
    return layer
end

-- Put every tile back in the pool.
local function release(self)
    for key, t in pairs(self.shown) do
        t:Hide()
        self.shown[key] = nil
        self.pool[#self.pool + 1] = t
    end
end

-- And the layer out of sight, keeping what it last measured.
local function clear(self)
    release(self)
    self.layer:SetAlpha(0)
    self.alpha = 0
end

function Terrain:Hide()
    if not self.layer then return end
    clear(self)
    self.last = nil
end

-- Draw what the map shows now. Skipped when nothing has moved.
function Terrain:Update()
    local wm, layer, db = ns.WorldMap(), self.layer, ns.DB()
    if not (wm and layer and db and db.terrain) then self:Hide() return end
    local mapID = wm:GetMapID()
    local g = mapID and geometryOf(mapID)
    local grid = g and tiles[g.cont]
    if not grid then self:Hide() return end
    local sc = wm.ScrollContainer
    local R = ns.CanvasRect(sc)
    if not R then self:Hide() return end
    local W, H = sc:GetWidth(), sc:GetHeight()
    local last = self.last
    if last and last.map == mapID and last.x == R.x and last.y == R.y and last.w == R.w and last.h == R.h then return end
    -- Tiles are placed on the canvas, so a new map puts them all back.
    if not last or last.map ~= mapID then release(self) end
    self.last = { map = mapID, x = R.x, y = R.y, w = R.w, h = R.h }

    -- The part of the map in view, as fractions of it.
    local x0, x1 = math.max(0, -R.x / R.w), math.min(1, (W - R.x) / R.w)
    local y0, y1 = math.max(0, -R.y / R.h), math.min(1, (H - R.y) / R.h)
    if x1 <= x0 or y1 <= y0 then clear(self) return end

    -- How far in the view is, against the zone's own map.
    local d = depth(sc, mapID, g, (x0 + x1) / 2, (y0 + y1) / 2)
    local alpha = (d - FADE_START) / (1 - FADE_START)
    if alpha <= 0 then clear(self) return end
    alpha = math.min(1, alpha)

    local du, dv = g.u1 - g.u0, g.v1 - g.v0
    local c0, c1 = math.floor(g.u0 + x0 * du), math.floor(g.u0 + x1 * du - 1e-9)
    local r0, r1 = math.floor(g.v0 + y0 * dv), math.floor(g.v0 + y1 * dv - 1e-9)
    if (c1 - c0 + 1) * (r1 - r0 + 1) > MAX_TILES then clear(self) return end

    -- A tile covers 1 / du of the map's width; on the canvas, the art's
    -- own units, that is fixed for the map, whatever the zoom.
    local canvas = ns.Canvas(wm)
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local keep = {}
    for col = math.max(0, c0), math.min(GRID - 1, c1) do
        for row = math.max(0, r0), math.min(GRID - 1, r1) do
            local key = col * GRID + row
            local id = grid[key]
            if id then
                if not self.shown[key] then
                    local t = table.remove(self.pool) or layer:CreateTexture(nil, "BACKGROUND")
                    t:SetTexture(id, nil, nil, "TRILINEAR")
                    t.wickTile = id
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", layer, "TOPLEFT", (col - g.u0) / du * cw, -(row - g.v0) / dv * ch)
                    t:SetSize(cw / du, ch / dv)
                    t:Show()
                    self.shown[key] = t
                end
                keep[key] = true
            end
        end
    end
    for key, t in pairs(self.shown) do
        if not keep[key] then
            t:Hide()
            self.shown[key] = nil
            self.pool[#self.pool + 1] = t
        end
    end
    layer:SetAlpha(alpha)
    self.alpha = alpha
end

-- How far our own zoom may take the map shown: the canvas scale at which
-- one pixel of terrain covers DEEP_MAX pixels of screen, never short of
-- where the terrain has finished coming in. nil where there is no terrain
-- to zoom into, or the game already zooms that far. Zones and smaller
-- only: on a continent, open ground under the cursor is the sea.
function Terrain:DeepCap(wm)
    local db = ns.DB()
    if not (db and db.terrain and wm) then return nil end
    local mapID = wm:GetMapID()
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info or (info.mapType or MAP_ZONE) < MAP_ZONE then return nil end
    local g = geometryOf(mapID)
    if not (g and tiles[g.cont]) then return nil end
    local sc = wm.ScrollContainer
    -- Screen pixels per terrain pixel at scale s:
    -- s * pixelsPerUnit * artWidth / yards (screen pixels per yard)
    -- times TILE / TILE_PX (yards per terrain pixel).
    local cap = DEEP_MAX * g.yards * TILE_PX / (g.artWidth * pixelsPerUnit(sc) * TILE)
    cap = math.max(cap, sc:GetScaleForMinZoom() * MIN_RANGE)
    if cap > sc:GetScaleForMaxZoom() * 1.02 then return cap end
end

function Terrain:Refresh()
    self.last = nil
    if not self.layer then return end
    local db = ns.DB()
    self.layer:SetShown(db and db.terrain and true or false)
    if not (db and db.terrain) then self:Hide() end
end

function Terrain:Attach(wm)
    if self.attached then return end
    self.attached = true
    decode()
    self:Layer(wm)
    self:Refresh()
end
