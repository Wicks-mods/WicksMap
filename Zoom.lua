-- Wick's Map
-- Zoom.lua: the mouse wheel moves between map levels, with a zoom between
-- them.
--
-- The game's own wheel handler runs first and zooms within the map where
-- the map allows it. This runs after it, and only acts when the game had
-- nowhere further to go: all the way in, the wheel opens the place under
-- the cursor (the world to a continent, a continent to a zone, a zone to a
-- city); all the way out, it goes up to the map above.
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

local DURATION = 0.32   -- the camera move
local FADE     = 0.14   -- our frame fading off the game's map after it
local PAUSE    = 0.3    -- after a change, the wheel waits this long to change maps again
local EPS      = 0.001  -- how close two canvas scales count as the same

-- ============================================================
-- Map art in a frame of our own
-- ============================================================
-- The base tiles and the explored overlays of one map, laid out at the
-- art's own size, as the game lays out its detail layer and its
-- exploration pin. The whole frame is scaled to put the map anywhere.

local function newArt(parent, level)
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameLevel(level)
    f:SetSize(1, 1)
    f.tex, f.used, f.w, f.h = {}, 0, 1, 1
    return f
end

local function nextTexture(art, layer)
    art.used = art.used + 1
    local t = art.tex[art.used]
    if not t then
        t = art:CreateTexture(nil, layer)
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

local function ease(t) return 1 - (1 - t) ^ 3 end

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
    local level = math.min(sc:GetFrameLevel() + 1200, 9000)
    ov:SetFrameLevel(level)
    ov:EnableMouse(false)
    ov:SetClipsChildren(true)
    ov:Hide()
    -- Behind the art, in case a map leaves part of the frame uncovered.
    local back = ov:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 1)
    ov.back = newArt(ov, level + 2)
    ov.front = newArt(ov, level + 4)
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

function Zoom:Frame(e)
    local a, ov = self.anim, self.ov
    if a.n then
        local n = a.n
        local x, y, w, h = zoomRect(a.S, a.E, e)
        local pw = w / (n.maxX - n.minX)
        local ph = h / (n.maxY - n.minY)
        place(ov.back, x - n.minX * pw, y - n.minY * ph, pw)
        place(ov.front, x, y, w)
        -- The smaller map comes in as it grows and goes as it shrinks.
        local alpha = (a.dir == "in") and (e / 0.7) or ((1 - e) / 0.7)
        ov.front:SetAlpha(math.max(0, math.min(1, alpha)))
    else
        local grow = a.dir == "in"
        placeAround(ov.back, a.before, grow and (1 + 0.25 * e) or (1 - 0.2 * e))
        placeAround(ov.front, a.after, grow and (0.8 + 0.2 * e) or (1.25 - 0.25 * e))
        ov.front:SetAlpha(e)
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
        self:Frame(ease(p))
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

function Zoom:Go(wm, fromID, toID, dir)
    self.pauseUntil = GetTime() + PAUSE
    local before = self:Rect()
    self:Stop()
    wm:SetMapID(toID)
    -- The map can refuse (a kiosk list); then there is nothing to show.
    if wm:GetMapID() ~= toID then return end
    local db = ns.DB()
    if db and db.animate then
        Core.safe(self.Play, self, dir, fromID, toID, before, self:Rect())
    end
end

function Zoom:OnWheel(delta)
    local db = ns.DB()
    if not (db and db.wheel) then return end
    if GetTime() < (self.pauseUntil or 0) then return end
    local wm = ns.WorldMap()
    if not (wm and wm:IsShown()) then return end
    local mapID = wm:GetMapID()
    if not mapID then return end
    local sc = wm.ScrollContainer

    -- What the game's handler just did, read back. If it set a zoom
    -- going, or the map is not yet at the end of its zoom, the wheel
    -- belonged to the game this time.
    local scale = sc:GetCanvasScale()
    local target = rawget(sc, "targetScale") or scale
    if delta > 0 then
        local hi = sc:GetScaleForMaxZoom()
        if scale < hi - EPS or target > scale + EPS then return end
        if not ns.CanChangeMap() then return end
        local x, y = wm:GetNormalizedCursorPosition()
        local info = x and y and mapAt(sc, mapID, x, y)
        if info and info.mapID and info.mapID ~= mapID then
            self:Go(wm, mapID, info.mapID, "in")
        end
    elseif delta < 0 then
        local lo = sc:GetScaleForMinZoom()
        if scale > lo + EPS or target < scale - EPS then return end
        if not ns.CanChangeMap() then return end
        local info = C_Map.GetMapInfo(mapID)
        local parent = info and info.parentMapID
        if parent and parent > 0 then
            self:Go(wm, mapID, parent, "out")
        end
    end
end

function Zoom:Attach(wm)
    if self.attached then return end
    self.attached = true
    self:Overlay(wm)
    -- After the game's own handler, never instead of it.
    wm.ScrollContainer:HookScript("OnMouseWheel", function(_, delta)
        Core.safe(Zoom.OnWheel, Zoom, delta)
    end)
    wm:HookScript("OnHide", function() Zoom:Stop() end)
end
