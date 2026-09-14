-- RGMercs User Module: Auto Lesson
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/auto_lesson.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "AutoLesson"
--
-- Automatically activates Lesson of the Devoted as soon as it's ready and
-- you're in a safe state to use it (alive, not moving, not invisible, not
-- sitting, and not already carrying Lesson of the Devoted or a Bottle of
-- Adventure buff, since using it under either would waste the activation).
-- Ported from EasyLua's Lesson check.
--
-- Survives RGMercs updates because it lives in your config folder, not lua/rgmercs.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Core     = require("utils.core")
local Config   = require('utils.config')
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")
local Ui       = require("utils.ui")

local AA_NAME  = "Lesson of the Devoted"

local Module   = {
    _version = '1.0',
    _name    = "AutoLesson",
    _author  = "Cannonballdex",
    _about   = "Automatically activates Lesson of the Devoted as soon as it's ready and safe to use.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why isn't it firing even though Lesson shows ready?",
        Answer   = "It also waits for you to be alive, not moving, not invisible, not sitting, and not already " ..
            "carrying the Lesson of the Devoted or Bottle of Adventure buff (using Lesson under either would waste " ..
            "the activation). It checks every tick, so it should fire within a moment of all of those being true.",
        Settings_Used = "ALEnabled",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['ALEnabled'] = {
        DisplayName = "Enable Auto Lesson",
        Category = Module._name,
        Index = 1,
        Tooltip = "Master toggle. Automatically activates Lesson of the Devoted as soon as it's ready and safe to use.",
        Default = true,
    },
    ['ALShowTab'] = {
        DisplayName = "Show AutoLesson Tab",
        Category = Module._name,
        Index = 2,
        Tooltip = "Add an AutoLesson tab to the main window. Turn off if you don't need the status display.",
        Default = true,
    },
}

local function Alive()
    return mq.TLO.Me() and (mq.TLO.Me.ID() or 0) > 0
end

local function ReadyToUseLesson()
    local me = mq.TLO.Me
    return Alive()
        and not me.Moving()
        and me.AltAbilityReady(AA_NAME)()
        and not me.Invis()
        and not me.Hovering()
        and not me.Sitting()
        and not me.Buff(AA_NAME)()
        and not me.Buff('Bottle of Adventure')()
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.useCount = 0
    self.lastUsed = nil
end

function Module:ShouldRender()
    return Config:GetSetting('ALShowTab') and true or false
end

function Module:GiveTime()
    if not Config:GetSetting('ALEnabled') then return end
    if not ReadyToUseLesson() then return end

    local aaAbility = mq.TLO.Me.AltAbility(AA_NAME)
    local aaId = aaAbility() and aaAbility.ID()
    if not aaId or aaId == 0 then return end

    Core.DoCmd("/alt act %d", aaId)
    self.useCount = self.useCount + 1
    self.lastUsed = os.time()
    Logger.log_info("\agAutoLesson: activated Lesson of the Devoted.")
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.Text("Lesson Ready:")
    ImGui.SameLine()
    if mq.TLO.Me.AltAbilityReady(AA_NAME)() then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionPassColor, "Yes")
    else
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "No")
    end

    ImGui.Text("Activated This Session:")
    ImGui.SameLine()
    ImGui.Text(tostring(self.useCount))

    if self.lastUsed then
        ImGui.Text("Last Activated:")
        ImGui.SameLine()
        ImGui.Text(os.date("%H:%M:%S", self.lastUsed))
    end
end

return Module
