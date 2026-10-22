-- Wick's Map
-- Marker.lua: right-click the world map to drop a marker.
--
-- Where the game has a waypoint of its own (Forever), the marker is that
-- waypoint, tracked, so the game draws it on the map, on the minimap and
-- in the world with the distance to it. Where it has none (TBC), or the
-- realm's rules switch it off, the marker is ours: a pin drawn over the
-- map and a small window with an arrow and the distance in yards, which
-- puts the marker away when you get there.
--
-- The right-click comes in through the map's canvas click handlers, the
-- place the map keeps for addons. Answering true there is what stops the
-- same click going up a level, as a right-click otherwise does. Shift
-- lets it through.

local ADDON, ns = ...
if not WickCore then return end

local Core, Chrome = WickCore, WickCore.Chrome
local C = Chrome.Colors

local Marker = {}
ns.Marker = Marker

local CIRCLE   = "Interface\\AddOns\\WickCore\\Media\\Textures\\mask-circle.png"
local NEAR_PX  = 14    -- a right-click this close to the marker takes it away
local ARRIVE   = 8     -- yards: close enough to count as there
local TICK     = 0.1   -- how often the arrow updates

-- Enum.UIMapType: a marker goes on a zone or deeper where it can.
local MAP_ZONE = 3

local function sound(kind)
    local K = rawget(_G, "SOUNDKIT")
    if not K then return end
    local id = (kind == "place") and (K.UI_MAP_WAYPOINT_CLICK_TO_PLACE or K.IG_MAINMENU_OPTION_CHECKBOX_ON)
        or (K.UI_MAP_WAYPOINT_REMOVE or K.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    if id then PlaySound(id) end
end

-- ============================================================
-- Which kind of marker
-- ============================================================

-- The game's waypoint, when this client has it and the realm allows it.
function Marker:Native()
    local M, ST = rawget(_G, "C_Map"), rawget(_G, "C_SuperTrack")
    if not (M and M.SetUserWaypoint and M.ClearUserWaypoint and M.CanSetUserWaypointOnMap
        and M.GetUserWaypoint and rawget(_G, "UiMapPoint") and ST and ST.SetSuperTrackedUserWaypoint) then
        return false
    end
    local GR, E = rawget(_G, "C_GameRules"), rawget(_G, "Enum")
    local rule = E and E.GameRule and E.GameRule.WorldMapTrackingPinDisabled
    if GR and GR.IsGameRuleActive and rule then
        local ok, off = pcall(GR.IsGameRuleActive, rule)
        if ok and off then return false end
    end
    return true
end

-- The marker as map, x, y (fractions of that map), or nil.
function Marker:Get()
    if self:Native() then
        if C_Map.HasUserWaypoint and not C_Map.HasUserWaypoint() then return nil end
        local p = C_Map.GetUserWaypoint()
        if p and p.uiMapID and p.position then
            local x, y = p.position:GetXY()
            return p.uiMapID, x, y
        end
        return nil
    end
    local m = ns.DB() and ns.DB().marker
    if m and m.mapID then return m.mapID, m.x, m.y end
end

function Marker:Has() return self:Get() ~= nil end

-- Where the marker falls on another map, as fractions of it, or nil.
function Marker:PosOn(mapID)
    local mm, mx, my = self:Get()
    if not mm then return nil end
    if mm == mapID then return mx, my end
    if self:Native() and C_Map.GetUserWaypointPositionForMap then
        local ok, v = pcall(C_Map.GetUserWaypointPositionForMap, mapID)
        if ok and v then return v:GetXY() end
        return nil
    end
    local cont, pos = ns.WorldPos(mm, mx, my)
    return ns.MapPos(cont, pos, mapID)
end

-- ============================================================
-- Dropping and clearing
-- ============================================================

-- A click on a map too large to hold a marker (the world, a continent
-- where the game wants a zone) goes to the map under the cursor instead,
-- at the same spot.
local function accepts(mapID)
    if Marker:Native() then
        local ok, yes = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
        return ok and yes
    end
    return ns.WorldPos(mapID, 0.5, 0.5) ~= nil
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

local function resolve(mapID, x, y)
    for _ = 1, 4 do
        local info = C_Map.GetMapInfo(mapID)
        local small = info and (info.mapType or MAP_ZONE) >= MAP_ZONE
        if small and accepts(mapID) then return mapID, x, y end
        local ok, child = pcall(C_Map.GetMapInfoAtPosition, mapID, x, y)
        if not (ok and child and child.mapID and child.mapID ~= mapID) then break end
        local cx, cy = down(mapID, child.mapID, x, y)
        if not cx then break end
        mapID, x, y = child.mapID, cx, cy
    end
    if accepts(mapID) then return mapID, x, y end
end

function Marker:Set(mapID, x, y)
    local m, mx, my = resolve(mapID, x, y)
    if not m then
        ns.A:Print(("a marker cannot go there on %s. Zoom in to a zone and try again."):format(ns.MapName(mapID)))
        return false
    end
    if self:Native() then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, mx, my))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    else
        ns.DB().marker = { mapID = m, x = mx, y = my }
        ns.Dirty()
    end
    self.arrowClosed = nil
    sound("place")
    self:Refresh()
    return true
end

function Marker:Clear()
    if self:Native() then
        C_Map.ClearUserWaypoint()
        C_SuperTrack.SetSuperTrackedUserWaypoint(false)
    end
    local db = ns.DB()
    if db and db.marker then
        db.marker = nil
        ns.Dirty()
    end
    sound("clear")
    self:Refresh()
end

-- Within a few pixels of the marker, as drawn on this map.
function Marker:IsNear(mapID, x, y)
    local mx, my = self:PosOn(mapID)
    if not mx then return false end
    local wm = ns.WorldMap()
    local r = wm and ns.CanvasRect(wm.ScrollContainer)
    if not r then return math.abs(mx - x) < 0.015 and math.abs(my - y) < 0.015 end
    local dx, dy = (mx - x) * r.w, (my - y) * r.h
    return dx * dx + dy * dy <= NEAR_PX * NEAR_PX
end

-- The canvas click handler. true stops the game handling the click.
local function onCanvasClick(map, button, x, y)
    if button ~= "RightButton" then return false end
    local db = ns.DB()
    if not (db and db.rightClick) or IsShiftKeyDown() then return false end
    local mapID = map and map.GetMapID and map:GetMapID()
    if not (mapID and x and y) then return false end
    if Marker:IsNear(mapID, x, y) then
        Marker:Clear()
    else
        Marker:Set(mapID, x, y)
    end
    return true
end
Marker.OnCanvasClick = onCanvasClick

-- ============================================================
-- Our own marker: distance and direction
-- ============================================================

-- Which way east and south run in world coordinates on a map, found by
-- asking where two of its corners are, so nothing depends on which
-- component of a world position the client calls x.
local axesCache = {}
local function axes(mapID)
    local hit = axesCache[mapID]
    if hit ~= nil then return hit or nil end
    local _, a = ns.WorldPos(mapID, 0, 0)
    local _, b = ns.WorldPos(mapID, 1, 0)
    local _, c = ns.WorldPos(mapID, 0, 1)
    local out = false
    if a and b and c then
        local ax, ay = a:GetXY()
        local bx, by = b:GetXY()
        local cx, cy = c:GetXY()
        local ex, ey = bx - ax, by - ay
        local sx, sy = cx - ax, cy - ay
        local el, sl = math.sqrt(ex * ex + ey * ey), math.sqrt(sx * sx + sy * sy)
        if el > 0 and sl > 0 then
            out = { ex = ex / el, ey = ey / el, sx = sx / sl, sy = sy / sl }
        end
    end
    axesCache[mapID] = out
    return out or nil
end

-- Yards to the marker, and its bearing counter-clockwise from north (the
-- way GetPlayerFacing measures), or nil while the player's position is
-- unknown (inside an instance) or on another continent.
function Marker:Bearing()
    local mm, mx, my = self:Get()
    if not mm then return nil end
    local pm = C_Map.GetBestMapForUnit("player")
    local pp = pm and C_Map.GetPlayerMapPosition(pm, "player")
    if not pp then return nil end
    local px, py = pp:GetXY()
    local pc, pw = ns.WorldPos(pm, px, py)
    local mc, mw = ns.WorldPos(mm, mx, my)
    if not (pw and mw) then return nil end
    if pc ~= mc then return nil, "elsewhere" end
    local ax = axes(mm)
    if not ax then return nil end
    local wx1, wy1 = pw:GetXY()
    local wx2, wy2 = mw:GetXY()
    local dx, dy = wx2 - wx1, wy2 - wy1
    local east = dx * ax.ex + dy * ax.ey
    local south = dx * ax.sx + dy * ax.sy
    return math.sqrt(dx * dx + dy * dy), math.atan2(-east, -south)
end

local function yards(d)
    if d >= 1000 then return ("%.1fk yd"):format(d / 1000) end
    return ("%d yd"):format(math.floor(d + 0.5))
end

-- One line for tooltips: where, and how far.
function Marker:Describe()
    local mm, mx, my = self:Get()
    if not mm then return nil end
    local s = ("%s  %.1f, %.1f"):format(ns.MapName(mm), mx * 100, my * 100)
    if not self:Native() then
        local d = self:Bearing()
        if d then s = s .. "  (" .. yards(d) .. ")" end
    end
    return s
end

-- ============================================================
-- Our own marker: the pin on the map
-- ============================================================

function Marker:PinLayer(wm)
    if self.layer then return self.layer end
    local sc = wm.ScrollContainer
    -- Laid over the part that draws the map, under the zoom overlay. It
    -- takes no mouse itself; only the pin does.
    local layer = CreateFrame("Frame", nil, wm)
    layer:SetAllPoints(sc)
    layer:SetFrameLevel(math.min(sc:GetFrameLevel() + 1000, 8800))
    layer:EnableMouse(false)
    layer:SetClipsChildren(true)
    layer:Hide()

    local pin = CreateFrame("Frame", nil, layer)
    pin:SetSize(22, 22)
    pin:SetFrameLevel(layer:GetFrameLevel() + 2)
    local glow = pin:CreateTexture(nil, "BACKGROUND")
    glow:SetTexture(Chrome.Media.glow)
    glow:SetPoint("CENTER")
    glow:SetSize(30, 30)
    glow:SetVertexColor(C.fel[1], C.fel[2], C.fel[3], 0.8)
    Chrome:Register(glow, C.fel, "vertex", 0.8)
    local ring = pin:CreateTexture(nil, "BORDER")
    ring:SetTexture(CIRCLE)
    ring:SetPoint("CENTER")
    ring:SetSize(16, 16)
    ring:SetVertexColor(C.void[1], C.void[2], C.void[3], 1)
    Chrome:Register(ring, C.void, "vertex", 1)
    local dot = pin:CreateTexture(nil, "ARTWORK")
    dot:SetTexture(CIRCLE)
    dot:SetPoint("CENTER")
    dot:SetSize(10, 10)
    dot:SetVertexColor(C.fel[1], C.fel[2], C.fel[3], 1)
    Chrome:Register(dot, C.fel, "vertex", 1)

    pin:EnableMouse(true)
    pin:SetScript("OnEnter", function(p)
        GameTooltip:SetOwner(p, "ANCHOR_RIGHT")
        GameTooltip:AddLine(Chrome:TitleMarkup("Wick's Map"))
        local line = Marker:Describe()
        local c = C.text
        if line then GameTooltip:AddLine("Your marker: " .. line, c[1], c[2], c[3]) end
        GameTooltip:AddLine("Right-click to take it away.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then GameTooltip:Hide(); Marker:Clear() end
    end)
    layer.pin = pin

    layer:SetScript("OnUpdate", function() Marker:PlacePin() end)
    self.layer = layer
    return layer
end

-- Put the pin where the marker falls on the map being shown. Every frame
-- while the map is open, because the game can zoom and pan under it.
function Marker:PlacePin()
    local layer, wm = self.layer, ns.WorldMap()
    if not (layer and wm) then return end
    local mapID = wm:GetMapID()
    if mapID ~= self.pinMap then
        self.pinMap = mapID
        self.pinX, self.pinY = self:PosOn(mapID)
    end
    local x, y = self.pinX, self.pinY
    local r = ns.CanvasRect(wm.ScrollContainer)
    local pin = layer.pin
    if not (x and y and r) or x < 0 or x > 1 or y < 0 or y > 1 then pin:Hide() return end
    local k = wm.ScrollContainer:GetEffectiveScale() / layer:GetEffectiveScale()
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", layer, "TOPLEFT", (r.x + x * r.w) * k, -(r.y + y * r.h) * k)
    pin:Show()
end

-- ============================================================
-- Our own marker: the arrow window
-- ============================================================

function Marker:ArrowWindow()
    if self.win then return self.win end
    -- No global name, so Escape leaves it alone: Escape is how a player
    -- drops a target, and the arrow should not go with it.
    local f = Chrome:NewPanel(nil, { title = "Wick's Map", width = 190, height = 92 })
    f:SetFrameStrata("MEDIUM")
    f.db = ns.DB().arrowWin
    f:ClearAllPoints()
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    Chrome:RestorePosition(f, f.db)
    ns.A:RegisterMovable(f, { key = "map_arrow", title = "Map marker arrow" })

    local body = f.content or f
    local arrow = body:CreateTexture(nil, "ARTWORK")
    arrow:SetTexture(Chrome:Glyph("up"))
    arrow:SetSize(44, 44)
    arrow:SetPoint("LEFT", body, "LEFT", 0, 0)
    arrow:SetVertexColor(C.fel[1], C.fel[2], C.fel[3], 1)
    Chrome:Register(arrow, C.fel, "vertex", 1)
    f.arrow = arrow

    f.dist = Chrome:Text(body, 16)
    f.dist:SetPoint("TOPLEFT", arrow, "TOPRIGHT", 8, -2)
    f.dist:SetJustifyH("LEFT")
    f.where = Chrome:Text(body, 10, C.muted)
    f.where:SetPoint("TOPLEFT", f.dist, "BOTTOMLEFT", 0, -3)
    f.where:SetPoint("RIGHT", body, "RIGHT", -2, 0)
    f.where:SetJustifyH("LEFT")
    if f.where.SetWordWrap then f.where:SetWordWrap(false) end

    -- Closing the window puts the arrow away for this marker only. The
    -- next marker brings it back.
    f:HookScript("OnHide", function()
        if Marker:Has() and not Marker.refreshing then Marker.arrowClosed = true end
    end)
    f:EnableMouse(true)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Marker:Clear() end
    end)

    local acc = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < TICK then return end
        acc = 0
        Marker:UpdateArrow()
    end)
    self.win = f
    return f
end

function Marker:UpdateArrow()
    local f = self.win
    if not f then return end
    local mm = self:Get()
    if not mm then self:Refresh() return end
    f.where:SetText(ns.MapName(mm))
    local d, bearing = self:Bearing()
    if not d then
        f.dist:SetText(bearing == "elsewhere" and "Another continent" or "Unknown")
        f.arrow:SetAlpha(0.25)
        f.arrow:SetRotation(0)
        return
    end
    local db = ns.DB()
    if d <= ARRIVE and db.autoClear then
        ns.A:Print("you reached your marker.")
        self:Clear()
        return
    end
    f.dist:SetText(yards(d))
    local facing = GetPlayerFacing and GetPlayerFacing()
    if facing and not Core.Restrict:IsSecret(facing) then
        f.arrow:SetAlpha(1)
        f.arrow:SetRotation(bearing - facing)
    else
        f.arrow:SetAlpha(0.25)
        f.arrow:SetRotation(0)
    end
end

-- ============================================================
-- Showing what there is
-- ============================================================

function Marker:Refresh()
    self.pinMap = nil
    local has, native = self:Has(), self:Native()
    if self.layer then
        self.layer:SetShown(has and not native)
    end
    local db = ns.DB()
    local wantArrow = has and not native and db and db.arrow and not self.arrowClosed
    if wantArrow then
        self:ArrowWindow():Show()
        self:UpdateArrow()
    elseif self.win then
        self.refreshing = true
        self.win:Hide()
        self.refreshing = nil
    end
end

-- At login: a marker of ours from last time comes back. A game waypoint
-- left over on a client that has one stays the game's.
function Marker:Restore()
    self:Refresh()
end

function Marker:Attach(wm)
    if self.attached then return end
    self.attached = true
    self:PinLayer(wm)
    if wm.AddCanvasClickHandler then
        -- Above the game's own handlers, so a right-click reaches us first.
        wm:AddCanvasClickHandler(onCanvasClick, 100)
    end
    -- The game's waypoint can change without us (its own map pin button,
    -- a shared waypoint link).
    if C_Map.SetUserWaypoint then
        ns.A:On("USER_WAYPOINT_UPDATED", function() Marker:Refresh() end)
    end
    self:Refresh()
end
