-- Wick's Map
-- Zoom.lua: the mouse wheel moves between map levels, with a zoom between
-- them.
--
-- The game's own wheel handler runs first and zooms within the map where
-- the map allows it. This runs after it, and only acts when the game had
-- nowhere further to go: all the way in, the wheel opens the place under
-- the cursor (the world to a continent, a continent to a zone, a zone to a
-- city); all the way out, it goes up to the map above. Through all of it
-- the spot under the cursor stays under the cursor.
--
-- The zoom is drawn by us, on a frame laid over the map, from the same art
-- files the game draws: the map we leave and the map we arrive at, the
-- smaller placed where it sits on the larger. The camera moves from one to
-- the other, then our frame fades off the game's own map, which has
-- changed underneath it the whole time and carries every pin.

local ADDON, ns = ...
if not WickCore then return end

local Core = WickCore

local Zoom = {}
ns.Zoom = Zoom

local SPRING   = 16     -- a glide's spring: starts gently, most of the way in a quarter second
local DEEP_STEP = 1.5   -- each notch past the game's closest step, into the terrain
local DURATION = 0.4    -- the camera move between levels
local FADE     = 0.16   -- our frame fading off the game's map after it
local FEATHER  = "Interface\\AddOns\\WicksMap\\Media\\feather.png"
local PAUSE    = 0.3    -- after a change, the wheel waits this long to change maps again
local EPS      = 0.001  -- how close two canvas scales count as the same

-- ============================================================
-- Map art in a frame of our own
-- ============================================================
-- The base tiles and the explored overlays of one map, laid out at the
-- art's own size, as the game lays out its detail layer and its
-- exploration pin. The whole frame is scaled to put the map anywhere.

-- feathered: the edges fade out through a mask, so the smaller map comes
-- in over the larger as a soft patch rather than a picture with a frame.
local function newArt(parent, level, feathered)
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameLevel(level)
    f:SetSize(1, 1)
    f.tex, f.used, f.w, f.h = {}, 0, 1, 1
    if feathered and f.CreateMaskTexture then
        local m = f:CreateMaskTexture()
        m:SetTexture(FEATHER, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(f)
        f.mask = m
    end
    return f
end

local function nextTexture(art, layer)
    art.used = art.used + 1
    local t = art.tex[art.used]
    if not t then
        t = art:CreateTexture(nil, layer)
        if art.mask then t:AddMaskTexture(art.mask) end
        art.tex[art.used] = t
    end
    t:SetDrawLayer(layer)
    t:ClearAllPoints()
    t:Show()
    return t
end

-- A texture file whose last row or column is part filled is stored at
-- the next power of two up, as the game's own code assumes.
local function fileSize(px, tile)
    local f = 16
    while f < px do f = f * 2 end
    return math.min(f, tile)
end

local function drawArt(art, mapID)
    for i = 1, art.used do art.tex[i]:Hide() end
    art.used = 0
    art.mapID = mapID
    local layers = mapID and C_Map.GetMapArtLayers(mapID)
    local L = layers and layers[1]
    if not (L and (L.tileWidth or 0) > 0 and (L.tileHeight or 0) > 0) then return false end
    local tw, th = L.tileWidth, L.tileHeight
    art.w, art.h = L.layerWidth, L.layerHeight
    art:SetSize(art.w, art.h)

    local files = C_Map.GetMapArtLayerTextures(mapID, 1) or {}
    local cols, rows = math.ceil(L.layerWidth / tw), math.ceil(L.layerHeight / th)
    for r = 1, rows do
        for c = 1, cols do
            local file = files[(r - 1) * cols + c]
            if file then
                -- The last row and column run past the edge of the map.
                -- The game clips them with its scroll frame; we crop them.
                local w = math.min(tw, L.layerWidth - (c - 1) * tw)
                local h = math.min(th, L.layerHeight - (r - 1) * th)
                local t = nextTexture(art, "BACKGROUND")
                t:SetTexture(file, nil, nil, "TRILINEAR")
                t:SetSize(w, h)
                t:SetTexCoord(0, w / tw, 0, h / th)
                t:SetPoint("TOPLEFT", art, "TOPLEFT", (c - 1) * tw, -(r - 1) * th)
            end
        end
    end

    -- The parts of a zone the character has explored are drawn over the
    -- base art. Without them a zone would come in blank and fill in at
    -- the end, when the game's map shows through.
    local E = rawget(_G, "C_MapExplorationInfo")
    local explored = E and E.GetExploredMapTextures and E.GetExploredMapTextures(mapID)
    for _, info in ipairs(explored or {}) do
        if not info.isShownByMouseOver and info.fileDataIDs then
            local wide = math.ceil(info.textureWidth / tw)
            local tall = math.ceil(info.textureHeight / th)
            for j = 1, tall do
                local ph = (j < tall) and th or (info.textureHeight % th)
                if ph == 0 then ph = th end
                local fh = (j < tall) and th or fileSize(ph, th)
                for k = 1, wide do
                    local pw = (k < wide) and tw or (info.textureWidth % tw)
                    if pw == 0 then pw = tw end
                    local fw = (k < wide) and tw or fileSize(pw, tw)
                    local file = info.fileDataIDs[(j - 1) * wide + k]
                    if file then
                        local t = nextTexture(art, "ARTWORK")
                        t:SetTexture(file, nil, nil, "TRILINEAR")
                        t:SetSize(pw, ph)
                        t:SetTexCoord(0, pw / fw, 0, ph / fh)
                        t:SetPoint("TOPLEFT", art, "TOPLEFT", info.offsetX + tw * (k - 1), -(info.offsetY + th * (j - 1)))
                    end
                end
            end
        end
    end
    return true
end

-- Put a map's art with its top left at x, y (in the overlay's units, y
-- running down) and w wide. One scale for the whole frame keeps every
-- tile in step.
local function place(art, x, y, w)
    local s = w / art.w
    if not (s > 0) then return end
    art:SetScale(s)
    art:ClearAllPoints()
    -- A scaled frame reads its offsets in its own scaled units.
    art:SetPoint("TOPLEFT", art:GetParent(), "TOPLEFT", x / s, -y / s)
end

-- The same, k times the size of rect R and centred on it.
local function placeAround(art, R, k)
    local w, h = R.w * k, R.h * k
    place(art, R.x + (R.w - w) / 2, R.y + (R.h - h) / 2, w)
end

-- ============================================================
-- The camera
-- ============================================================

-- The camera eases in and out, and the smaller map's fade rides the same
-- curve a little ahead of it, so movement and fade arrive together
-- rather than a zoom followed by a fade.
local function smooth(t) return t * t * (3 - 2 * t) end
local function fadeAt(p) return smooth(math.min(1, p / 0.8)) end

-- Where one map sits on the other, as fractions of the larger map, or nil
-- where the game has no position for it (an instance inside a zone).
local function rectOnMap(childID, parentID)
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, childID, parentID)
    if not (ok and minX and maxX and minY and maxY) then return nil end
    if maxX - minX <= 0.001 or maxY - minY <= 0.001 then return nil end
    -- A map that covers its parent exactly gives nothing to zoom into.
    if maxX - minX > 0.999 and maxY - minY > 0.999 then return nil end
    return { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
end

-- The part of rect R that n covers.
local function sub(R, n)
    return { x = R.x + n.minX * R.w, y = R.y + n.minY * R.h,
             w = (n.maxX - n.minX) * R.w, h = (n.maxY - n.minY) * R.h }
end

-- One axis of a zoom from S to E at progress e. Zooming about the one
-- point that stays still, rather than sliding the corner across, is what
-- makes it read as a camera moving in.
local function zoomAxis(s0, e0, size, k, e)
    local ke = k ^ e
    if math.abs(1 - k) < 0.01 then
        return s0 + (e0 - s0) * e, size * ke
    end
    local fixed = (e0 - k * s0) / (1 - k)
    return fixed + ke * (s0 - fixed), size * ke
end

local function zoomRect(S, E, e)
    local x, w = zoomAxis(S.x, E.x, S.w, E.w / S.w, e)
    local y, h = zoomAxis(S.y, E.y, S.h, E.h / S.h, e)
    return x, y, w, h
end

-- ============================================================
-- The overlay
-- ============================================================

function Zoom:Overlay(wm)
    if self.ov then return self.ov end
    local sc = wm.ScrollContainer
    -- Ours, hung on the map so it shows, hides, scales and fades with it,
    -- and laid over the part that draws the map. It never takes the mouse.
    local ov = CreateFrame("Frame", nil, wm)
    ov:SetAllPoints(sc)
    -- Over every pin while it plays: the game's map has already changed
    -- underneath, and its pins should not sit on our art of the old one.
    local _, top = ns.PinLevels(wm)
    local level = math.min(top + 20, 9500)
    ov:SetFrameLevel(level)
    ov:EnableMouse(false)
    ov:SetClipsChildren(true)
    ov:Hide()
    -- Behind the art, in case a map leaves part of the frame uncovered.
    local back = ov:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 1)
    ov.back = newArt(ov, level + 2)
    ov.front = newArt(ov, level + 4, true)
    ov:SetScript("OnUpdate", function(_, elapsed) Zoom:Step(elapsed) end)
    self.ov = ov
    return ov
end

-- Where the map art sits, in the overlay's units.
function Zoom:Rect()
    local wm, ov = ns.WorldMap(), self.ov
    if not (wm and ov) then return nil end
    local sc = wm.ScrollContainer
    local r = ns.CanvasRect(sc)
    if not r then return nil end
    local k = sc:GetEffectiveScale() / ov:GetEffectiveScale()
    return { x = r.x * k, y = r.y * k, w = r.w * k, h = r.h * k }
end

-- Where a map would sit fitted inside the overlay, for when the canvas
-- cannot be read.
function Zoom:Fit(art)
    local W, H = self.ov:GetWidth(), self.ov:GetHeight()
    if not (W and H and W > 0 and H > 0 and art.w > 0) then return nil end
    local s = math.min(W / art.w, H / art.h)
    local w, h = art.w * s, art.h * s
    return { x = (W - w) / 2, y = (H - h) / 2, w = w, h = h }
end

function Zoom:Stop()
    self.anim = nil
    if self.ov then
        self.ov:Hide()
        self.ov:SetAlpha(1)
    end
end

-- dir is "in" or "out". before and after are where the canvas sat on
-- either side of the change.
function Zoom:Play(dir, fromID, toID, before, after)
    local ov = self.ov
    local parentID, childID = fromID, toID
    if dir == "out" then parentID, childID = toID, fromID end
    local n = rectOnMap(childID, parentID)

    local a = { dir = dir, t = 0, phase = "zoom", target = toID, n = n }
    if n then
        -- The camera: the larger map behind, the smaller drawn where it
        -- sits on it, and the smaller one's rect moving from start to end.
        if not (drawArt(ov.back, parentID) and drawArt(ov.front, childID)) then return end
        before = before or self:Fit(dir == "in" and ov.back or ov.front)
        after = after or self:Fit(dir == "in" and ov.front or ov.back)
        if not (before and after) then return end
        if dir == "in" then
            a.S, a.E = sub(before, n), after
        else
            a.S, a.E = before, sub(after, n)
        end
    else
        -- No known place for one map on the other: the old map grows or
        -- shrinks away while the new one comes in over it.
        if not (drawArt(ov.back, fromID) and drawArt(ov.front, toID)) then return end
        before = before or self:Fit(ov.back)
        after = after or self:Fit(ov.front)
        if not (before and after) then return end
        a.before, a.after = before, after
    end
    self.anim = a
    ov:SetAlpha(1)
    ov.front:SetAlpha(0)
    self:Frame(0)
    ov:Show()
end

-- p is the move's progress, 0 to 1.
function Zoom:Frame(p)
    local a, ov = self.anim, self.ov
    local e = smooth(p)
    if a.n then
        local n = a.n
        local x, y, w, h = zoomRect(a.S, a.E, e)
        local pw = w / (n.maxX - n.minX)
        local ph = h / (n.maxY - n.minY)
        place(ov.back, x - n.minX * pw, y - n.minY * ph, pw)
        place(ov.front, x, y, w)
        -- The smaller map comes in as it grows and goes as it shrinks.
        ov.front:SetAlpha((a.dir == "in") and fadeAt(p) or (1 - fadeAt(p)))
    else
        local grow = a.dir == "in"
        placeAround(ov.back, a.before, grow and (1 + 0.25 * e) or (1 - 0.2 * e))
        placeAround(ov.front, a.after, grow and (0.8 + 0.2 * e) or (1.25 - 0.25 * e))
        ov.front:SetAlpha(fadeAt(p))
    end
end

function Zoom:Step(elapsed)
    local a = self.anim
    local wm = ns.WorldMap()
    -- Something else changed the map meanwhile (a click): let it show.
    if not a or not wm or wm:GetMapID() ~= a.target then self:Stop() return end
    a.t = a.t + (elapsed or 0)
    if a.phase == "zoom" then
        local p = math.min(1, a.t / DURATION)
        self:Frame(p)
        if p >= 1 then a.phase, a.t = "fade", 0 end
    else
        local p = math.min(1, a.t / FADE)
        self.ov:SetAlpha(1 - p)
        if p >= 1 then self:Stop() end
    end
end

-- ============================================================
-- The wheel
-- ============================================================

-- The map under the cursor, asked the way the game's own click asks.
local function mapAt(sc, mapID, x, y)
    local ignore = sc.ShouldNavigateIgnoreZoneMapPositionData and sc:ShouldNavigateIgnoreZoneMapPositionData()
    local ok, info
    if ignore ~= nil then
        ok, info = pcall(C_Map.GetMapInfoAtPosition, mapID, x, y, ignore)
    else
        ok, info = pcall(C_Map.GetMapInfoAtPosition, mapID, x, y)
    end
    return ok and info or nil
end

-- ============================================================
-- Gliding
-- ============================================================
-- The game zooms the world map in one jump a step (its canvas is set to
-- zoom instantly, on both clients), and a new map opens fitted and
-- centred. Here a step glides instead, closing in on one spot that stays
-- put on screen, and a new map opens zoomed so that spot stays put too.
--
-- The spot is chosen when the wheel turns and then held: you, when the
-- cursor is over the part of the map you are in, otherwise whatever is
-- under the cursor (Zoom:Anchor). Holding it, rather than reading the
-- cursor every frame, is what keeps a mouse that drifts mid-zoom from
-- dragging the map about.
--
-- The game's jump has already happened by the time the wheel reaches us,
-- so it is taken back, in the same frame, to where the map stood a frame
-- ago, and glided from there. A glide is a critically damped spring on
-- the zoom, counted in steps of scale: it sets off gently, comes to rest
-- without overshooting, and a notch that comes mid-glide moves its target
-- on while it keeps its speed.
--
-- All of it goes through the canvas's own InstantPanAndZoom(scale, x, y),
-- which zooms about the map point it is given, starting from where the
-- map is now: the map is always in a state the game itself could put it in.

local CENTRE = 0.5   -- each notch in on you brings you this much of the way to the middle

-- The cursor in the scroll frame's units, from its top left, y down.
local function cursorIn(sc)
    local x, y = GetCursorPosition()
    local s = sc:GetEffectiveScale()
    local l, t = sc:GetLeft(), sc:GetTop()
    if not (x and y and l and t and s and s > 0) then return nil end
    return x / s - l, t - y / s
end

-- The map point under the cursor, as fractions of the map.
local function pointUnder(canvas)
    local x, y = GetCursorPosition()
    local s = canvas:GetEffectiveScale()
    local l, t = canvas:GetLeft(), canvas:GetTop()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    if not (x and y and l and t and s and s > 0 and w > 0 and h > 0) then return nil end
    return (x / s - l) / w, (t - y / s) / h
end

local function scroll(sc)
    local x = sc.GetCurrentScrollX and sc:GetCurrentScrollX() or 0.5
    local y = sc.GetCurrentScrollY and sc:GetCurrentScrollY() or 0.5
    return x, y
end

-- Set the map to scale s with the map point (cx, cy) in the middle.
-- InstantPanAndZoom lands the middle at a + (now - a) * ratio, so ask for
-- the a that lands it on c. At the same scale it cannot pan.
local function putAt(sc, s, cx, cy)
    local r = sc:GetCanvasScale() / s
    if math.abs(1 - r) > 1e-6 then
        local nx, ny = scroll(sc)
        cx, cy = (cx - nx * r) / (1 - r), (cy - ny * r) / (1 - r)
    end
    sc:InstantPanAndZoom(s, cx, cy)
end

-- Keep the map exactly where it is. The game's wheel handler aims the map
-- at the spot under the cursor whenever it thinks the zoom can go further
-- in, and past its closest step it always thinks so; without this, every
-- notch at our limit would slide the view across.
local function hold(sc)
    local nx, ny = scroll(sc)
    sc:InstantPanAndZoom(sc:GetCanvasScale(), nx, ny)
end

-- Zoom the map to scale s with map point q at the screen point (ax, ay),
-- in the scroll frame's units from its top left.
local function anchorAt(sc, canvas, s, qx, qy, ax, ay)
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    if not (ax and ay and cw > 0 and ch > 0) then return end
    putAt(sc, s, qx - (ax - sc:GetWidth() / 2) / (cw * s), qy - (ay - sc:GetHeight() / 2) / (ch * s))
end

-- The next of the map's zoom steps past a scale, in or out.
local function nextStep(sc, scale, dir)
    local levels = rawget(sc, "zoomLevels")
    if type(levels) ~= "table" then return nil end
    if dir > 0 then
        for _, z in ipairs(levels) do
            if z.scale > scale + EPS then return z.scale end
        end
    else
        for i = #levels, 1, -1 do
            if levels[i].scale < scale - EPS then return levels[i].scale end
        end
    end
end

-- Where the map stands now, kept every frame, so a jump the game makes
-- can be taken back.
function Zoom:Note(wm)
    local sc = wm.ScrollContainer
    local seen = self.seen or {}
    seen.mapID, seen.scale = wm:GetMapID(), sc:GetCanvasScale()
    seen.x, seen.y = scroll(sc)
    self.seen = seen
end

-- ============================================================
-- What a notch closes in on
-- ============================================================

-- Your spot on a map, as fractions of it, or nil where you are not on it
-- (or the game will not say, inside an instance).
local function playerOn(mapID)
    local M = rawget(_G, "C_Map")
    if not (M and M.GetPlayerMapPosition) then return nil end
    local ok, v = pcall(M.GetPlayerMapPosition, mapID, "player")
    if not (ok and v) then return nil end
    local x, y = v:GetXY()
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and (x > 0 or y > 0) then return x, y end
end

-- The map one level down at a spot, or nil where there is none.
local function childAt(sc, mapID, x, y)
    local info = mapAt(sc, mapID, x, y)
    if info and info.mapID and info.mapID ~= mapID then return info.mapID end
end

-- A map point and the screen point it is kept at: ax0, ay0 where it is
-- now, ax1, ay1 where it ends the glide. You, when the cursor is over the
-- part of the map you are in (your continent on the world map, your zone
-- on a continent, anywhere on your zone), eased toward the middle as the
-- map closes in; otherwise, or with Shift held, the spot under the cursor.
function Zoom:Anchor(wm, delta)
    local sc, canvas = wm.ScrollContainer, ns.Canvas(wm)
    local mapID = wm:GetMapID()
    local cx, cy = cursorIn(sc)
    local qx, qy = pointUnder(canvas)
    local a = { qx = qx, qy = qy, ax0 = cx, ay0 = cy, ax1 = cx, ay1 = cy, mode = "cursor" }
    local db = ns.DB()
    if not (db and db.onPlayer) or IsShiftKeyDown() then return a end
    local px, py = playerOn(mapID)
    if not px then return a end
    if qx and childAt(sc, mapID, qx, qy) ~= childAt(sc, mapID, px, py) then return a end
    local R = ns.CanvasRect(sc)
    if not R then return a end
    local sx, sy = R.x + px * R.w, R.y + py * R.h
    a.qx, a.qy, a.mode = px, py, "player"
    a.ax0, a.ay0, a.ax1, a.ay1 = sx, sy, sx, sy
    if delta > 0 then
        a.ax1 = sx + (sc:GetWidth() / 2 - sx) * CENTRE
        a.ay1 = sy + (sc:GetHeight() / 2 - sy) * CENTRE
    end
    return a
end

-- ============================================================
-- The glide
-- ============================================================

-- Start a glide to scale `to` closing in on anchor `a`, or move the one
-- under way on to them; a glide under way keeps its speed.
function Zoom:ZoomWithin(wm, to, a)
    local sc = wm.ScrollContainer
    -- A level change still playing gives way: the canvas is about to move
    -- under it.
    if self.anim then self:Stop() end
    local mapID = wm:GetMapID()
    local now = sc:GetCanvasScale()
    local g = self.glide
    -- Already heading there (a notch at the end of the zoom): the glide
    -- keeps its spot, rather than taking up wherever the cursor is now.
    if g and g.mapID == mapID and math.abs(to - g.to) <= EPS then return end
    if not (g and g.mapID == mapID) then
        g = { v = 0, mapID = mapID }
        self.glide = g
    end
    g.to, g.x, g.x0 = to, math.log(now), math.log(now)
    g.a = a or self:Anchor(wm, (to > now) and 1 or -1)
    -- Hold the map where it stands: a zoom target the game set going is
    -- dropped, as this replaces it.
    local nx, ny = scroll(sc)
    sc:InstantPanAndZoom(now, nx, ny)
    self.driver:Show()
end

-- One frame of a glide.
function Zoom:Glide(elapsed)
    local g, wm = self.glide, ns.WorldMap()
    if not (g and wm and wm:IsShown() and wm:GetMapID() == g.mapID) then
        self.glide = nil
        self.driver:Hide()
        return
    end
    local sc, canvas = wm.ScrollContainer, ns.Canvas(wm)
    local goal = math.log(g.to)
    -- The spring, solved exactly for the frame's length, so a slow frame
    -- lands where a run of quick ones would have.
    local dt = elapsed or 0
    local y = g.x - goal
    local k = math.exp(-SPRING * dt)
    local c = g.v + SPRING * y
    y, g.v = (y + c * dt) * k, (g.v - SPRING * c * dt) * k
    g.x = goal + y
    local done = math.abs(y) < 0.002 and math.abs(g.v) < 0.05
    if done then g.x = goal end
    local s = done and g.to or math.exp(g.x)
    -- How far through this notch the glide is, to ease the spot across.
    local span = goal - g.x0
    local f = (math.abs(span) > 1e-6) and math.max(0, math.min(1, (g.x - g.x0) / span)) or 1
    local a = g.a
    if a and a.qx and a.ax0 then
        anchorAt(sc, canvas, s, a.qx, a.qy, a.ax0 + (a.ax1 - a.ax0) * f, a.ay0 + (a.ay1 - a.ay0) * f)
    else
        local nx, ny = scroll(sc)
        sc:InstantPanAndZoom(s, nx, ny)
    end
    self:Note(wm)
    if done then
        self.glide = nil
        self.driver:Hide()
    end
end

-- Ask the game to start loading a map's art before it is needed, so the
-- change to it does not wait on the disk.
local function preload(mapID)
    local M = rawget(_G, "C_Map")
    if mapID and M and M.RequestPreloadMap then pcall(M.RequestPreloadMap, mapID) end
end

-- One notch of our own zoom past the game's closest step, in the terrain
-- (Terrain:DeepCap says how far it may go). Out, it comes back down to
-- the game's closest step, where the game's own steps take over again.
function Zoom:Deeper(wm, scale, hi, delta, a)
    local cap = ns.Terrain and ns.Terrain:DeepCap(wm)
    -- Notches faster than the glide go on from where it was heading.
    local g = self.glide
    local from = scale
    if g and g.mapID == wm:GetMapID() and (g.to - scale) * delta > 0 then from = g.to end
    local to
    if delta > 0 then
        if not cap then hold(wm.ScrollContainer) return end
        to = math.min(from * DEEP_STEP, cap)
    else
        to = from / DEEP_STEP
        if to < hi * 1.02 then to = hi end
    end
    -- At the limit the wheel does nothing at all, however long it turns.
    if math.abs(to - scale) > EPS then self:ZoomWithin(wm, to, a) else hold(wm.ScrollContainer) end
end

-- A new map, opened so the anchor's spot stays where it is on screen: at
-- the size the smaller map was drawn before the change, within the new
-- map's zoom.
local function anchorChange(sc, canvas, dir, n, a, oldWidth)
    local nw, nh = n.maxX - n.minX, n.maxY - n.minY
    local cw = canvas:GetWidth()
    if not (cw and cw > 0) then return end
    local want, qx, qy
    if dir == "in" then
        want = nw * oldWidth / cw
        qx, qy = (a.qx - n.minX) / nw, (a.qy - n.minY) / nh
    else
        want = oldWidth / (nw * cw)
        qx, qy = n.minX + a.qx * nw, n.minY + a.qy * nh
    end
    local s = math.max(sc:GetScaleForMinZoom(), math.min(sc:GetScaleForMaxZoom(), want))
    anchorAt(sc, canvas, s, qx, qy, a.ax0, a.ay0)
end

-- ============================================================
-- Changing maps
-- ============================================================

function Zoom:Go(wm, fromID, toID, dir, a)
    self.pauseUntil = GetTime() + PAUSE
    self.glide = nil
    local sc, canvas = wm.ScrollContainer, ns.Canvas(wm)
    a = a or self:Anchor(wm, dir == "in" and 1 or -1)
    local before = self:Rect()
    -- How wide the old map is drawn now, in the scroll frame's units.
    local oldWidth = canvas:GetWidth() * sc:GetCanvasScale()
    local parentID, childID = fromID, toID
    if dir == "out" then parentID, childID = toID, fromID end
    local n = rectOnMap(childID, parentID)
    self:Stop()
    wm:SetMapID(toID)
    -- The map can refuse (a kiosk list); then there is nothing to show.
    if wm:GetMapID() ~= toID then return end
    local db = ns.DB()
    if db and db.anchor and n and a.qx and a.ax0 then
        Core.safe(anchorChange, sc, ns.Canvas(wm), dir, n, a, oldWidth)
    end
    if db and db.animate then
        Core.safe(self.Play, self, dir, fromID, toID, before, self:Rect())
    end
end

function Zoom:OnWheel(delta)
    local db = ns.DB()
    if not db then return end
    local wm = ns.WorldMap()
    if not (wm and wm:IsShown()) then return end
    local mapID = wm:GetMapID()
    if not mapID then return end
    local sc = wm.ScrollContainer
    local smooth = db.anchor and ns.CanChangeMap()

    -- What the game's handler just did, read back.
    local scale = sc:GetCanvasScale()
    local target = rawget(sc, "targetScale") or scale
    local seen = self.seen
    if seen and seen.mapID == mapID and math.abs(target - scale) <= EPS
        and math.abs(seen.scale - scale) > EPS then
        -- The game jumped a step. That notch was the game's zoom, so it
        -- changes nothing else; gliding, the map goes back to where it
        -- stood and the glide goes where the jump landed.
        if not smooth then self:Note(wm) return end
        putAt(sc, seen.scale, seen.x, seen.y)
        scale, target = seen.scale, scale
    end
    local hi = sc:GetScaleForMaxZoom()
    -- The spot this notch closes in on, read with the map back in place.
    local a = self:Anchor(wm, delta)

    -- Past the game's closest step the map is in the terrain, and the
    -- wheel takes our own steps both ways; the game's would jump back.
    if scale > hi + EPS then
        if ns.CanChangeMap() then self:Deeper(wm, scale, hi, delta, a) end
        self:Note(wm)
        return
    end

    -- A step within this map.
    if math.abs(target - scale) > EPS then
        if smooth then
            -- Notches that come faster than the glide each go one step on
            -- from where the last was heading, as they would at rest; one
            -- past the game's closest step goes on into the terrain.
            -- (The game's smooth wheel mode has no steps to go on to.)
            local g = self.glide
            local sm = rawget(_G, "MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_SMOOTH")
            local stepped = sm == nil or rawget(sc, "mouseWheelZoomMode") ~= sm
            if g and g.mapID == mapID and (g.to - scale) * delta > 0 and stepped then
                local on = nextStep(sc, g.to, delta)
                if not on and delta > 0 and g.to >= hi - EPS then
                    local cap = ns.Terrain and ns.Terrain:DeepCap(wm)
                    on = cap and math.min(g.to * DEEP_STEP, cap)
                end
                target = on or g.to
            end
            self:ZoomWithin(wm, target, a)
        end
        -- Arriving at either end of the zoom, start loading the map the
        -- next notch would open.
        if delta > 0 and target >= hi - EPS then
            if a.qx then preload(childAt(sc, mapID, a.qx, a.qy)) end
        elseif delta < 0 and target <= sc:GetScaleForMinZoom() + EPS then
            local info = C_Map.GetMapInfo(mapID)
            if info and info.parentMapID and info.parentMapID > 0 then preload(info.parentMapID) end
        end
        self:Note(wm)
        return
    end

    -- At the end of the map's zoom: the wheel changes maps, or goes on
    -- into the terrain where there is no smaller map to open.
    if not ns.CanChangeMap() then return end
    local paused = GetTime() < (self.pauseUntil or 0)
    if delta > 0 then
        -- Just after a change the wheel waits, so one flick lands on one
        -- level rather than running on past it.
        if scale < hi - EPS or paused then return end
        local x, y = a.qx, a.qy
        if not x then x, y = wm:GetNormalizedCursorPosition() end
        local child = x and y and childAt(sc, mapID, x, y)
        if db.wheel and child then
            self:Go(wm, mapID, child, "in", a)
        else
            self:Deeper(wm, scale, hi, delta, a)
        end
    elseif delta < 0 then
        if not db.wheel or paused then return end
        if scale > sc:GetScaleForMinZoom() + EPS then return end
        local info = C_Map.GetMapInfo(mapID)
        local parent = info and info.parentMapID
        if parent and parent > 0 then
            self:Go(wm, mapID, parent, "out", a)
        end
    end
    self:Note(wm)
end

function Zoom:Attach(wm)
    if self.attached then return end
    self.attached = true
    self:Overlay(wm)
    -- Runs the glide; on the map, so it only runs while the map is open.
    local driver = CreateFrame("Frame", nil, wm)
    driver:Hide()
    driver:SetScript("OnUpdate", function(_, elapsed) Zoom:Glide(elapsed) end)
    self.driver = driver
    -- Notes where the map stands each frame while it is open.
    local watcher = CreateFrame("Frame", nil, wm)
    watcher:SetScript("OnUpdate", function() Zoom:Note(wm) end)
    self.watcher = watcher
    -- After the game's own handler, never instead of it.
    wm.ScrollContainer:HookScript("OnMouseWheel", function(_, delta)
        Core.safe(Zoom.OnWheel, Zoom, delta)
    end)
    wm:HookScript("OnHide", function()
        Zoom:Stop()
        Zoom.glide = nil
        Zoom.seen = nil
        driver:Hide()
    end)
end
