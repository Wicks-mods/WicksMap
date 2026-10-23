-- Wick's Map
-- Pins.lua: pins of your own for places worth finding again, and the
-- right-click menu on the world map that makes them.
--
-- A pin is a spot on a map with a name, an optional note and one of the
-- eight raid marker icons. Pins are kept account-wide, between sessions,
-- and drawn over the game's own map icons on the map they were made on,
-- on any smaller map that holds the spot, and (smaller) on the continent.
-- Hover one to read it, left-click it to head there, right-click it to
-- change or delete it. A pin you head for is the destination itself (it
-- glows, and the arrow in Marker.lua points to it), so deleting it stops
-- the heading too.
--
-- Right-click the world map for the menu: add a pin here, set a waypoint
-- here, clear the waypoint. The right-click comes in through the map's
-- canvas click handlers, the place the map keeps for addons; answering
-- true there is what stops it going up a level, as a right-click
-- otherwise does. Shift lets it through.

local ADDON, ns = ...
if not WickCore then return end

local Core, Chrome = WickCore, WickCore.Chrome
local C = Chrome.Colors

local Pins = {}
ns.Pins = Pins

local ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local ICONS = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local CIRCLE = "Interface\\AddOns\\WickCore\\Media\\Textures\\mask-circle.png"
local PIN_SIZE = 18
local ON_CONTINENT = 0.75   -- a pin drawn on a continent, this much of its size
local MAP_CONTINENT, MAP_ZONE = 2, 3

Pins.ICONS = ICONS
function Pins.IconPath(i) return ICON:format(i or 1) end

-- ============================================================
-- The pins themselves
-- ============================================================

function Pins:All()
    local db = ns.DB()
    return db and db.pins or {}
end

function Pins:Get(id)
    for _, p in ipairs(self:All()) do
        if p.id == id then return p end
    end
end

function Pins:Add(mapID, x, y, title, icon, note)
    local db = ns.DB()
    local p = { id = db.nextPin or 1, mapID = mapID, x = x, y = y,
                title = title, icon = icon or 1, note = (note ~= "" and note) or nil }
    db.nextPin = p.id + 1
    db.pins[#db.pins + 1] = p
    ns.Dirty()
    self:Changed()
    return p
end

function Pins:Change(p, title, icon, note)
    p.title, p.icon, p.note = title, icon or p.icon, (note ~= "" and note) or nil
    -- Heading for it: the arrow window takes the new name.
    local m = ns.DB().marker
    if m and m.pin == p.id then
        m.label = p.title
        ns.Marker:Refresh()
    end
    ns.Dirty()
    self:Changed()
end

function Pins:Remove(p)
    local list = self:All()
    for i, q in ipairs(list) do
        if q == p then table.remove(list, i) break end
    end
    -- Heading for it: there is nowhere to head for now.
    if ns.Marker:PinID() == p.id then ns.Marker:Clear() end
    ns.Dirty()
    self:Changed()
end

function Pins:IsDestination(p)
    return p ~= nil and ns.Marker:PinID() == p.id
end

function Pins:Changed()
    self.shownOn, self.last = nil, nil
end

-- The name of the place at a spot: the explored area there, else the map.
local function placeName(mapID, x, y)
    local E = rawget(_G, "C_MapExplorationInfo")
    if E and E.GetExploredAreaIDsAtPosition then
        local ok, ids = pcall(E.GetExploredAreaIDsAtPosition, mapID, ns.Vector(x, y))
        local area = ok and type(ids) == "table" and ids[1]
        local name = area and C_Map.GetAreaInfo and C_Map.GetAreaInfo(area)
        if name and name ~= "" then return name end
    end
    return ns.MapName(mapID)
end
Pins.PlaceName = placeName

-- A pin goes on a zone or smaller where the click allows: a click on a
-- continent goes down to the zone under it.
local function holds(mapID) return ns.WorldPos(mapID, 0.5, 0.5) ~= nil end
function Pins.Spot(mapID, x, y) return ns.Descend(mapID, x, y, holds) end

-- Where a pin falls on another map, as fractions of it, or nil.
local function posOn(p, mapID)
    if p.mapID == mapID then return p.x, p.y end
    local cont, pos = ns.WorldPos(p.mapID, p.x, p.y)
    return ns.MapPos(cont, pos, mapID)
end

-- ============================================================
-- Drawing them on the map
-- ============================================================
-- Over the part of the map that draws it, above the game's own icons,
-- placed each frame from where the canvas sits, so they follow every pan
-- and zoom at the same size on screen.

local function tooltip(f)
    local p = f.pin
    if not p then return end
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    GameTooltip:AddLine(p.title or "Pin", C.fel[1], C.fel[2], C.fel[3])
    if p.note then GameTooltip:AddLine(p.note, C.text[1], C.text[2], C.text[3], true) end
    GameTooltip:AddLine(("%s  %.1f, %.1f"):format(ns.MapName(p.mapID), p.x * 100, p.y * 100), 0.56, 0.53, 0.44)
    GameTooltip:AddLine(Pins:IsDestination(p) and "Heading here. Left-click: stop   Right-click: change"
        or "Left-click: head here   Right-click: change", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function newPin(layer)
    local f = CreateFrame("Frame", nil, layer)
    f:SetSize(PIN_SIZE, PIN_SIZE)
    local back = f:CreateTexture(nil, "BACKGROUND")
    back:SetTexture(CIRCLE)
    back:SetPoint("TOPLEFT", -2, 2)
    back:SetPoint("BOTTOMRIGHT", 2, -2)
    back:SetVertexColor(C.void[1], C.void[2], C.void[3], 0.85)
    Chrome:Register(back, C.void, "vertex", 0.85)
    -- A soft ring of the accent on the pin you are heading for.
    local glow = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    glow:SetTexture(Chrome.Media.glow)
    glow:SetPoint("TOPLEFT", -9, 9)
    glow:SetPoint("BOTTOMRIGHT", 9, -9)
    glow:SetVertexColor(C.fel[1], C.fel[2], C.fel[3], 1)
    Chrome:Register(glow, C.fel, "vertex", 1)
    glow:Hide()
    f.glow = glow
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    f.icon = icon
    f:EnableMouse(true)
    f:SetScript("OnEnter", tooltip)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnMouseUp", function(self, button)
        GameTooltip:Hide()
        if not self.pin then return end
        if button == "RightButton" then
            Pins:PinMenu(self.pin)
        elseif button == "LeftButton" then
            Pins:HeadTo(self.pin)
        end
    end)
    return f
end

function Pins:Layer(wm)
    if self.layer then return self.layer end
    local sc = wm.ScrollContainer
    local _, top = ns.PinLevels(wm)
    local layer = CreateFrame("Frame", nil, wm)
    layer:SetAllPoints(sc)
    -- Over the game's icons, under the waypoint and the zoom overlay.
    layer:SetFrameLevel(math.min(top + 6, 9300))
    layer:EnableMouse(false)
    layer:SetClipsChildren(true)
    layer:SetScript("OnUpdate", function() Pins:Place() end)
    self.layer, self.frames, self.visible = layer, {}, {}
    return layer
end

-- Which pins show on a map, and where.
function Pins:Collect(mapID)
    self.shownOn = mapID
    local visible = {}
    local info = C_Map.GetMapInfo(mapID)
    local kind = info and info.mapType
    local db = ns.DB()
    if kind and kind >= MAP_CONTINENT and not (kind == MAP_CONTINENT and not db.continentPins) then
        local size = (kind == MAP_CONTINENT) and PIN_SIZE * ON_CONTINENT or PIN_SIZE
        for _, p in ipairs(self:All()) do
            local x, y = posOn(p, mapID)
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                visible[#visible + 1] = { pin = p, x = x, y = y, size = size }
            end
        end
    end
    self.visible = visible
    for i, e in ipairs(visible) do
        local f = self.frames[i] or newPin(self.layer)
        self.frames[i] = f
        f.pin = e.pin
        f.icon:SetTexture(ICON:format(e.pin.icon or 1))
        f.glow:SetShown(Pins:IsDestination(e.pin))
        f:SetSize(e.size, e.size)
        f:Show()
    end
    for i = #visible + 1, #self.frames do
        self.frames[i].pin = nil
        self.frames[i]:Hide()
    end
end

function Pins:Place()
    local wm, layer = ns.WorldMap(), self.layer
    if not (wm and layer) then return end
    local mapID = wm:GetMapID()
    if mapID ~= self.shownOn then self:Collect(mapID) self.last = nil end
    local sc = wm.ScrollContainer
    local R = ns.CanvasRect(sc)
    if not R then return end
    local last = self.last
    if last and last.x == R.x and last.y == R.y and last.w == R.w then return end
    self.last = { x = R.x, y = R.y, w = R.w }
    local k = sc:GetEffectiveScale() / layer:GetEffectiveScale()
    for i, e in ipairs(self.visible) do
        local f = self.frames[i]
        f:ClearAllPoints()
        f:SetPoint("CENTER", layer, "TOPLEFT", (R.x + e.x * R.w) * k, -(R.y + e.y * R.h) * k)
    end
end

-- ============================================================
-- Heading for one
-- ============================================================

-- Head for a pin, or, if it is where you are heading already, stop.
function Pins:HeadTo(p)
    if self:IsDestination(p) then
        ns.Marker:Clear()
        ns.A:Print(("stopped heading for %s%s|r."):format(Chrome:Esc("fel"), p.title or "your pin"))
        return
    end
    ns.Marker:HeadToPin(p)
    ns.A:Print(("heading for %s%s|r."):format(Chrome:Esc("fel"), p.title or "your pin"))
end

-- ============================================================
-- The right-click menu
-- ============================================================
-- In the suite's chrome, at the cursor, over everything (TOOLTIP strata,
-- as Wick's Ledger does it). It goes away when the cursor leaves it, when
-- a line is picked, or when the map closes.

local ROW_H, MENU_W = 22, 190

local function buildMenu()
    local m = CreateFrame("Frame", "WicksMapMenu", UIParent)
    m:SetFrameStrata("TOOLTIP")
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    local bg = Chrome:Texture(m, "BACKGROUND", C.voidBG)
    bg:SetAllPoints()
    Chrome:AddBorder(m)
    m.title = Chrome:Text(m, 11, C.muted)
    m.title:SetPoint("TOPLEFT", 10, -7)
    m.title:SetPoint("RIGHT", m, "RIGHT", -10, 0)
    m.title:SetJustifyH("LEFT")
    if m.title.SetWordWrap then m.title:SetWordWrap(false) end
    m.rows = {}
    m:Hide()
    -- Away from it for a moment, it closes: a slip of the mouse does not.
    local away = 0
    m:SetScript("OnUpdate", function(self, elapsed)
        if self:IsMouseOver(10, -10, -10, 10) then away = 0 return end
        away = away + (elapsed or 0)
        if away > 0.4 then self:Hide() end
    end)
    m:SetScript("OnShow", function() away = 0 end)
    return m
end

local function row(m, i)
    local r = m.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, m)
    r:SetHeight(ROW_H)
    local hl = Chrome:Texture(r, "HIGHLIGHT", Chrome:Wash("fel", 0.18))
    hl:SetAllPoints()
    r.label = Chrome:Text(r, 12)
    r.label:SetPoint("LEFT", 10, 0)
    r.label:SetPoint("RIGHT", -10, 0)
    r.label:SetJustifyH("LEFT")
    -- On the press's release, as menus must be: a click arrives too late.
    r:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" and button ~= "RightButton" then return end
        m:Hide()
        if self.fn then Core.safe(self.fn) end
    end)
    m.rows[i] = r
    return r
end

-- items: { { text = "...", fn = function() end }, ... }
function Pins:ShowMenu(title, items)
    local m = self.menu or buildMenu()
    self.menu = m
    m.title:SetText(title or "")
    local y = -24
    for i, item in ipairs(items) do
        local r = row(m, i)
        r.label:SetText(item.text)
        r.fn = item.fn
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", m, "TOPLEFT", 1, y)
        r:SetPoint("TOPRIGHT", m, "TOPRIGHT", -1, y)
        r:Show()
        y = y - ROW_H
    end
    for i = #items + 1, #m.rows do m.rows[i]:Hide() end
    m:SetSize(MENU_W, -y + 6)
    local s = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    m:ClearAllPoints()
    -- The cursor starts just inside the corner, over the menu.
    m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / s - 8, cy / s + 8)
    m:Show()
    return m
end

function Pins:HideMenu()
    if self.menu then self.menu:Hide() end
end

-- The menu for a spot on the map.
function Pins:MapMenu(mapID, x, y)
    local m, mx, my = Pins.Spot(mapID, x, y)
    local native = ns.Marker:Native()
    local items = {}
    if m then
        items[#items + 1] = { text = "Add a pin here", fn = function() Pins:Edit(nil, m, mx, my) end }
    end
    items[#items + 1] = { text = native and "Set a waypoint here" or "Point the arrow here",
                          fn = function() ns.Marker:Set(mapID, x, y) end }
    if ns.Marker:Has() then
        local dest = ns.Marker:PinID() and ns.Marker:Label()
        items[#items + 1] = { text = dest and ("Stop heading for " .. dest) or (native and "Clear the waypoint" or "Clear the arrow"),
                              fn = function() ns.Marker:Clear() end }
    end
    local title = m and ("%s  %.1f, %.1f"):format(placeName(m, mx, my), mx * 100, my * 100) or ns.MapName(mapID)
    return self:ShowMenu(title, items)
end

-- The menu for one of your pins.
function Pins:PinMenu(p)
    return self:ShowMenu(p.title or "Pin", {
        { text = Pins:IsDestination(p) and "Stop heading here" or "Head here", fn = function() Pins:HeadTo(p) end },
        { text = "Change", fn = function() Pins:Edit(p) end },
        { text = "Delete", fn = function()
            Pins:Remove(p)
            ns.A:Print(("deleted %s%s|r."):format(Chrome:Esc("fel"), p.title or "the pin"))
        end },
    })
end

-- The canvas click handler. true stops the game going up a level.
local function onCanvasClick(map, button, x, y)
    if button ~= "RightButton" then return false end
    local db = ns.DB()
    if not (db and db.rightClick) or IsShiftKeyDown() then return false end
    local mapID = map and map.GetMapID and map:GetMapID()
    if not (mapID and x and y) then return false end
    -- Whatever happens in here, the click was ours: a slip inside must
    -- not let it fall through to the map going up a level.
    Core.safe(Pins.MapMenu, Pins, mapID, x, y)
    return true
end
Pins.OnCanvasClick = onCanvasClick

-- ============================================================
-- The editor
-- ============================================================

local function Ink(fs, c)
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    Chrome:Register(fs, c, "text")
end

local function Paint(f, c)
    if not f.border then return end
    for _, t in pairs(f.border) do t:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
end

-- A text box in the suite's chrome.
local function input(parent, w, onEnter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(w, 24)
    if Chrome:Game() then
        Chrome:GameInputArt(holder, 0)
    else
        local bg = Chrome:Texture(holder, "BACKGROUND", C.void)
        bg:SetAllPoints()
        Chrome:AddBorder(holder)
    end
    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 7, -2)
    eb:SetPoint("BOTTOMRIGHT", -7, 2)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(120)
    local chatFont = rawget(_G, "ChatFontNormal")
    if chatFont and eb.SetFontObject then eb:SetFontObject(chatFont) end
    Chrome:SetFont(eb, 12)
    Ink(eb, C.text)
    eb:SetScript("OnEditFocusGained", function() Paint(holder, C.fel) end)
    eb:SetScript("OnEditFocusLost", function() Paint(holder, C.border) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus(); if onEnter then onEnter() end end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() eb:SetFocus() end)
    holder.edit = eb
    return holder
end

local EDIT_W, EDIT_H = 300, 214

function Pins:Editor()
    if self.editor then return self.editor end
    local f = Chrome:NewPanel("WicksMapPinEditor", { title = "Wick's Map", width = EDIT_W, height = EDIT_H })
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    local body = f.content or f

    local nameLabel = Chrome:Text(body, 11, C.muted)
    nameLabel:SetPoint("TOPLEFT", 0, -2)
    nameLabel:SetText("Name")
    f.name = input(body, EDIT_W - 16, function() Pins:SaveEditor() end)
    f.name:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)
    f.name:SetPoint("RIGHT", body, "RIGHT", 0, 0)

    local noteLabel = Chrome:Text(body, 11, C.muted)
    noteLabel:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -8)
    noteLabel:SetText("Note (optional)")
    f.note = input(body, EDIT_W - 16, function() Pins:SaveEditor() end)
    f.note:SetPoint("TOPLEFT", noteLabel, "BOTTOMLEFT", 0, -4)
    f.note:SetPoint("RIGHT", body, "RIGHT", 0, 0)

    -- The eight raid marker icons; the picked one is ringed in the accent.
    f.icons = {}
    for i = 1, #ICONS do
        local b = CreateFrame("Button", nil, body)
        b:SetSize(26, 26)
        b:SetPoint("TOPLEFT", f.note, "BOTTOMLEFT", (i - 1) * 32, -10)
        local ring = Chrome:Texture(b, "BACKGROUND", C.border)
        ring:SetAllPoints()
        b.ring = ring
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetPoint("TOPLEFT", 3, -3)
        t:SetPoint("BOTTOMRIGHT", -3, 3)
        t:SetTexture(ICON:format(i))
        b:SetScript("OnClick", function() Pins:PickIcon(i) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(ICONS[i])
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.icons[i] = b
    end

    f.save = Chrome:Button(body, "Save", 70, 22)
    f.save:SetPoint("BOTTOMRIGHT", 0, 0)
    f.save:SetScript("OnClick", function() Pins:SaveEditor() end)
    f.cancel = Chrome:Button(body, "Cancel", 70, 22)
    f.cancel:SetPoint("RIGHT", f.save, "LEFT", -6, 0)
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    f.delete = Chrome:Button(body, "Delete", 70, 22)
    f.delete:SetPoint("BOTTOMLEFT", 0, 0)
    f.delete:SetScript("OnClick", function()
        local p = f.pin
        f:Hide()
        if p then
            Pins:Remove(p)
            ns.A:Print(("deleted %s%s|r."):format(Chrome:Esc("fel"), p.title or "the pin"))
        end
    end)
    self.editor = f
    return f
end

function Pins:PickIcon(i)
    local f = self:Editor()
    f.icon = i
    for j, b in ipairs(f.icons) do
        local c = (j == i) and C.fel or C.border
        b.ring:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    end
end

-- Open the editor on a pin, or on a new one at mapID, x, y.
function Pins:Edit(p, mapID, x, y)
    local f = self:Editor()
    f.pin = p
    f.spot = (not p) and { mapID = mapID, x = x, y = y } or nil
    local name = p and p.title or placeName(mapID, x, y)
    f.name.edit:SetText(name or "")
    f.note.edit:SetText(p and p.note or "")
    self:PickIcon(p and p.icon or 1)
    f.delete:SetShown(p ~= nil)
    f:ClearAllPoints()
    local s = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / s + 12, cy / s - 12)
    f:Show()
    f.name.edit:SetFocus()
    if f.name.edit.HighlightText then f.name.edit:HighlightText() end
    return f
end

function Pins:SaveEditor()
    local f = self.editor
    if not (f and f:IsShown()) then return end
    local title = Core.trim(f.name.edit:GetText() or "")
    local note = Core.trim(f.note.edit:GetText() or "")
    if f.pin then
        if title == "" then title = f.pin.title end
        self:Change(f.pin, title, f.icon, note)
    elseif f.spot then
        local sp = f.spot
        if title == "" then title = placeName(sp.mapID, sp.x, sp.y) end
        self:Add(sp.mapID, sp.x, sp.y, title, f.icon, note)
        ns.A:Print(("pinned %s%s|r."):format(Chrome:Esc("fel"), title))
    end
    f:Hide()
end

-- ============================================================
-- Where you stand
-- ============================================================

-- A pin on your own spot, for /wmap pin and macros.
function Pins:PinHere(title)
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then
        ns.A:Print("the game will not say where you are here.")
        return nil
    end
    local x, y = pos:GetXY()
    title = (title and title ~= "") and title or placeName(mapID, x, y)
    local p = self:Add(mapID, x, y, title, 1)
    ns.A:Print(("pinned %s%s|r where you stand."):format(Chrome:Esc("fel"), title))
    return p
end

function Pins:Attach(wm)
    if self.attached then return end
    self.attached = true
    self:Layer(wm)
    if wm.AddCanvasClickHandler then
        -- Above the game's own handlers, so a right-click reaches us first.
        wm:AddCanvasClickHandler(onCanvasClick, 100)
    end
    wm:HookScript("OnHide", function() Pins:HideMenu() end)
end
