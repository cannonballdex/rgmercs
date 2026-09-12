-- RGMercs User Module: Merc Stance Monitor
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/merc_stance_monitor.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "MercStanceMonitor"
--
-- Surfaces the merc-stance-unsupported detection RGMercs already tracks in
-- Globals.MercStanceUnsupported (built up in init.lua's own stance-attempt
-- logic), so you can actually SEE which stances got marked unsupported for
-- your current mercenary, instead of it being invisible background state.

local mq       = require('mq')
local ImGui    = require('ImGui')
local Icons    = require('mq.ICONS')
local Base     = require("modules.base")
local Globals  = require("utils.globals")
local Logger   = require("utils.logger")
local Ui       = require("utils.ui")

local Module   = {
    _version = '1.0',
    _name    = "MercStanceMonitor",
    _author  = "Cannonballdex",
    _about   = "Shows current merc stance and which stances were auto-detected as unsupported for this merc's tier.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why does this show 'unsupported' stances?",
        Answer   = "RGMercs has no way to directly ask a mercenary's tier (Apprentice/Journeyman/etc.), so it learns which " ..
            "stances fail by trying them and watching for the stance to not actually change. Once learned, it stops " ..
            "wasting a real /stance attempt on that stance again for this merc. This tab just shows what it has learned " ..
            "so far, and lets you clear that memory if you think it learned wrong (e.g. after a merc upgrade).",
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

function Module:New()
    return Base.New(self)
end

function Module:ShouldRender()
    return true
end

--- Deletes the on-disk memory file for the given merc name, if any.
local function DeleteStanceFile(mercName)
    local path = string.format("%s/RGMercs_MercStance_%s.lua", mq.configDir, mercName)
    os.remove(path)
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local merc = mq.TLO.Me.Mercenary
    if not merc() then
        ImGui.TextColored(ImVec4(0.7, 0.7, 0.7, 1.0), "No mercenary out.")
        return
    end

    local mercName = merc.Name() or "Unknown"
    ImGui.Text("Mercenary:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(1, 1, 0.5, 1), mercName)
    ImGui.SameLine()
    ImGui.Text(string.format("(%s)", (merc.Class and merc.Class.ShortName()) or "?"))

    ImGui.Text("Current Stance:")
    ImGui.SameLine()
    ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), merc.Stance() or "Unknown")

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local trackedFor = Globals.MercStanceUnsupportedForName
    if trackedFor ~= mercName then
        ImGui.TextColored(ImVec4(0.7, 0.7, 0.7, 1.0), "No stance data learned yet for this mercenary this session.")
    else
        local unsupported = Globals.MercStanceUnsupported or {}
        local names = {}
        for stance in pairs(unsupported) do table.insert(names, stance) end
        table.sort(names)

        if #names == 0 then
            ImGui.TextColored(ImVec4(0.4, 1.0, 0.4, 1.0), "No unsupported stances learned yet - every stance tried so far has worked.")
        else
            ImGui.Text("Stances learned as unsupported for this merc:")
            ImGui.Indent()
            for _, stance in ipairs(names) do
                ImGui.BulletText(stance)
            end
            ImGui.Unindent()
        end
    end

    ImGui.Spacing()
    if ImGui.SmallButton(Icons.MD_REFRESH .. " Forget Learned Stances") then
        Globals.MercStanceUnsupported = {}
        Globals.MercStanceUnsupportedForName = ""
        DeleteStanceFile(mercName)
        Logger.log_info("\ayMercStanceMonitor: cleared learned stance data for %s.", mercName)
    end
    Ui.Tooltip("Clears what RGMercs has learned about this merc's unsupported stances (e.g. after a merc upgrade), so it re-tests from scratch.")
end

return Module
