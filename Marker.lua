-- Wick's Map
-- Marker.lua: the waypoint, one place to head for at a time.
--
-- Where the game has a waypoint of its own (Forever), the marker is that
-- waypoint, tracked, so the game draws it on the world map and the
-- minimap. Where it has none (TBC), or the realm's rules switch it off,
-- the marker is ours, a pin drawn over the map. Either way a small window
-- with an arrow and the distance in yards points to it (the game draws no
-- guide in the world on Forever, as it is set up) and puts the marker
-- away when you get there.
--
-- It is set from the right-click menu on the world map and from a pin
-- (Pins.lua), or with /wmap x y.

local ADDON, ns = ...
if not WickCore then return end

local Core, Chrome = WickCore, WickCore.Chrome
local C = Chrome.Colors

local Marker = {}
ns.Marker = Marker

local CIRCLE   = "Interface\\AddOns\\WickCore\\Media\\Textures\\mask-circle.png"
local NEAR_PX  = 14    -- a click this close to the marker counts as on it
local ARRIVE   = 8     -- yards: close enough to count as there
local TICK     = 0.1   -- how often the arrow updates

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
-- Heading for one of your pins: the pin is the destination, kept by us on
-- every client, with no waypoint of the game's drawn on top of it.
function Marker:PinID()
    local m = ns.DB() and ns.DB().marker
    return m and m.pin
end

function Marker:Get()
    local m = ns.DB() and ns.DB().marker
    if m and m.pin and m.mapID then return m.mapID, m.x, m.y end
    if self:Native() then
        if C_Map.HasUserWaypoint and not C_Map.HasUserWaypoint() then return nil end
        local p = C_Map.GetUserWaypoint()
        if p and p.uiMapID and p.position then
            local x, y = p.position:GetXY()
            return p.uiMapID, x, y
        end
        return nil
    end
    if m and m.mapID then return m.mapID, m.x, m.y end
end

function Marker:Has() return self:Get() ~= nil end

-- Where the marker falls on another map, as fractions of it, or nil.
function Marker:PosOn(mapID)
    local mm, mx, my = self:Get()
    if not mm then return nil end
    if mm == mapID then return mx, my end
    if self:Native() and not self:PinID() and C_Map.GetUserWaypointPositionForMap then
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

-- label: what the arrow window calls the place (a pin's name), or nil
-- for the name of the map.
function Marker:Set(mapID, x, y, label)
    local m, mx, my = ns.Descend(mapID, x, y, accepts)
    if not m then
        ns.A:Print(("a waypoint cannot go there on %s. Zoom in to a zone and try again."):format(ns.MapName(mapID)))
        return false
    end
    -- One place to head for at a time: this replaces a pin being headed for.
    if self:Native() then
        ns.DB().marker = nil
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, mx, my))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    else
        ns.DB().marker = { mapID = m, x = mx, y = my, label = label }
    end
    ns.Dirty()
    self.label = label
    self.arrowClosed = nil
    sound("place")
    self:Refresh()
    return true
end

-- Head for one of your pins. It replaces any waypoint, the game's too, so
-- there is one place to head for and nothing drawn over the pin.
function Marker:HeadToPin(p)
    if self:Native() and C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() then
        C_Map.ClearUserWaypoint()
        C_SuperTrack.SetSuperTrackedUserWaypoint(false)
    end
    ns.DB().marker = { mapID = p.mapID, x = p.x, y = p.y, label = p.title, pin = p.id }
    ns.Dirty()
    self.label = nil
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
    self.label = nil
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

-- What the waypoint is called, when it was set for a pin.
function Marker:Label()
    if not self:Has() then return nil end
    local m = ns.DB().marker
    if m then return m.label end
    return self.label
end

-- One line for tooltips: where, and how far.
function Marker:Describe()
    local mm, mx, my = self:Get()
    if not mm then return nil end
    local s = ("%s  %.1f, %.1f"):format(self:Label() or ns.MapName(mm), mx * 100, my * 100)
    local d = self:Bearing()
    if d then s = s .. "  (" .. yards(d) .. ")" end
    return s
end

-- ============================================================
-- Our own marker: the pin on the map
-- ============================================================

function Marker:PinLayer(wm)
    if self.layer then return self.layer end
    local sc = wm.ScrollContainer
    -- Laid over the part that draws the map, above the map's pins (the
    -- explored areas a zone draws over its art are pins too, and would
    -- cover it) and under the zoom overlay. It takes no mouse itself; only
    -- the pin does.
    local layer = CreateFrame("Frame", nil, wm)
    layer:SetAllPoints(sc)
    local _, top = ns.PinLevels(wm)
    layer:SetFrameLevel(math.min(top + 10, 9400))
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
    f.where:SetText(self:Label() or ns.MapName(mm))
    local d, bearing = self:Bearing()
    if not d then
        f.dist:SetText(bearing == "elsewhere" and "Another continent" or "Unknown")
        f.arrow:SetAlpha(0.25)
        f.arrow:SetRotation(0)
        return
    end
    local db = ns.DB()
    if d <= ARRIVE and db.autoClear then
        ns.A:Print("you reached your waypoint.")
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
    -- Our marker shows for a spot of our own; the game draws its waypoint,
    -- and a pin being headed for glows instead.
    if self.layer then
        self.layer:SetShown(has and not native and not self:PinID())
    end
    if ns.Pins then ns.Pins:Changed() end
    local db = ns.DB()
    -- The arrow for every waypoint, the game's own too: the game may draw
    -- no guide to it in the world (Forever does not, as it is set up).
    local wantArrow = has and db and db.arrow and not self.arrowClosed
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
    -- Heading for a pin that has gone since (deleted on another character).
    local id = self:PinID()
    if id and ns.Pins and not ns.Pins:Get(id) then ns.DB().marker = nil end
    self:Refresh()
end

function Marker:Attach(wm)
    if self.attached then return end
    self.attached = true
    self:PinLayer(wm)
    -- The game's waypoint can change without us (its own map pin button,
    -- a shared waypoint link).
    if C_Map.SetUserWaypoint then
        ns.A:On("USER_WAYPOINT_UPDATED", function()
            -- A waypoint the game set (its own map pin button, a shared
            -- link) is the newest place to head for.
            if C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() and Marker:PinID() then
                ns.DB().marker = nil
            end
            Marker:Refresh()
        end)
    end
    self:Refresh()
end
