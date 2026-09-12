-- RGMercs User Module: Close Popup
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/close_popup.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "ClosePopup"
--
-- Auto-dismisses the F2P "AlertWnd" popup (the "you are running low on X"
-- nag window) as soon as it appears, instead of it sitting there blocking
-- input until someone notices it.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Base     = require("modules.base")
local Globals  = require("utils.globals")
local Config   = require('utils.config')
local Logger   = require("utils.logger")
local Ui       = require("utils.ui")

local Module   = {
    _version = '1.0',
    _name    = "ClosePopup",
    _author  = "Cannonballdex",
    _about   = "Automatically dismisses the F2P AlertWnd popup when it appears.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why does it wait before dismissing?",
        Answer   = "It waits a short delay after the popup is seen before clicking Dismiss, matching the original " ..
            "behavior this module was ported from. If the popup closes on its own during that wait (e.g. you " ..
            "dismissed it manually), the click is skipped.",
        Settings_Used = "CPWaitSeconds",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['CPEnabled'] = {
        DisplayName = "Enable Close Popup",
        Category = Module._name,
        Index = 1,
        Tooltip = "Master toggle for automatically dismissing the F2P alert popup (AlertWnd) when it appears.",
        Default = true,
    },
    ['CPWaitSeconds'] = {
        DisplayName = "Wait To Dismiss (Seconds)",
        Category = Module._name,
        Index = 2,
        Tooltip = "How long to wait after the popup is seen before clicking Dismiss. Set to 0 to dismiss immediately.",
        Default = 5,
        Min = 0,
        Max = 30,
    },
}

local function PopupOpen()
    return mq.TLO.Window('AlertWnd').Open() == true
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.closeCount = 0
    self.lastClosed = nil
end

function Module:ShouldRender()
    return true
end

function Module:GiveTime()
    if not Config:GetSetting('CPEnabled') then return end
    if not PopupOpen() then return end

    local wait = Config:GetSetting('CPWaitSeconds') or 5
    if wait > 0 then
        mq.delay(wait * 1000, function() return not PopupOpen() end)
        if not PopupOpen() then return end
    end

    mq.cmd('/notify AlertWnd "ALW_Dismiss_button" leftmouseup')
    self.closeCount = self.closeCount + 1
    self.lastClosed = os.time()
    Logger.log_info("\ayClosePopup: dismissed the F2P alert popup.")
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.Text("F2P Alert Popup:")
    ImGui.SameLine()
    if PopupOpen() then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "Open")
    else
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionPassColor, "Closed")
    end

    ImGui.Text("Dismissed This Session:")
    ImGui.SameLine()
    ImGui.Text(tostring(self.closeCount))

    if self.lastClosed then
        ImGui.Text("Last Dismissed:")
        ImGui.SameLine()
        ImGui.Text(os.date("%H:%M:%S", self.lastClosed))
    end
end

return Module
