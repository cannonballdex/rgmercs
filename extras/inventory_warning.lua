-- RGMercs User Module: Inventory Warning
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/inventory_warning.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "InventoryWarning"
--
-- Watches your free inventory slots and announces to the group (or just
-- logs) once when you're running low, instead of finding out mid-pull.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Comms    = require("utils.comms")
local Config   = require('utils.config')
local Logger   = require("utils.logger")

local Module   = {
    _version = '1.0',
    _name    = "InventoryWarning",
    _author  = "Cannonballdex",
    _about   = "Warns once when your free inventory slots drop to the threshold, instead of finding out mid-pull.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why did I only get warned once?",
        Answer   = "The warning fires once when you cross the threshold, then waits until your free slots recover " ..
            "above it before it can fire again - otherwise it'd spam every tick while you're farming with a full bag.",
        Settings_Used = "InvWarnThreshold,InvWarnToGroup",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['InvWarnThreshold'] = {
        DisplayName = "Warn At Free Slots",
        Category = Module._name,
        Index = 1,
        Tooltip = "Warn once your free inventory slots drop to or below this number.",
        Default = 3,
        Min = 0,
        Max = 20,
    },
    ['InvWarnToGroup'] = {
        DisplayName = "Announce To Group",
        Category = Module._name,
        Index = 2,
        Tooltip = "Also announce the warning to your group, not just your own log.",
        Default = false,
    },
}

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.warned = false
end

function Module:ShouldRender()
    return true
end

function Module:GiveTime()
    local free = mq.TLO.Me.FreeInventory(3)()
    if free == nil then return end
    local threshold = Config:GetSetting('InvWarnThreshold') or 3

    if free <= threshold and not self.warned then
        self.warned = true
        local msg = string.format("Inventory low: %d free slot(s) left.", free)
        Logger.log_warn("\ay%s", msg)
        if Config:GetSetting('InvWarnToGroup') then
            Comms.PrintGroupMessage("%s", msg)
        end
    elseif free > threshold then
        self.warned = false
    end
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local free      = mq.TLO.Me.FreeInventory(3)() or 0
    local threshold = Config:GetSetting('InvWarnThreshold') or 3

    ImGui.Text("Free Inventory Slots:")
    ImGui.SameLine()
    if free <= threshold then
        ImGui.TextColored(ImVec4(1.0, 0.3, 0.3, 1.0), tostring(free))
    else
        ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), tostring(free))
    end
end

return Module
