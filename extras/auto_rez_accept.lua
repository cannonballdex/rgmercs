-- RGMercs User Module: Auto Rez Accept
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/auto_rez_accept.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "AutoRezAccept"
--
-- Watches the resurrect confirmation popup (ConfirmationDialogBox) while you're
-- dead. If it can identify both the offering caster's name and the offered
-- experience %% in the popup text, the caster is in your guild, and the %%
-- meets your minimum, it accepts. Otherwise it leaves the popup alone for you
-- or MQ2Rez to handle. This is a safety net alongside MQ2Rez, not a
-- replacement -- it only ever acts when its own checks are satisfied.
--
-- Survives RGMercs updates because it lives in your config folder, not lua/rgmercs.

local mq        = require('mq')
local ImGui     = require('ImGui')
local Base      = require("modules.base")
local Config    = require('utils.config')
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Ui        = require("utils.ui")

local Module    = {
    _version = '1.0',
    _name    = "AutoRezAccept",
    _author  = "Cannonballdex",
    _about   = "Auto-accepts a resurrect offer while dead, if the caster is in your guild and the offered %% meets your minimum. A safety net alongside MQ2Rez, not a replacement.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why didn't it accept a rez I expected it to?",
        Answer   = "It only acts while you're actually dead (hovering) with the resurrect confirmation window open, and only if it can find both the caster's name and the offered percentage in the popup text, the caster is in your guild, and the percentage meets your minimum. If the popup wording doesn't match what this module expects, it logs the raw popup text at info level instead of guessing -- check your RGMercs log and report the exact text so the parsing can be adjusted.",
        Settings_Used = "ARAEnabled,ARAMinPct",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['ARAEnabled'] = {
        DisplayName = "Enable Auto Rez Accept",
        Category = Module._name,
        Index = 1,
        Tooltip = "Master toggle. Automatically accepts a resurrect offer while dead, if the caster is a guildmate and the offered %% meets your minimum. Runs alongside MQ2Rez as a safety net, not a replacement.",
        Default = true,
    },
    ['ARAMinPct'] = {
        DisplayName = "Minimum Accept %",
        Category = Module._name,
        Index = 2,
        Tooltip = "Minimum experience %% offered before auto-accepting a rez.",
        Default = 90,
        Min = 1,
        Max = 100,
    },
    ['ARAShowTab'] = {
        DisplayName = "Show AutoRezAccept Tab",
        Category = Module._name,
        Index = 3,
        Tooltip = "Add an AutoRezAccept tab to the main window. Turn off if you don't need the status display.",
        Default = true,
    },
}

local function RezDialogOpen()
    return mq.TLO.Window('ConfirmationDialogBox').Open() == true
end

local function GetDialogText()
    local child = mq.TLO.Window('ConfirmationDialogBox').Child('CD_TextOutput')
    return (child and child.Text()) or ""
end

--- Best-effort extraction of the offering caster's name and offered %% from the
--- popup text. Returns nil, nil if either can't be confidently found -- callers
--- must treat that as "don't act", not "assume it's fine".
--- @param text string Raw ConfirmationDialogBox text.
--- @return string|nil name, number|nil pct
local function ParseRezOffer(text)
    if not text or text == "" then return nil, nil end

    local pct = text:match("(%d+)%%")
    if not pct then return nil, nil end

    -- Try a few common phrasings; if none match, deliberately return no name
    -- rather than guess, so the caller skips auto-accepting an unverified offer.
    local name = text:match("^(%a+) has") or text:match("^(%a+) will") or text:match("^(%a+) offers")

    return name, tonumber(pct)
end

--- Whether the named PC is in the local character's guild.
--- @param name string
--- @return boolean
local function IsGuildMember(name)
    if not name or name == "" then return false end
    if mq.TLO.Me.Guild() == nil then return false end

    local spawn = mq.TLO.Spawn(string.format("pc =%s", name))
    if spawn() and spawn.Guild() == mq.TLO.Me.Guild() then
        return true
    end

    -- The caster may not be a nearby spawn we can query directly from a corpse's
    -- perspective; fall back to the group roster, which reports guild tags too.
    local groupSize = mq.TLO.Group.Members() or 0
    for i = 1, groupSize do
        local member = mq.TLO.Group.Member(i)
        if member and member.Name() == name then
            return member.Guild() ~= nil and member.Guild() == mq.TLO.Me.Guild()
        end
    end

    return false
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.lastSeenText = nil
    self.acceptCount = 0
    self.lastAccepted = nil
end

function Module:ShouldRender()
    return Config:GetSetting('ARAShowTab') and true or false
end

function Module:GiveTime()
    if not Config:GetSetting('ARAEnabled') then return end

    if not RezDialogOpen() then
        self.lastSeenText = nil
        return
    end

    -- Only act while actually dead -- a ConfirmationDialogBox is reused for many
    -- unrelated prompts, but you can't trigger those while hovering as a corpse.
    if not mq.TLO.Me.Hovering() then return end

    local text = GetDialogText()
    if text == self.lastSeenText then return end -- already evaluated this exact popup
    self.lastSeenText = text

    local name, pct = ParseRezOffer(text)
    if not name or not pct then
        Logger.log_info("\ayAutoRezAccept: resurrect popup text didn't match expected patterns, leaving it alone: %s", text)
        return
    end

    if pct < Config:GetSetting('ARAMinPct') then
        Logger.log_debug("AutoRezAccept: %s offered %d%%, below your minimum -- leaving it for you/MQ2Rez.", name, pct)
        return
    end

    if not IsGuildMember(name) then
        Logger.log_debug("AutoRezAccept: %s isn't recognized as a guildmate -- leaving it for you/MQ2Rez.", name)
        return
    end

    mq.TLO.Window('ConfirmationDialogBox').Child('CD_Yes_Button').LeftMouseUp()
    self.acceptCount = self.acceptCount + 1
    self.lastAccepted = os.time()
    Logger.log_info("\agAutoRezAccept: accepted a %d%% rez from guildmate %s.", pct, name)
end

function Module:OnZone()
    self.lastSeenText = nil
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.Text("Rez Popup:")
    ImGui.SameLine()
    if RezDialogOpen() then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "Open")
    else
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionPassColor, "Closed")
    end

    ImGui.Text("Accepted This Session:")
    ImGui.SameLine()
    ImGui.Text(tostring(self.acceptCount))

    if self.lastAccepted then
        ImGui.Text("Last Accepted:")
        ImGui.SameLine()
        ImGui.Text(os.date("%H:%M:%S", self.lastAccepted))
    end
end

return Module
