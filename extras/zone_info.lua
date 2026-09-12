-- RGMercs User Module: Zone Info
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/zone_info.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "ZoneInfo"
--   3. It draws in the MAIN window, right under Author(s): Cannonballdex
--      (no extra tab unless you turn on "Show ZoneInfo Tab")
--
-- Survives RGMercs updates because it lives in your config folder, not lua/rgmercs.

local mq        = require('mq')
local ImGui     = require('ImGui')
local Icons     = require('mq.ICONS')
local Base      = require("modules.base")
local Comms     = require("utils.comms")
local Core      = require("utils.core")
local Config    = require("utils.config")
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Modules   = require("utils.modules")
local Ui        = require("utils.ui")

local Module    = {
    _version = '1.1',
    _name    = "ZoneInfo",
    _author  = "Cannonballdex",
    _about   = "Draws zone / DanNet / peer counts under Author(s) in the main RGMercs window.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- DanNet uses zone_<shortname> (no server) for these; everything else is zone_<server>_<shortname>.
local INSTANCE_ZONE = {
    guildhall     = true,
    guildhalllrg  = true,
    guildlobby    = true,
    neighborhood  = true,
    guildhall3    = true,
    potranquility = true,
    bazaar        = true,
    nexus         = true,
}

local COL = {
    Yellow = ImVec4(1.0, 1.0, 0.5, 1.0),
    Green  = ImVec4(0.0, 1.0, 0.0, 1.0),
    Red    = ImVec4(0.95, 0.05, 0.05, 1.0),
    Grey   = ImVec4(0.70, 0.70, 0.70, 1.0),
    Cyan   = ImVec4(0.40, 0.90, 1.00, 1.0),
}

-- Hooked StandardUI instance lives here so the header callback can reach us.
local hooked
local origRenderWindowControls
local weInstalledHook = false

Module.FAQ = {
    {
        Question = "Where does Zone Info show?",
        Answer   = "On the main RGMercs window, directly under Author(s), matching Easy's Zone Info counts: " ..
            "zone name/short/id, PC / guild / other, DanNet peers total and in-zone, plus RGMercs heartbeat peers.\n\n" ..
            "Turn off Show Under Author(s) if you'd rather keep the main window slim and only check the ZoneInfo tab.",
        Settings_Used = "ZoneInfoShowUnderAuthor,ZoneInfoShowPCTable,ZoneInfoShowPeerList,ZoneInfoShowTab",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['ZoneInfoShowUnderAuthor'] = {
        DisplayName = "Show Under Author(s)",
        Category = Module._name,
        Index = 1,
        Tooltip = "Draw the zone/peer count line under Author(s) in the main window. Turn off for a slimmer " ..
            "main window if you'd rather only use the ZoneInfo tab.",
        Default = true,
    },
    ['ZoneInfoShowPCTable'] = {
        DisplayName = "Show PC Table",
        Category = Module._name,
        Index = 2,
        Tooltip = "Expandable table of every PC in the zone under the count row.",
        Default = true,
    },
    ['ZoneInfoShowPeerList'] = {
        DisplayName = "Show Peer List",
        Category = Module._name,
        Index = 3,
        Tooltip = "Expandable list of DanNet / RGMercs peers in this zone.",
        Default = true,
    },
    ['ZoneInfoShowTab'] = {
        DisplayName = "Show ZoneInfo Tab",
        Category = Module._name,
        Index = 4,
        Tooltip = "Also add a ZoneInfo tab (independent of Show Under Author(s)).",
        Default = false,
    },
    ['ZoneInfoScanMs'] = {
        DisplayName = "Scan Interval (ms)",
        Category = Module._name,
        Index = 5,
        Tooltip = "How often to refresh spawn and peer snapshots.",
        Default = 500,
        Min = 100,
        Max = 5000,
    },
}

Module.CommandHandlers = {
    zoneinfo = {
        usage = "/rgl zoneinfo",
        about = "Print zone, PC, guild, other, and DanNet peer counts to the console.",
        handler = function(self)
            self:Scan()
            local c = self.counts
            Logger.log_info("\ayZone:\ax %s [%s] ID %d | PC %d | Guild %d | Other %d | DanNet %d / zone %d | RGMercs zone %d",
                c.zoneName, c.shortName, c.zoneId, c.pc, c.guild, c.other, c.dannetAll, c.dannetZone, c.rgZone)
            return true
        end,
    },
}

function Module:New()
    return Base.New(self)
end

local function SafeNum(v, fallback)
    local n = tonumber(v)
    if n == nil then return fallback or 0 end
    return n
end

local function Alive()
    return mq.TLO.Me() and (mq.TLO.Me.ID() or 0) > 0
end

local function DanNetLoaded()
    return mq.TLO.Plugin('MQ2DanNet')() ~= nil
end

local function GetDanNetZoneObserve()
    local short = (mq.TLO.Zone.ShortName() or ""):lower()
    local inst  = SafeNum(mq.TLO.Me.Instance(), 0)
    if inst > 0 or INSTANCE_ZONE[short] then
        return string.format("zone_%s", mq.TLO.Zone.ShortName() or short)
    end
    return string.format("zone_%s_%s", mq.TLO.EverQuest.Server() or "", mq.TLO.Zone.ShortName() or "")
end

local function SplitPeers(raw)
    local list = {}
    if not raw or raw == "" then return list end
    for name in string.gmatch(raw, "[^|]+") do
        if name ~= "" then table.insert(list, name) end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    return list
end

local function Bracket(value, tooltip, color)
    ImGui.TextColored(color or COL.Green, string.format("[ %s ]", tostring(value)))
    if tooltip then Ui.Tooltip(tooltip) end
end

function Module:Init()
    Base.Init(self)
    hooked = self
    self.lastScan    = 0
    self.players     = {}
    self.danNetPeers = {}
    self.rgZonePeers = {}
    self.counts      = {
        pc = 0, guild = 0, other = 0,
        dannetAll = 0, dannetZone = 0,
        rgAll = 0, rgZone = 0,
        zoneName = "", shortName = "", zoneId = 0,
        danNetLoaded = false, observe = "",
    }

    -- Draw in the main header, immediately under Author(s), without editing ui/standard.lua.
    local ok, StandardUI = pcall(require, "ui.standard")
    if ok and StandardUI and not StandardUI._cannonZoneInfoHook then
        origRenderWindowControls = StandardUI.RenderWindowControls
        StandardUI.RenderWindowControls = function(uiSelf, ...)
            if hooked and hooked.ModuleLoaded then
                hooked:RenderUnderAuthor()
            end
            if origRenderWindowControls then
                return origRenderWindowControls(uiSelf, ...)
            end
        end
        StandardUI._cannonZoneInfoHook = true
        weInstalledHook = true
        Logger.log_info("\ag[ZoneInfo]\ax hooked under Author(s) in the main RGMercs window.")
    elseif ok and StandardUI and StandardUI._cannonZoneInfoHook then
        -- A stale hook from before a reload is still installed; it checks its own
        -- now-nil `hooked` upvalue and quietly no-ops, so this is safe to leave.
        Logger.log_debug("[ZoneInfo] ui.standard hook already present from a prior load; leaving it in place.")
    else
        Logger.log_error("\ar[ZoneInfo]\ax could not hook ui.standard — counts will only appear on the ZoneInfo tab.")
    end
end

function Module:Shutdown()
    hooked = nil
    if weInstalledHook then
        local ok, StandardUI = pcall(require, "ui.standard")
        if ok and StandardUI then
            StandardUI.RenderWindowControls = origRenderWindowControls
            StandardUI._cannonZoneInfoHook = nil
        end
        weInstalledHook = false
    end
    Base.Shutdown(self)
end

function Module:Scan()
    if not Alive() then
        self.players = {}
        return
    end

    local zone = mq.TLO.Zone
    local c = self.counts
    c.zoneName  = zone() or "Unknown"
    c.shortName = zone.ShortName() or "unknown"
    c.zoneId    = SafeNum(zone.ID(), 0)

    local pc    = SafeNum(mq.TLO.SpawnCount('pc')(), 0)
    local guild = SafeNum(mq.TLO.SpawnCount('guild pc')(), 0)
    c.pc    = pc
    c.guild = guild
    c.other = math.max(0, pc - guild)

    c.danNetLoaded = DanNetLoaded()
    c.dannetAll    = 0
    c.dannetZone   = 0
    c.observe      = ""
    self.danNetPeers = {}

    if c.danNetLoaded then
        c.observe    = GetDanNetZoneObserve()
        c.dannetAll  = SafeNum(mq.TLO.DanNet.PeerCount(), 0)
        c.dannetZone = SafeNum(mq.TLO.DanNet.PeerCount(c.observe)(), 0)
        self.danNetPeers = SplitPeers(mq.TLO.DanNet.Peers(c.observe)() or mq.TLO.DanNet.Peers()() or "")
    end

    local rgAll  = Comms.GetPeers(true) or {}
    local rgZone = Comms.GetZonePeers(true) or {}
    c.rgAll  = #rgAll
    c.rgZone = #rgZone
    self.rgZonePeers = rgZone

    local players = {}
    for i = 1, pc do
        local spawn = mq.TLO.NearestSpawn(i, 'pc')
        if spawn and spawn() then
            table.insert(players, {
                id       = spawn.ID() or 0,
                name     = spawn.CleanName() or spawn.Name() or "Unknown",
                level    = SafeNum(spawn.Level(), 0),
                class    = (spawn.Class and spawn.Class.ShortName()) or "UNK",
                race     = (spawn.Race and spawn.Race()) or "",
                guild    = spawn.Guild() or "No Guild",
                distance = math.floor(SafeNum(spawn.Distance(), 0)),
                los      = spawn.LineOfSight() and true or false,
                hp       = SafeNum(spawn.PctHPs(), 0),
                loc      = spawn.LocYXZ() or "",
            })
        end
        if not Alive() then break end
    end
    self.players = players
end

function Module:GiveTime()
    local now = Globals.GetTimeSeconds()
    local interval = (Config:GetSetting('ZoneInfoScanMs') or 500) / 1000
    if (now - (self.lastScan or 0)) < interval then return end
    self.lastScan = now
    self:Scan()
end

function Module:OnZone()
    self.lastScan = 0
    self.players = {}
    self.danNetPeers = {}
    self.rgZonePeers = {}
end

function Module:RenderCountRow()
    local c = self.counts

    ImGui.Text("Zone:")
    ImGui.SameLine()
    Bracket(c.zoneName, "Zone long name", COL.Yellow)
    ImGui.SameLine()
    ImGui.Text("Short:")
    ImGui.SameLine()
    Bracket(c.shortName, "Zone short name", COL.Yellow)
    ImGui.SameLine()
    ImGui.Text("ID:")
    ImGui.SameLine()
    Bracket(c.zoneId, "Zone ID", COL.Yellow)
    local inst = SafeNum(mq.TLO.Me.Instance(), 0)
    if inst > 0 then
        ImGui.SameLine()
        ImGui.Text("Inst:")
        ImGui.SameLine()
        Bracket(inst, "Instance ID", COL.Yellow)
    end

    ImGui.Text("Zone | Guild | Other:")
    Ui.Tooltip("Players in zone, guild members, everyone else")
    ImGui.SameLine()
    Bracket(c.pc, "Players in zone")
    ImGui.SameLine()
    Bracket(c.guild, "Guild members in zone")
    ImGui.SameLine()
    Bracket(c.other, "Other players in zone")

    ImGui.SameLine()
    ImGui.Text("Peers | Zone")
    Ui.Tooltip("Total DanNet peers and DanNet peers in this zone")
    ImGui.SameLine()

    if not c.danNetLoaded then
        ImGui.TextColored(COL.Red, "DanNet Disabled")
        Ui.Tooltip("MQ2DanNet is not loaded")
    elseif c.dannetAll > 0 then
        Bracket(c.dannetAll, "Total DanNet peers")
        ImGui.SameLine()
        Bracket(c.dannetZone, string.format("DanNet peers in this zone (%s)", c.observe))
    else
        ImGui.TextColored(COL.Red, "[ 0 ]")
        Ui.Tooltip("DanNet is loaded but reports no peers")
    end

    ImGui.SameLine()
    ImGui.Text("RG")
    Ui.Tooltip("RGMercs heartbeat peers in this zone + instance")
    ImGui.SameLine()
    Bracket(c.rgZone, "RGMercs peers in this zone", COL.Cyan)
end

function Module:RenderPeerList()
    if not Config:GetSetting('ZoneInfoShowPeerList') then return end
    if not ImGui.CollapsingHeader("Peers in Zone") then return end

    if ImGui.BeginTable("##ZoneInfoPeers", 3, bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY), 0, 120) then
        ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableSetupColumn("Class / HP", ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableHeadersRow()

        local seen = {}
        for _, peer in ipairs(self.rgZonePeers or {}) do
            local data = peer.data or {}
            local name = peer.name or peer.key or "?"
            seen[name:lower()] = true
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            if ImGui.Selectable(name .. "##rg" .. name) then
                if SafeNum(data.ID, 0) > 0 then
                    Core.SetTarget(data.ID)
                else
                    Core.DoCmd("/target %s", name)
                end
            end
            Ui.Tooltip("RGMercs peer — click to target")
            ImGui.TableNextColumn()
            ImGui.TextColored(COL.Cyan, "RGMercs")
            ImGui.TableNextColumn()
            local hp = data.HPs
            ImGui.Text(string.format("%s%s", data.Class or "", hp and (" " .. tostring(hp) .. "%") or ""))
        end

        for _, name in ipairs(self.danNetPeers or {}) do
            if not seen[name:lower()] then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                if ImGui.Selectable(name .. "##dn" .. name) then
                    Core.DoCmd("/target %s", name)
                end
                Ui.Tooltip("DanNet peer — click to target")
                ImGui.TableNextColumn()
                ImGui.TextColored(COL.Green, "DanNet")
                ImGui.TableNextColumn()
                ImGui.Text("-")
            end
        end

        if ((self.counts.rgZone or 0) == 0) and (#self.danNetPeers == 0) then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextColored(COL.Grey, "No peers in zone")
            ImGui.TableNextColumn()
            ImGui.Text("")
            ImGui.TableNextColumn()
            ImGui.Text("")
        end

        ImGui.EndTable()
    end
end

function Module:RenderPCTable()
    if not Config:GetSetting('ZoneInfoShowPCTable') then return end
    if not ImGui.CollapsingHeader("Players in Zone") then return end

    local flags = bit32.bor(
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.SizingStretchProp
    )

    if ImGui.BeginTable("##ZoneInfoPlayers", 9, flags, 0, 200) then
        ImGui.TableSetupColumn("Name",     ImGuiTableColumnFlags.WidthStretch, 20.0)
        ImGui.TableSetupColumn("Level",    ImGuiTableColumnFlags.WidthFixed, 45.0)
        ImGui.TableSetupColumn("Class",    ImGuiTableColumnFlags.WidthFixed, 45.0)
        ImGui.TableSetupColumn("Race",     ImGuiTableColumnFlags.WidthStretch, 12.0)
        ImGui.TableSetupColumn("Guild",    ImGuiTableColumnFlags.WidthStretch, 16.0)
        ImGui.TableSetupColumn("Dist",     ImGuiTableColumnFlags.WidthFixed, 50.0)
        ImGui.TableSetupColumn("LOS",      ImGuiTableColumnFlags.WidthFixed, 35.0)
        ImGui.TableSetupColumn("HP",       ImGuiTableColumnFlags.WidthFixed, 40.0)
        ImGui.TableSetupColumn("LOC",      ImGuiTableColumnFlags.WidthStretch, 16.0)
        ImGui.TableHeadersRow()

        local myName = mq.TLO.Me.CleanName() or ""
        for _, p in ipairs(self.players) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            if p.los then ImGui.PushStyleColor(ImGuiCol.Text, COL.Green) end
            local clicked = ImGui.Selectable(string.format("%s##pc%d", p.name, p.id))
            if p.los then ImGui.PopStyleColor() end
            if clicked then Core.SetTarget(p.id) end
            Ui.Tooltip(p.name == myName and "This is you" or "Click to target")

            ImGui.TableNextColumn()
            ImGui.Text(tostring(p.level))
            ImGui.TableNextColumn()
            ImGui.Text(p.class)
            ImGui.TableNextColumn()
            ImGui.Text(p.race)
            ImGui.TableNextColumn()
            ImGui.Text(p.guild)
            ImGui.TableNextColumn()
            ImGui.Text(tostring(p.distance))
            ImGui.TableNextColumn()
            if p.los then
                ImGui.TextColored(COL.Green, Icons.FA_EYE)
            else
                ImGui.TextColored(COL.Grey, Icons.FA_EYE_SLASH)
            end
            ImGui.TableNextColumn()
            ImGui.Text(tostring(p.hp))
            ImGui.TableNextColumn()
            if p.loc ~= "" and ImGui.Selectable(p.loc .. "##loc" .. p.id) then
                Core.DoCmd("/nav id %d", p.id)
            end
            Ui.Tooltip("Click to /nav to this player")
        end
        ImGui.EndTable()
    end
end

function Module:RenderBody()
    if not Alive() or not mq.TLO.Zone() then
        ImGui.TextColored(COL.Red, "Not in game.")
        return
    end
    self:RenderCountRow()
    self:RenderPeerList()
    self:RenderPCTable()
end

-- Called from the StandardUI header hook: sits directly under Author(s).
function Module:RenderUnderAuthor()
    if not Config:GetSetting('ZoneInfoShowUnderAuthor') then return end
    ImGui.PushID("##CannonZoneInfoHeader")
    self:RenderBody()
    ImGui.NewLine()
    ImGui.PopID()
end

function Module:ShouldRender()
    return Config:GetSetting('ZoneInfoShowTab') and true or false
end

function Module:Render()
    Base.Render(self)
    self:RenderBody()
end

function Module:DoGetState()
    local c = self.counts
    return string.format("PC %d | DanNet %d/%d | RG %d", c.pc, c.dannetZone, c.dannetAll, c.rgZone)
end

return Module