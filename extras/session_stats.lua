-- RGMercs User Module: Session Stats
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/session_stats.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "SessionStats"
--
-- Tracks kills, levels/AA gained, and plat earned since RGMercs was loaded
-- (or since you last reset), and shows a compact readout of session
-- productivity.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Icons    = require('mq.ICONS')
local Base     = require("modules.base")
local Logger   = require("utils.logger")

local Module   = {
    _version = '1.0',
    _name    = "SessionStats",
    _author  = "Cannonballdex",
    _about   = "Kills, levels/AA gained, and plat earned this session.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

Module.FAQ = {
    {
        Question = "How is plat earned calculated?",
        Answer   = "It's the difference between your current total money (plat/gold/silver/copper converted to copper) " ..
            "and what you had when this module loaded or was last reset. Spending money during the session will show " ..
            "as a smaller (or negative) total, same as it would in your own head.",
        Settings_Used = "",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
}

Module.CommandHandlers = {
    sessionstats = {
        usage = "/rgl sessionstats [reset]",
        about = "Print session stats, or reset the counters.",
        handler = function(self, sub)
            if (sub or ""):lower() == "reset" then
                self:ResetStats()
                Logger.log_info("\aySessionStats: counters reset.")
                return true
            end
            Logger.log_info("\ayKills: \ax%d \ayLevels: \ax+%d \ayAA: \ax+%d \ayPlat: \ax%s",
                self.kills, self:LevelsGained(), self:AAGained(), self:FormatMoney(self:MoneyGained()))
            return true
        end,
    },
}

local function TotalCopper()
    local me = mq.TLO.Me
    return (me.Platinum() or 0) * 1000 + (me.Gold() or 0) * 100 + (me.Silver() or 0) * 10 + (me.Copper() or 0)
end

function Module:New()
    return Base.New(self)
end

function Module:ResetStats()
    self.startTime  = os.time()
    self.kills      = 0
    self.startLevel = mq.TLO.Me.Level() or 1
    self.startAA    = (mq.TLO.Me.AAPointsSpent() or 0) + (mq.TLO.Me.AAPoints() or 0)
    self.startMoney = TotalCopper()
end

function Module:LevelsGained()
    return (mq.TLO.Me.Level() or self.startLevel) - self.startLevel
end

function Module:AAGained()
    return ((mq.TLO.Me.AAPointsSpent() or 0) + (mq.TLO.Me.AAPoints() or 0)) - self.startAA
end

function Module:MoneyGained()
    return TotalCopper() - self.startMoney
end

function Module:FormatMoney(copper)
    local sign = copper < 0 and "-" or ""
    copper     = math.abs(copper)
    local plat = math.floor(copper / 1000)
    local gold = math.floor((copper % 1000) / 100)
    return string.format("%s%dp %dg", sign, plat, gold)
end

function Module:Init()
    Base.Init(self)
    self:ResetStats()

    self._slainEvent = "RGMercsSessionStatsSlain"
    mq.event(self._slainEvent, "You have slain #victim#!", function(_, victim)
        self.kills = self.kills + 1
    end)
end

function Module:Shutdown()
    if self._slainEvent then
        mq.unevent(self._slainEvent)
        self._slainEvent = nil
    end
    Base.Shutdown(self)
end

function Module:ShouldRender()
    return true
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local elapsed = os.time() - self.startTime
    local hours   = elapsed / 3600

    ImGui.Text(string.format("Session Time: %02d:%02d:%02d", math.floor(elapsed / 3600), math.floor((elapsed % 3600) / 60), elapsed % 60))

    ImGui.Text("Kills:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), tostring(self.kills))
    if hours > 0.01 then
        ImGui.SameLine()
        ImGui.TextColored(ImVec4(0.7, 0.7, 0.7, 1.0), string.format("(%.1f/hr)", self.kills / hours))
    end

    ImGui.Text("Current XP:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), string.format("%.1f%%", mq.TLO.Me.PctExp() or 0))

    ImGui.Text("Levels Gained:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), tostring(self:LevelsGained()))

    ImGui.Text("AA Gained:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), tostring(self:AAGained()))

    ImGui.Text("Plat Earned:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(1, 1, 0.5, 1), self:FormatMoney(self:MoneyGained()))

    ImGui.Spacing()
    if ImGui.SmallButton(Icons.MD_REFRESH .. " Reset Counters") then
        self:ResetStats()
    end
end

return Module
