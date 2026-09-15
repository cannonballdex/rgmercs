-- RGMercs User Module: Corpse Recovery
-- Author: Cannonballdex
-- Ported from EasyLua's corpserecovery.lua
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/corpse_recovery.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "CorpseRecovery"
--
-- For Rogues and Bards only (the only classes with a real self-invis to travel
-- safely). Periodically scans for reachable corpses in priority order (group,
-- guild, raid, then DanNet peers), goes invis, drags the corpse back to a safe
-- spot near where you started, drops it, and resumes.
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

local Module   = {
    _version = '1.0',
    _name    = "CorpseRecovery",
    _author  = "Cannonballdex",
    _about   = "Periodically recovers group/guild/raid/DanNet peer corpses using invis (Rogue/Bard only).",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why isn't it doing anything?",
        Answer   = "It only runs on Rogues and Bards (the only classes with a reliable self-invis for this). It also " ..
            "waits until you're not in combat, not hovering as a ghost, and have no hostile XTargets before it will " ..
            "go looking for a corpse to recover.",
        Settings_Used = "CREnabled",
    },
    {
        Question = "What order does it recover corpses in?",
        Answer   = "Group corpses first, then guild, then raid, then DanNet peers -- each can be turned off " ..
            "independently. It only considers corpses between the min and max distance settings, and only ones it " ..
            "can actually path to.",
        Settings_Used = "CRDoGroup, CRDoGuild, CRDoRaid, CRDoDanNet, CRMinDistance, CRMaxDistance",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['CREnabled'] = {
        DisplayName = "Enable Corpse Recovery",
        Category = Module._name,
        Index = 1,
        Tooltip = "Master toggle. Periodically scans for and recovers reachable corpses (Rogue/Bard only).",
        Default = true,
    },
    ['CRShowTab'] = {
        DisplayName = "Show CorpseRecovery Tab",
        Category = Module._name,
        Index = 2,
        Tooltip = "Add a CorpseRecovery tab to the main window. Turn off if you don't need the status display.",
        Default = true,
    },
    ['CRCheckInterval'] = {
        DisplayName = "Check Interval (seconds)",
        Category = Module._name,
        Index = 3,
        Tooltip = "How often to scan for recoverable corpses.",
        Default = 5,
        Min = 1,
        Max = 60,
    },
    ['CRMinDistance'] = {
        DisplayName = "Min Distance",
        Category = Module._name,
        Index = 4,
        Tooltip = "Ignore corpses closer than this -- avoids dragging a corpse that's already basically where it needs to be.",
        Default = 75,
        Min = 0,
        Max = 1000,
    },
    ['CRMaxDistance'] = {
        DisplayName = "Max Distance",
        Category = Module._name,
        Index = 5,
        Tooltip = "Ignore corpses farther than this.",
        Default = 5000,
        Min = 100,
        Max = 20000,
    },
    ['CRDoGroup'] = {
        DisplayName = "Recover Group Corpses",
        Category = Module._name,
        Index = 6,
        Default = true,
    },
    ['CRDoGuild'] = {
        DisplayName = "Recover Guild Corpses",
        Category = Module._name,
        Index = 7,
        Default = true,
    },
    ['CRDoRaid'] = {
        DisplayName = "Recover Raid Corpses",
        Category = Module._name,
        Index = 8,
        Default = true,
    },
    ['CRDoDanNet'] = {
        DisplayName = "Recover DanNet Peer Corpses",
        Category = Module._name,
        Index = 9,
        Tooltip = "Requires MQ2DanNet to be loaded.",
        Default = true,
    },
}

-- Helper: Manhattan distance between two points (matches the reference script).
local function FetchDistance(x1, y1, x2, y2)
    return math.abs(x2 - x1) + math.abs(y2 - y1)
end

-- Safe to act: not a ghost, not immune, not locked down, and not already engaged.
local function Checked()
    return not mq.TLO.Me.Hovering()
        and not mq.TLO.Me.Invulnerable()
        and not mq.TLO.Me.Silenced()
        and not mq.TLO.Me.Mezzed()
        and not mq.TLO.Me.Charmed()
        and not mq.TLO.Me.Feigning()
        and not mq.TLO.Me.Stunned()
end

local function Alive()
    return mq.TLO.NearestSpawn('pc')() ~= nil
end

local function HasHostileXTargets()
    local xtargetcount = mq.TLO.Me.XTarget() or 0
    if xtargetcount == 0 then return false end

    for i = 1, xtargetcount do
        local xtarget = mq.TLO.Me.XTarget(i)
        if xtarget and xtarget.ID() and xtarget.ID() > 0 and xtarget.Type() == "NPC" then
            local aggressive = xtarget.Aggressive()
            local pctAggro = xtarget.PctAggro() or 0
            if aggressive or pctAggro > 0 then return true end
        end
    end

    return false
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)
    self.lastCheck = 0
    self.recoverCount = 0
    self.lastRecovered = nil
    self.lastRecoveredAt = nil
end

function Module:ShouldRender()
    return Config:GetSetting('CRShowTab') and true or false
end

--- Drags one corpse back to the spot we started from, then drops it there.
---@param corpsid number
---@param corpse string
function Module:Drag(corpsid, corpse)
    Logger.log_info("\aw[Corpse Drag] \atRecovering corpse: %s", corpse)

    if mq.TLO.Me.Combat() then
        while mq.TLO.Me.Combat() do
            mq.delay(100)
        end
    end

    if mq.TLO.Me.Hovering() then
        while mq.TLO.Me.Hovering() do
            mq.delay(100)
        end
    end

    Core.DoCmd('/squelch /multiline ; /mqpause on; /stick off; /moveto stop; /nav stop')
    mq.delay(100)

    local x = mq.TLO.Me.X()
    local y = mq.TLO.Me.Y()
    local z = mq.TLO.Me.Z()
    local myname = mq.TLO.Me.Name()

    -- Bard: go invisible.
    if Alive() and not mq.TLO.Me.Invis() and mq.TLO.Me.Class.ShortName() == 'BRD' then
        Core.DoCmd('/twist stop')
        Core.DoCmd('/alt activate 231')
        Core.DoCmd('/dgga /removelev')
        mq.delay(1000)
    end

    -- Rogue: hide.
    if Alive() and not mq.TLO.Me.Invis('SOS')() and mq.TLO.Me.Class.ShortName() == 'ROG' then
        Core.DoCmd('/makemevisible')
        Core.DoCmd('/dismount')
        mq.delay(500)
        if not mq.TLO.Me.Sneaking() then
            while not mq.TLO.Me.AbilityReady('Sneak')() do
                mq.delay(10)
            end
            Core.DoCmd('/doability sneak')
            mq.delay(500)
        end
        while not mq.TLO.Me.AbilityReady('Hide')() do
            mq.delay(10)
        end
        Core.DoCmd('/doability hide')
        mq.delay(500)
        Core.DoCmd('/removelev')
    end

    -- Target and get consent.
    Core.DoCmd('/tar id %s', corpsid)
    mq.delay(500)

    if mq.TLO.Target.ID() ~= corpsid then
        Logger.log_warn("\aw[Corpse Drag] \arFailed to target corpse!")
        return
    end

    Core.DoCmd('/dex %s /consent %s', corpse, myname)
    mq.delay(1000)

    if not Alive() or not mq.TLO.Navigation.PathExists('target')() then
        Logger.log_warn("\aw[Corpse Drag] \arCannot navigate to corpse!")
        return
    end

    -- Navigate to the corpse.
    local attempts = 0
    while mq.TLO.Target.Distance() ~= nil and mq.TLO.Target.Distance() >= 21 do
        if not mq.TLO.Navigation.Active() then
            Core.DoCmd('/nav target log=off')
            attempts = attempts + 1
            if attempts > 100 then
                Logger.log_warn("\aw[Corpse Drag] \arTimeout reaching corpse!")
                return
            end
        end
        mq.delay(100)
    end

    -- Drag the corpse.
    if Alive() and mq.TLO.Target.Distance() ~= nil and mq.TLO.Target.Distance() <= 20 then
        Core.DoCmd('/squelch /corpsedrag')
        mq.delay(1000)
    else
        Logger.log_warn("\aw[Corpse Drag] \arCannot drag corpse!")
        return
    end

    Core.DoCmd('/squelch /multiline ; /mqpause on; /stick off; /moveto stop; /nav stop')
    mq.delay(100)

    -- Navigate back to where we started.
    Core.DoCmd('/squelch /nav locxyz %s %s %s log=off', x, y, z)

    local timeout = 0
    while FetchDistance(mq.TLO.Me.X(), mq.TLO.Me.Y(), x, y) >= 20 do
        if not mq.TLO.Navigation.Active() then
            Core.DoCmd('/squelch /nav locxyz %s %s %s log=off', x, y, z)
        end
        mq.delay(100)
        timeout = timeout + 1
        if timeout > 300 then break end
    end

    while mq.TLO.Navigation.Active() do
        mq.delay(100)
    end

    Core.DoCmd('/corpsedrop')
    mq.delay(500)
    Core.DoCmd('/squelch /mqpause off')

    self.recoverCount = self.recoverCount + 1
    self.lastRecovered = corpse
    self.lastRecoveredAt = os.time()
    Logger.log_info("\aw[Corpse Drag] \agCorpse recovered: %s", corpse)
end

-- Scan `corpses` (nearest-first) for the first one `isMatch` accepts; drag it if reachable.
---@param corpses table
---@param isMatch fun(c: table): string|nil
---@param label string
---@return boolean
function Module:FindAndDrag(corpses, isMatch, label)
    for _, c in ipairs(corpses) do
        local owner = isMatch(c)
        if owner and mq.TLO.Navigation.PathExists('id ' .. c.id)() then
            Logger.log_info("\aw[Corpse Drag] \agFound %s corpse: %s (Distance: %.2f)", label, owner, c.dist)
            self:Drag(c.id, owner)
            return true
        end
    end
    return false
end

function Module:CorpseRecovery()
    local myclass = mq.TLO.Me.Class.ShortName()
    if myclass ~= 'ROG' and myclass ~= 'BRD' then return end

    if not Checked() or mq.TLO.Me.Combat() or HasHostileXTargets() then return end

    local maxDistance = Config:GetSetting('CRMaxDistance')
    local minDistance = Config:GetSetting('CRMinDistance')

    local corpsecount = mq.TLO.SpawnCount('pccorpse radius ' .. maxDistance)()
    if not corpsecount or corpsecount == 0 then return end

    local raidcount = mq.TLO.Raid.Members() or 0
    local groupcount = mq.TLO.Group.Members() or 0
    local myguild = mq.TLO.Me.Guild()

    -- Collect qualifying corpses first, nearest to farthest.
    local corpses = {}
    for c = 1, corpsecount do
        local spawn = mq.TLO.NearestSpawn(c .. ',pccorpse radius ' .. maxDistance)

        if spawn and spawn() then
            local corpsename = spawn.CleanName()
            local corpseid = spawn.ID()
            local corpsedist = spawn.Distance()
            local corpseguild = spawn.Guild()

            if corpseid and corpsename and corpsedist and corpsedist >= minDistance then
                corpses[#corpses + 1] = { name = corpsename, id = corpseid, dist = corpsedist, guild = corpseguild, }
            end
        end
    end

    if #corpses == 0 then return end

    -- PRIORITY 1: Group corpses.
    if Config:GetSetting('CRDoGroup') and groupcount > 0 then
        local groupNames = {}
        for g = 0, groupcount do
            local groupmember = mq.TLO.Group.Member(g).Name()
            if groupmember then groupNames[groupmember .. "'s corpse"] = groupmember end
        end
        if self:FindAndDrag(corpses, function(c) return groupNames[c.name] end, 'group') then return end
    end

    -- PRIORITY 2: Guild corpses.
    if Config:GetSetting('CRDoGuild') and myguild then
        local isGuildMatch = function(c)
            if c.guild and myguild == c.guild then
                return c.name:match("(.+)'s corpse")
            end
        end
        if self:FindAndDrag(corpses, isGuildMatch, 'guild') then return end
    end

    -- PRIORITY 3: Raid corpses.
    if Config:GetSetting('CRDoRaid') and raidcount > 0 then
        local raidNames = {}
        for r = 1, raidcount do
            local raidmember = mq.TLO.Raid.Member(r).Name()
            if raidmember then raidNames[raidmember .. "'s corpse"] = raidmember end
        end
        if self:FindAndDrag(corpses, function(c) return raidNames[c.name] end, 'raid') then return end
    end

    -- PRIORITY 4: DanNet peer corpses.
    if Config:GetSetting('CRDoDanNet') and mq.TLO.Plugin('mq2dannet')() then
        local dannetscount = mq.TLO.DanNet.PeerCount()
        if dannetscount and dannetscount > 0 then
            for peers in string.gmatch(mq.TLO.DanNet.Peers(), "([^|]+)") do
                local spawnedsearch = string.format('pccorpse %s radius %s', peers, maxDistance)
                local corpses_count = mq.TLO.SpawnCount(spawnedsearch)()

                if corpses_count and corpses_count > 0 then
                    for corpse = 1, corpses_count do
                        local corpse_ID = mq.TLO.NearestSpawn(corpse, spawnedsearch).ID()
                        local corpse_dist = mq.TLO.NearestSpawn(corpse, spawnedsearch).Distance()

                        if Alive() and corpse_ID and Checked()
                            and corpse_dist and corpse_dist >= minDistance
                            and mq.TLO.Navigation.PathExists('id ' .. corpse_ID)() then
                            Core.DoCmd('/mqtarget id %s', corpse_ID)
                            mq.delay(500)

                            if mq.TLO.Target.ID() == corpse_ID then
                                Core.DoCmd('/dge all /consent %s', mq.TLO.Me.CleanName())
                                mq.delay(2000)

                                Logger.log_info("\aw[Corpse Drag] \agFound DanNet corpse: %s (Distance: %.2f)", peers, corpse_dist)
                                self:Drag(corpse_ID, mq.TLO.Target.CleanName())
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end

function Module:GiveTime()
    if not Config:GetSetting('CREnabled') then return end

    local myclass = mq.TLO.Me.Class.ShortName()
    if myclass ~= 'ROG' and myclass ~= 'BRD' then return end

    local now = Globals.GetTimeSeconds()
    if now - self.lastCheck < Config:GetSetting('CRCheckInterval') then return end
    self.lastCheck = now

    self:CorpseRecovery()
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    local myclass = mq.TLO.Me.Class.ShortName()
    if myclass ~= 'ROG' and myclass ~= 'BRD' then
        Ui.RenderColoredText(Globals.Constants.Colors.ConditionFailColor, "Only Rogues and Bards can recover corpses.")
        return
    end

    ImGui.Text("Corpses Recovered This Session:")
    ImGui.SameLine()
    ImGui.Text(tostring(self.recoverCount))

    if self.lastRecovered then
        ImGui.Text("Last Recovered:")
        ImGui.SameLine()
        ImGui.Text(string.format("%s (%s)", self.lastRecovered, os.date("%H:%M:%S", self.lastRecoveredAt)))
    end
end

return Module
