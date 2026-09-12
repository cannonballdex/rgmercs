-- RGMercs User Module: Named Timer
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/named_timer.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "NamedTimer"
--
-- Logs when you kill a mob flagged as Named, per zone, to a local file, and
-- shows how long ago each one died plus a naive ETA based on an assumed
-- respawn window you set. This has no real per-mob respawn data - it's just
-- a timer against your own kill history.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Icons    = require('mq.ICONS')
local Base     = require("modules.base")
local Config   = require('utils.config')
local Logger   = require("utils.logger")
local Modules  = require("utils.modules")
local Ui       = require("utils.ui")

local Module   = {
    _version = '1.0',
    _name    = "NamedTimer",
    _author  = "Cannonballdex",
    _about   = "Tracks when you last killed each Named mob per zone and estimates a respawn ETA.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

Module.FAQ = {
    {
        Question = "Where does the respawn time come from?",
        Answer   = "There's no real per-mob respawn data here - the ETA is just your kill time plus the Assumed " ..
            "Respawn Minutes setting. It's a personal timer against your own kill history, not a real spawn timer.",
        Settings_Used = "NamedTimerRespawnMinutes",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['NamedTimerRespawnMinutes'] = {
        DisplayName = "Assumed Respawn Minutes",
        Category = Module._name,
        Index = 1,
        Tooltip = "Default respawn window (in minutes) used for the ETA, since RGMercs has no real per-mob respawn data.",
        Default = 30,
        Min = 1,
        Max = 1440,
    },
}

Module.CommandHandlers = {
    namedtimer = {
        usage = "/rgl namedtimer clear",
        about = "Clear this zone's tracked named kill times.",
        handler = function(self, sub)
            if (sub or ""):lower() == "clear" then
                self:ClearZone()
                Logger.log_info("\ayNamedTimer: cleared kill history for this zone.")
            end
            return true
        end,
    },
}

local function FilePath()
    return string.format("%s/RGMercs_NamedTimer.lua", mq.configDir)
end

function Module:Load()
    local ok, data = pcall(dofile, FilePath())
    self.data = (ok and type(data) == "table") and data or {}
end

function Module:Save()
    pcall(mq.pickle, FilePath(), self.data)
end

function Module:ZoneKey()
    return (mq.TLO.Zone.ShortName() or "unknown"):lower()
end

function Module:ClearZone()
    self.data[self:ZoneKey()] = nil
    self:Save()
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self:Load()
    self.lastNamedName = nil

    self._slainEvent = "RGMercsNamedTimerSlain"
    mq.event(self._slainEvent, "You have slain #victim#!", function(_, victim)
        if not self.lastNamedName or not victim then return end
        if not victim:lower():find(self.lastNamedName:lower(), 1, true) then return end

        local zoneKey = self:ZoneKey()
        self.data[zoneKey] = self.data[zoneKey] or {}
        self.data[zoneKey][self.lastNamedName] = os.time()
        self:Save()
    end)
end

function Module:Shutdown()
    if self._slainEvent then
        mq.unevent(self._slainEvent)
        self._slainEvent = nil
    end
    Base.Shutdown(self)
end

function Module:GiveTime()
    local target = mq.TLO.Target
    if target() and target.Type() == "NPC" then
        local ok, isNamed = pcall(function() return Modules:ExecModule("Named", "IsNamed", target) end)
        if ok and isNamed then
            self.lastNamedName = target.CleanName() or target.Name()
        end
    end
end

function Module:ShouldRender()
    return true
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local zoneKey  = self:ZoneKey()
    local zoneData = self.data[zoneKey] or {}
    local names    = {}
    for name in pairs(zoneData) do table.insert(names, name) end
    table.sort(names, function(a, b) return zoneData[a] > zoneData[b] end)

    if #names == 0 then
        ImGui.TextColored(ImVec4(0.7, 0.7, 0.7, 1.0), "No named kills logged for this zone yet.")
    else
        local respawnSec = (Config:GetSetting('NamedTimerRespawnMinutes') or 30) * 60
        local now = os.time()
        if ImGui.BeginTable("##NamedTimerTable", 3, bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.Resizable)) then
            ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn('Killed', ImGuiTableColumnFlags.WidthFixed, 100.0)
            ImGui.TableSetupColumn('ETA', ImGuiTableColumnFlags.WidthFixed, 100.0)
            ImGui.TableHeadersRow()
            for _, name in ipairs(names) do
                local killedAt = zoneData[name]
                local elapsed  = now - killedAt
                local remain   = respawnSec - elapsed
                ImGui.TableNextColumn()
                Ui.RenderText(name)
                ImGui.TableNextColumn()
                Ui.RenderText(string.format("%dm ago", math.floor(elapsed / 60)))
                ImGui.TableNextColumn()
                if remain <= 0 then
                    Ui.RenderColoredText(ImVec4(0.4, 1.0, 0.4, 1.0), "Up now")
                else
                    Ui.RenderText(string.format("~%dm", math.ceil(remain / 60)))
                end
            end
            ImGui.EndTable()
        end
    end

    ImGui.Spacing()
    if ImGui.SmallButton(Icons.FA_TRASH .. " Clear This Zone") then
        self:ClearZone()
    end
end

return Module
