-- RGMercs User Module: Player AA Buyer
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/playeraa.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "PlayerAA"
--
-- Buys regular (General / Archetype / Class / Special / Focus) AAs once your
-- AA points reach the threshold you set, from a purchase list you control.
-- Keeps its own floating GUI (/playeraa ui) and the same per-character settings
-- file as the standalone PlayerAA script, so do not run both at once.
--
-- Commands:
--   /playeraa help | ui | status | scan | buy | pause | resume
--   /playeraa priority | save | load | reset
-- ============================================================

local mq = require('mq')
local PackageMan = require('mq/PackageMan')
local lfs = PackageMan.Require(
    'luafilesystem',
    'lfs',
    '[PlayerAA] LuaFileSystem is required to create the config directory.'
)
local imgui = require('ImGui')
local Base = require("modules.base")
local Combat = require("utils.combat")
local Config = require('utils.config')

local VERSION = 'v1.0'
-- the ### part keeps the window's saved size and position when the version changes
local WINDOW_TITLE = ('PlayerAA.lua by Cannonballdex™ %s###PlayerAABuyerGUI'):format(VERSION)

-- Cannonballdex logo for the window header, loaded once if the file is there
local logoTexture
do
    local logoPath = mq.luaDir .. '/rgmercs/extras/cannonballdex.png'
    local f = io.open(logoPath, 'rb')
    if f then
        f:close()
        logoTexture = mq.CreateTexture(logoPath)
    end
end

local Module = {
    _version = '1.0',
    _name    = "PlayerAA",
    _author  = "Cannonballdex",
    _about   = "Automatically trains regular AAs from a purchase list once your AA points cross a threshold.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why does PlayerAA start paused?",
        Answer   = "The first time it runs on a character it has no saved list, so every AA is switched ON. It starts paused so you can " ..
            "switch OFF the AAs you do not want, then click Resume. It also starts paused when the account is not Gold, because EQ limits AAs there.",
        Settings_Used = "",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['PlayerAAShowTab'] = {
        DisplayName = "Show PlayerAA Tab",
        Category = Module._name,
        Index = 1,
        Tooltip = "Add a PlayerAA tab to the main window. Turn off if you don't need the status display and just want it running quietly.",
        Default = true,
    },
}

-- ============================================================
-- Configuration
-- ============================================================

-- Begin purchasing when this many AA points are available.
local AA_THRESHOLD = 50

-- Go through the motions without buying. Always starts OFF.
local TEST_MODE = false

-- Print extra information about every Train button lookup. Always starts OFF.
local BUTTON_DEBUG = false

-- How often to check the available AA points.
local CHECK_INTERVAL_MS = 5000

-- UI delays.
local WINDOW_OPEN_TIMEOUT_MS = 5000
local TAB_CHANGE_TIMEOUT_MS = 3000
local ROW_SELECT_DELAY_MS = 500
local PURCHASE_TIMEOUT_MS = 5000
local PURCHASE_DELAY_MS = 750

-- Never buy more than this many ranks of one AA in a single pass (safety net).
local MAX_RANKS_PER_PASS = 50

-- Do not immediately repeat a failed automatic purchase cycle.
local FAILED_SCAN_COOLDOWN_MS = 60000

-- Close the AA window after a purchase cycle (if the script opened it).
local CLOSE_AA_WINDOW_WHEN_FINISHED = true

-- ============================================================
-- UI control names
-- ============================================================

local AA_WINDOW = 'AAWindow'
local TAB_BOX = 'AAW_Subwindows'
local TRAIN_BUTTON = 'AAW_TrainButton'

-- The regular AA tabs, in the order EQ shows them.
local TABS = {
    { index = 1, key = 'general',   label = 'General',   list = 'AAW_GeneralList' },
    { index = 2, key = 'archetype', label = 'Archetype', list = 'AAW_ArchList' },
    { index = 3, key = 'class',     label = 'Class',     list = 'AAW_ClassList' },
    { index = 4, key = 'special',   label = 'Special',   list = 'AAW_SpecialList' },
    { index = 5, key = 'focus',     label = 'Focus',     list = 'AAW_FocusList' },
}
local TAB_BY_KEY = {}
for _, tab in ipairs(TABS) do TAB_BY_KEY[tab.key] = tab end

-- List columns: 1 = name, 2 = "current/max", 3 = cost
local COL_NAME, COL_RANK, COL_COST = 1, 2, 3

-- ============================================================
-- Runtime state
-- ============================================================

local running = true
local paused = false
local thresholdHandled = false
local lastFailedScanTime = 0

local gui = {
    open = true,
    applyInitialLayout = true,
    status = 'Ready. Availability is checked when your points reach the threshold, or click Check Availability.',
    points = 0,          -- AA points, spent points and membership, read by the main loop; the window only draws these
    spent = 0,
    sub = 'UNKNOWN',
    state = {},          -- [aa name] = 'available' / 'locked' / 'maxed', from the last check
    info = {},           -- [aa name] = { tab = key, cur = n, max = n, cost = n }
    eqOrder = {},        -- every AA name in EQ's order (General, Archetype, Class, Special, Focus)
    pendingAction = nil,
    selectedPriorityIndex = 0,
    filter = 'all',      -- which tab the Purchase List shows
    hideMaxed = false,
    windowX = nil,
    windowY = nil,
}

local settingsDirty = false
local lastSettingsSaveTime = 0
local SETTINGS_SAVE_DELAY_MS = 750

local priority = {
    -- Modes:
    -- priority = your list, top to bottom
    -- eq_order = the order EQ lists them (General, Archetype, Class, Special, Focus)
    -- Either way, only AAs switched ON are bought.
    mode = 'priority',
    entries = {},        -- { name = string, enabled = bool, tab = key }
}

local lastAutomaticCheckTime = 0

-- ============================================================
-- Logging
-- ============================================================

local function log(message)
    printf('\ag[PlayerAA]\ax %s', tostring(message))
end

local function warn(message)
    printf('\ay[PlayerAA]\ax %s', tostring(message))
end

local function fail(message)
    printf('\ar[PlayerAA]\ax %s', tostring(message))
end

local function debugLog(message)
    if BUTTON_DEBUG then
        printf('\at[PlayerAA Debug]\ax %s', tostring(message))
    end
end

-- ============================================================
-- General helpers
-- ============================================================

local function trim(value)
    if value == nil then return '' end
    return tostring(value):match('^%s*(.-)%s*$')
end

local function toNumber(value, defaultValue)
    local result = tonumber(value)
    if result == nil then return defaultValue or 0 end
    return result
end

local function toBoolean(value)
    if value == true then return true end
    if value == false or value == nil then return false end
    if type(value) == 'number' then return value ~= 0 end
    local text = tostring(value):upper()
    return text == 'TRUE' or text == '1' or text == 'YES' or text == 'ON' or text == 'ENABLED'
end

local function waitUntil(timeoutMs, condition)
    local startTime = mq.gettime()
    while running and mq.gettime() - startTime < timeoutMs do
        local success, result = pcall(condition)
        if success and result then return true end
        mq.delay(50)
    end
    return false
end

local function isInGame()
    local success, gameState = pcall(function() return mq.TLO.MacroQuest.GameState() end)
    return success and gameState == 'INGAME'
end

local function isZoning()
    local success, zoning = pcall(function() return mq.TLO.Me.Zoning() end)
    return success and toBoolean(zoning)
end

-- Buying opens the AA window and clicks through it, and GiveTime runs on RGMercs' main loop,
-- so it waits for a quiet moment
local function inCombat()
    local success, state = pcall(function() return Combat.GetCachedCombatState() end)
    return success and state == "Combat"
end

-- ============================================================
-- Per-character configuration
-- ============================================================

local function sanitizeFileName(value)
    local text = trim(value)
    if text == '' then return 'Unknown' end
    return (text:gsub('[<>:"/\\|%?%*]', '_'):gsub('%s+', '_'))
end

local function getCharacterName()
    local success, name = pcall(function() return mq.TLO.Me.CleanName() end)
    if success and trim(name) ~= '' then return trim(name) end
    return 'UnknownCharacter'
end

local function getServerName()
    for _, lookup in ipairs({
        function() return mq.TLO.EverQuest.Server() end,
        function() return mq.TLO.MacroQuest.Server() end,
    }) do
        local success, name = pcall(lookup)
        if success and trim(name) ~= '' then return trim(name) end
    end
    return 'UnknownServer'
end

local function normalizeWindowsPath(path)
    return (tostring(path):gsub('/', '\\'))
end

local function directoryExists(path)
    if not lfs or type(lfs.attributes) ~= 'function' then return false end
    return lfs.attributes(normalizeWindowsPath(path), 'mode') == 'directory'
end

local function ensureDirectoryExists(path)
    if not lfs or type(lfs.mkdir) ~= 'function' then
        fail('LuaFileSystem could not be loaded.')
        return false
    end
    local windowsPath = normalizeWindowsPath(path)
    if directoryExists(windowsPath) then return true end

    local drive, remainder = windowsPath:match('^(%a:[\\]?)(.*)$')
    local currentPath = drive or ''
    if drive == nil then remainder = windowsPath end

    for part in tostring(remainder):gmatch('[^\\]+') do
        if currentPath == '' then
            currentPath = part
        elseif currentPath:sub(-1) == '\\' then
            currentPath = currentPath .. part
        else
            currentPath = currentPath .. '\\' .. part
        end
        local mode = lfs.attributes(currentPath, 'mode')
        if mode == nil then
            local created, mkdirError = lfs.mkdir(currentPath)
            if not created and not directoryExists(currentPath) then
                fail(string.format('Could not create directory "%s": %s', currentPath, tostring(mkdirError)))
                return false
            end
        elseif mode ~= 'directory' then
            fail('Configuration path is not a directory: ' .. currentPath)
            return false
        end
    end
    return directoryExists(windowsPath)
end

-- One configuration file per server and character under MacroQuest\config\playeraa
local MQ_ROOT = normalizeWindowsPath(tostring(mq.TLO.MacroQuest.Path()))
local CONFIG_DIRECTORY = MQ_ROOT .. '\\config\\playeraa'
ensureDirectoryExists(CONFIG_DIRECTORY)

local CONFIG_FILE = string.format(
    '%s\\playeraa_%s_%s.lua',
    CONFIG_DIRECTORY,
    sanitizeFileName(getServerName()),
    sanitizeFileName(getCharacterName())
)

local function markConfigurationDirty()
    settingsDirty = true
end

local function priorityContains(name)
    for index, entry in ipairs(priority.entries) do
        if entry.name == name then return index end
    end
    return nil
end

-- Is this entry shown with the Purchase List's current tab filter / Hide Maxed?
local function isVisible(entry)
    if gui.filter ~= 'all' and entry.tab ~= gui.filter then return false end
    if gui.hideMaxed and gui.state[entry.name] == 'maxed' then return false end
    return true
end

-- Move the selected entry past the next entry that is shown (so moving
-- works the same when the list is filtered to one tab).
local function movePriority(index, direction)
    if index < 1 or index > #priority.entries then return false end
    local destination = index + direction
    while destination >= 1 and destination <= #priority.entries
        and not isVisible(priority.entries[destination]) do
        destination = destination + direction
    end
    if destination < 1 or destination > #priority.entries then return false end

    local entry = table.remove(priority.entries, index)
    table.insert(priority.entries, destination, entry)
    gui.selectedPriorityIndex = destination
    gui.status = string.format('Moved "%s" to position %d.', entry.name, destination)
    markConfigurationDirty()
    return true
end

local function togglePriority(index)
    local entry = priority.entries[index]
    if entry == nil then
        gui.status = 'Select an AA in the list first.'
        return false
    end
    entry.enabled = not entry.enabled
    gui.status = string.format('%s "%s".', entry.enabled and 'Switched ON' or 'Switched OFF', entry.name)
    markConfigurationDirty()
    return true
end

-- Switch every AA currently shown in the list ON or OFF.
local function setShown(enabled)
    local count = 0
    for _, entry in ipairs(priority.entries) do
        if isVisible(entry) and entry.enabled ~= enabled then
            entry.enabled = enabled
            count = count + 1
        end
    end
    gui.status = string.format('Switched %d shown AA(s) %s.', count, enabled and 'ON' or 'OFF')
    if count > 0 then markConfigurationDirty() end
end

local function saveConfiguration(silent)
    if not ensureDirectoryExists(CONFIG_DIRECTORY) then
        fail('Could not create configuration directory: ' .. CONFIG_DIRECTORY)
        gui.status = 'Could not create configuration directory.'
        return false
    end

    local file, openError = io.open(CONFIG_FILE, 'w')
    if file == nil then
        fail('Could not save configuration file: ' .. tostring(openError))
        gui.status = 'Could not save configuration.'
        return false
    end

    file:write('return {\n')
    file:write('    threshold = ', tostring(AA_THRESHOLD), ',\n')
    file:write('    paused = ', tostring(paused), ',\n')
    file:write('    windowX = ', tostring(gui.windowX or 'nil'), ',\n')
    file:write('    windowY = ', tostring(gui.windowY or 'nil'), ',\n')
    file:write('    mode = ', string.format('%q', priority.mode), ',\n')
    file:write('    entries = {\n')
    for _, entry in ipairs(priority.entries) do
        file:write(string.format('        { name = %q, enabled = %s, tab = %q },\n',
            entry.name, tostring(entry.enabled ~= false), entry.tab or ''))
    end
    file:write('    },\n')
    file:write('}\n')
    file:close()

    settingsDirty = false
    lastSettingsSaveTime = mq.gettime()

    if not silent then
        gui.status = string.format('Saved settings and %d AAs.', #priority.entries)
        log(gui.status)
    end
    return true
end

local function loadConfiguration()
    local chunk, loadError = loadfile(CONFIG_FILE)
    if chunk == nil then
        -- First run for this character: start paused so nothing is bought
        -- until you have looked over the list and switched off what you don't want.
        paused = true
        gui.status = 'First run: the list is filled with every AA, all ON. '
            .. 'Switch OFF what you do not want, then click Resume.'
        warn(gui.status)
        return false
    end

    local success, loaded = pcall(chunk)
    if not success or type(loaded) ~= 'table' then
        fail('Could not load configuration file: ' .. tostring(loadError or loaded))
        gui.status = 'Configuration file could not be loaded.'
        return false
    end

    AA_THRESHOLD = math.max(1, math.floor(toNumber(loaded.threshold, AA_THRESHOLD)))
    -- Test Mode and Button Debug always start OFF; they are not saved
    if loaded.paused ~= nil then paused = toBoolean(loaded.paused) end

    if tonumber(loaded.windowX) ~= nil and tonumber(loaded.windowY) ~= nil then
        gui.windowX = tonumber(loaded.windowX)
        gui.windowY = tonumber(loaded.windowY)
    end

    if loaded.mode == 'priority' or loaded.mode == 'eq_order' then
        priority.mode = loaded.mode
    end

    priority.entries = {}
    if type(loaded.entries) == 'table' then
        for _, entry in ipairs(loaded.entries) do
            if type(entry) == 'table' and trim(entry.name) ~= '' then
                priority.entries[#priority.entries + 1] = {
                    name = trim(entry.name),
                    enabled = entry.enabled ~= false,
                    tab = TAB_BY_KEY[entry.tab] and entry.tab or nil,
                }
            end
        end
    end

    gui.selectedPriorityIndex = 0
    gui.status = string.format('Loaded settings and %d AAs.', #priority.entries)
    log(gui.status)
    return true
end

local function savePriorities() return saveConfiguration(false) end
local function loadPriorities() return loadConfiguration() end

-- ============================================================
-- AA points
-- ============================================================

local function getAvailableAAPoints()
    local success, points = pcall(function() return mq.TLO.Me.AAPoints() end)
    if not success or points == nil then gui.points = 0 return 0 end
    gui.points = toNumber(points, 0)
    return gui.points
end

local function getSpentAAPoints()
    local success, points = pcall(function() return mq.TLO.Me.AAPointsSpent() end)
    if not success or points == nil then gui.spent = 0 return 0 end
    gui.spent = toNumber(points, 0)
    return gui.spent
end

-- Membership: GOLD (All Access), SILVER, FREE or UNKNOWN
local function getSubscription()
    local success, sub = pcall(function() return mq.TLO.Me.Subscription() end)
    sub = success and trim(sub):upper() or ''
    if sub == '' or sub == 'NULL' then sub = 'UNKNOWN' end
    gui.sub = sub
    return sub
end

local function isGold()
    local sub = getSubscription()
    return sub == 'GOLD' or sub == 'UNKNOWN'   -- unknown: don't hold anyone back
end

-- ============================================================
-- AA window and tab handling
-- ============================================================

local function isAAWindowOpen()
    local success, open = pcall(function() return mq.TLO.Window(AA_WINDOW).Open() end)
    return success and toBoolean(open)
end

local function openAAWindow()
    if isAAWindowOpen() then return true end
    mq.cmd('/windowstate AAWindow open')
    local opened = waitUntil(WINDOW_OPEN_TIMEOUT_MS, function()
        return mq.TLO.Window(AA_WINDOW).Open()
    end)
    if not opened then
        fail('Could not open the Alternate Advancement window.')
        return false
    end
    mq.delay(500)
    return true
end

local function closeAAWindow()
    if isAAWindowOpen() then mq.cmd('/windowstate AAWindow close') end
end

local function getList(tab)
    return mq.TLO.Window(AA_WINDOW .. '/' .. tab.list)
end

-- Is this tab's page the one showing?
local function isTabShowing(tab)
    local success, showing = pcall(function()
        local pageName = getList(tab).Parent.Name()
        local current = mq.TLO.Window(AA_WINDOW .. '/' .. TAB_BOX).CurrentTab.Name()
        if pageName == nil or current == nil then return nil end
        return pageName == current
    end)
    if not success then return nil end
    return showing
end

local function selectTab(tab)
    if not openAAWindow() then return false end
    if isTabShowing(tab) == true then return true end

    mq.cmdf('/notify %s %s tabselect %d', AA_WINDOW, TAB_BOX, tab.index)
    mq.doevents()

    -- If the page can't be read, fall back to a short wait.
    local switched = waitUntil(TAB_CHANGE_TIMEOUT_MS, function()
        return isTabShowing(tab) ~= false
    end)
    if not switched then
        fail(string.format('Could not switch the AA window to the %s tab.', tab.label))
        return false
    end
    mq.delay(300)
    return true
end

-- ============================================================
-- Reading the AA lists
-- ============================================================

local function getRowCount(tab)
    local success, count = pcall(function() return getList(tab).Items() end)
    if not success or count == nil then return 0 end
    return toNumber(count, 0)
end

local function getCell(tab, row, column)
    local success, text = pcall(function() return getList(tab).List(row, column)() end)
    if not success or text == nil then return '' end
    return trim(text)
end

local function readRow(tab, row)
    local name = getCell(tab, row, COL_NAME)
    local cur, max = getCell(tab, row, COL_RANK):match('(%d+)%s*/%s*(%d+)')
    return name, toNumber(cur, 0), toNumber(max, 0), toNumber(getCell(tab, row, COL_COST), 0)
end

local function findRowByName(tab, name)
    for row = 1, getRowCount(tab) do
        if getCell(tab, row, COL_NAME) == name then return row end
    end
    return nil
end

-- AVAILABLE / LOCKED / MAXED without clicking anything. The Train button
-- is still checked right before every purchase, so this only decides
-- what is worth trying.
local function judgeAA(name, cur, max, cost)
    if max > 0 and cur >= max then return 'maxed' end

    local ok, canTrain = pcall(function() return mq.TLO.AltAbility(name).CanTrain() end)
    if ok and toBoolean(canTrain) then return 'available' end

    -- CanTrain can be stale after a purchase, so work it out as well.
    if getAvailableAAPoints() < cost then return 'locked' end
    local okLevel, minLevel = pcall(function() return mq.TLO.AltAbility(name).MinLevel() end)
    if okLevel and toNumber(minLevel, 0) > toNumber(mq.TLO.Me.Level(), 0) then return 'locked' end
    local okReq, reqName, reqRank = pcall(function()
        local aa = mq.TLO.AltAbility(name)
        return aa.RequiresAbility.Name(), aa.RequiresAbilityPoints()
    end)
    if okReq and reqName and trim(reqName) ~= '' then
        local okHave, haveRank = pcall(function() return mq.TLO.Me.AltAbility(reqName).Rank() end)
        if not okHave or toNumber(haveRank, 0) < toNumber(reqRank, 0) then return 'locked' end
    end
    return 'available'
end

-- Read every regular AA from the five tabs: adds new ones to the end of the
-- purchase list (switched ON), and records AVAILABLE / LOCKED / MAXED.
-- Clicks nothing, so it is quick.
local function scanAllAAs()
    if not openAAWindow() then
        gui.status = 'Could not open the AA window.'
        return false
    end

    local order, seen, added, counts = {}, {}, 0, { available = 0, locked = 0, maxed = 0 }
    for _, tab in ipairs(TABS) do
        for row = 1, getRowCount(tab) do
            local name, cur, max, cost = readRow(tab, row)
            if name ~= '' and not seen[name] then
                seen[name] = true
                order[#order + 1] = name
                gui.info[name] = { tab = tab.key, cur = cur, max = max, cost = cost }
                local state = judgeAA(name, cur, max, cost)
                gui.state[name] = state
                counts[state] = counts[state] + 1

                local index = priorityContains(name)
                if index == nil then
                    priority.entries[#priority.entries + 1] = { name = name, enabled = true, tab = tab.key }
                    added = added + 1
                elseif priority.entries[index].tab ~= tab.key then
                    priority.entries[index].tab = tab.key
                    markConfigurationDirty()
                end
            end
        end
    end

    if #order == 0 then
        gui.status = 'No AAs could be read from the AA window.'
        return false
    end

    gui.eqOrder = order
    if added > 0 then
        log(string.format('Added %d AA(s) to the end of the purchase list (ON).', added))
        markConfigurationDirty()
    end

    gui.status = string.format('Checked %d AAs: %d available now, %d locked, %d maxed.',
        #order, counts.available, counts.locked, counts.maxed)
    return true
end

-- ============================================================
-- Train button
-- ============================================================

local function buttonIsValid(button)
    if button == nil then return false end
    local success, screenID = pcall(function() return button.ScreenID() end)
    if success and screenID ~= nil and tostring(screenID) ~= '' and tostring(screenID) ~= 'NULL' then
        return true
    end
    local nameSuccess, name = pcall(function() return button.Name() end)
    return nameSuccess and name ~= nil and tostring(name) ~= '' and tostring(name) ~= 'NULL'
end

local function getTrainButton()
    local candidates = {
        { location = 'AAWindow child',      get = function() return mq.TLO.Window(AA_WINDOW).Child(TRAIN_BUTTON) end },
        { location = 'AAWindow slash path', get = function() return mq.TLO.Window(AA_WINDOW .. '/' .. TRAIN_BUTTON) end },
    }
    for _, candidate in ipairs(candidates) do
        local success, button = pcall(candidate.get)
        if success and buttonIsValid(button) then return button, candidate.location end
    end
    return nil, nil
end

local function isTrainButtonEnabled()
    local button, location = getTrainButton()
    if button == nil then
        debugLog('AAW_TrainButton could not be located.')
        return false
    end
    local success, rawEnabled = pcall(function() return button.Enabled() end)
    if not success then
        debugLog('Could not read Enabled() from ' .. tostring(location))
        return false
    end
    debugLog(string.format('Train button (%s): Enabled raw="%s".', tostring(location), tostring(rawEnabled)))
    return toBoolean(rawEnabled)
end

local function selectRow(tab, row)
    mq.cmdf('/notify %s %s listselect %d', AA_WINDOW, tab.list, row)
    mq.doevents()
    mq.delay(ROW_SELECT_DELAY_MS)
    if BUTTON_DEBUG then
        local ok, selected = pcall(function() return getList(tab).SelectedIndex() end)
        debugLog(string.format('%s: requested row %d, SelectedIndex %s.', tab.label, row, tostring(ok and selected)))
    end
end

local function isConfirmationOpen()
    local success, open = pcall(function() return mq.TLO.Window('ConfirmationDialogBox').Open() end)
    return success and toBoolean(open)
end

local function acceptConfirmation()
    mq.delay(250)
    if not isConfirmationOpen() then return end
    mq.cmd('/yes')
    mq.doevents()
    waitUntil(3000, function() return not isConfirmationOpen() end)
end

-- ============================================================
-- Purchasing
-- ============================================================

-- Buy one rank: switch to the AA's tab, select it, check Train, click,
-- confirm, and verify that points were spent.
local function buyOne(name)
    local info = gui.info[name]
    local tab = info and TAB_BY_KEY[info.tab]
    if tab == nil then return false end
    if not selectTab(tab) then return false end

    local row = findRowByName(tab, name)
    if row == nil then return false end

    selectRow(tab, row)
    if not isTrainButtonEnabled() then
        local _, cur, max = readRow(tab, row)
        gui.state[name] = (max > 0 and cur >= max) and 'maxed' or 'locked'
        return false
    end

    local pointsBefore = getAvailableAAPoints()
    log(string.format('Purchasing "%s" (%s).', name, tab.label))
    mq.cmd('/notify AAWindow AAW_TrainButton leftmouseup')
    mq.doevents()
    acceptConfirmation()

    local spent = waitUntil(PURCHASE_TIMEOUT_MS, function()
        return getAvailableAAPoints() < pointsBefore
    end)
    local pointsAfter = getAvailableAAPoints()
    if not spent then
        warn(string.format('Purchase was not verified for "%s". Points before: %d; now: %d.',
            name, pointsBefore, pointsAfter))
        return false
    end

    -- refresh this AA's rank from the list
    local newRow = findRowByName(tab, name)
    if newRow then
        local _, cur, max, cost = readRow(tab, newRow)
        gui.info[name] = { tab = tab.key, cur = cur, max = max, cost = cost }
        gui.state[name] = (max > 0 and cur >= max) and 'maxed' or 'available'
    end

    log(string.format('Purchased "%s". Points %d -> %d.', name, pointsBefore, pointsAfter))
    mq.delay(PURCHASE_DELAY_MS)
    return true
end

-- The AAs to buy this cycle, in order. Only AAs switched ON are bought.
local function buildPurchaseOrder()
    local order, enabled = {}, {}
    for _, entry in ipairs(priority.entries) do
        if entry.enabled then enabled[entry.name] = true end
    end
    if priority.mode == 'eq_order' then
        for _, name in ipairs(gui.eqOrder) do
            if enabled[name] and gui.state[name] == 'available' then order[#order + 1] = name end
        end
    else
        for _, entry in ipairs(priority.entries) do
            if entry.enabled and gui.state[entry.name] == 'available' then order[#order + 1] = entry.name end
        end
    end
    return order
end

local function runPurchaseCycleBody()
    local startingPoints = getAvailableAAPoints()
    log(string.format('Purchase cycle started with %d available points.', startingPoints))

    if not scanAllAAs() then return false end
    local order = buildPurchaseOrder()

    if #order == 0 then
        warn('No AA that is switched ON can be bought right now.')
        return false
    end

    if TEST_MODE then
        log(string.format('TEST MODE: would buy, in order: %s', table.concat(order, ', ')))
        return true
    end

    -- Spend down: keep buying ranks in order while points last.
    local purchaseCount = 0
    for _, name in ipairs(order) do
        if not running or paused or isZoning() or inCombat() then break end
        if getAvailableAAPoints() <= 0 then break end
        local ranks = 0
        while running and not paused and not isZoning() and not inCombat()
            and ranks < MAX_RANKS_PER_PASS
            and getAvailableAAPoints() > 0
            and buyOne(name)
        do
            ranks = ranks + 1
            purchaseCount = purchaseCount + 1
        end
    end

    -- quick re-check so the labels are up to date
    scanAllAAs()
    log(string.format('Purchase cycle finished. Ranks bought: %d. Points remaining: %d.',
        purchaseCount, getAvailableAAPoints()))

    return purchaseCount > 0
end

-- Every way out of a cycle closes the AA window if the cycle was the one that opened it;
-- an error mid-cycle is reported and the script keeps running
local function runPurchaseCycle()
    local wasOpen = isAAWindowOpen()
    local ok, result = pcall(runPurchaseCycleBody)

    if not ok then
        fail('Purchase cycle error: ' .. tostring(result))
        result = false
    end

    if CLOSE_AA_WINDOW_WHEN_FINISHED and not wasOpen then closeAAWindow() end

    -- second value: true when the cycle raised an error
    return result, not ok
end

-- ============================================================
-- Commands
-- ============================================================

local function modeDisplayName()
    if priority.mode == 'eq_order' then return 'EQ List Order' end
    return 'Priority Order'
end

local function showStatus()
    log(string.format('Membership: %s | AA points: %d (spent %d) | Threshold: %d | Mode: %s | Test mode: %s | Paused: %s',
        getSubscription(), getAvailableAAPoints(), getSpentAAPoints(), AA_THRESHOLD, modeDisplayName(),
        tostring(TEST_MODE), tostring(paused)))
    log(string.format('AA window open: %s | List: %d AAs', tostring(isAAWindowOpen()), #priority.entries))
    if isAAWindowOpen() then
        local button, location = getTrainButton()
        log(string.format('Train button found: %s (%s) | Enabled: %s',
            tostring(button ~= nil), tostring(location), tostring(button ~= nil and isTrainButtonEnabled())))
    end
end

-- ============================================================
-- GUI
-- ============================================================

local function queueGUIAction(action)
    if gui.pendingAction ~= nil then
        gui.status = 'Another action is already queued.'
        return
    end
    gui.pendingAction = action
    gui.status = 'Queued: ' .. action
end

-- hover help for the window's buttons and settings
local function tip(text)
    if imgui.IsItemHovered() then imgui.SetTooltip(text) end
end

local STATE_TEXT = { available = '[AVAILABLE]', locked = '[LOCKED]', maxed = '[MAXED]' }

local function drawPurchaseList()
    -- tab filter
    if imgui.RadioButton('All', gui.filter == 'all') then gui.filter = 'all' end
    tip('Show every AA in the list.')
    for _, tab in ipairs(TABS) do
        imgui.SameLine()
        if imgui.RadioButton(tab.label, gui.filter == tab.key) then gui.filter = tab.key end
        tip('Show only the ' .. tab.label .. ' tab.')
    end
    imgui.SameLine()
    local newHide, hideChanged = imgui.Checkbox('Hide Maxed', gui.hideMaxed)
    if hideChanged then gui.hideMaxed = newHide end
    tip('Hide AAs you already have at max rank.')

    if #priority.entries == 0 then
        imgui.TextWrapped('The list fills itself from the AA window - click Check Availability.')
    elseif imgui.BeginChild('PlayerAAPriorityList', 0, 300, true) then
        local shown = 0
        for index, entry in ipairs(priority.entries) do
            if isVisible(entry) then
                shown = shown + 1
                local state = gui.state[entry.name]
                local info = gui.info[entry.name]
                local tab = TAB_BY_KEY[entry.tab or '']
                local label = string.format('%d. %s %s %s%s%s###paa_%d',
                    index,
                    entry.enabled and '[ON] ' or '[OFF]',
                    STATE_TEXT[state] or '[?]',
                    entry.name,
                    info and string.format('  (%d/%d, cost %d)', info.cur, info.max, info.cost) or '',
                    (gui.filter == 'all' and tab) and ('  - ' .. tab.label) or '',
                    index)

                -- green = ON and available now; grey = OFF; blue = maxed
                local pushed = true
                if not entry.enabled then
                    imgui.PushStyleColor(ImGuiCol.Text, 0.55, 0.55, 0.55, 1.0)
                elseif state == 'maxed' then
                    imgui.PushStyleColor(ImGuiCol.Text, 0.45, 0.65, 1.0, 1.0)
                elseif state == 'available' then
                    imgui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
                else
                    pushed = false
                end
                if imgui.Selectable(label, gui.selectedPriorityIndex == index) then
                    gui.selectedPriorityIndex = index
                end
                if pushed then imgui.PopStyleColor() end
            end
        end
        if shown == 0 then imgui.TextDisabled('Nothing to show with this filter.') end
    end
    if #priority.entries > 0 then imgui.EndChild() end
    imgui.TextDisabled('[?] = not checked yet - Check Availability or a purchase updates it.')

    if imgui.Button('Move Up') then movePriority(gui.selectedPriorityIndex, -1) end
    tip('Move the selected AA up (bought sooner in Priority Order).')
    imgui.SameLine()
    if imgui.Button('Move Down') then movePriority(gui.selectedPriorityIndex, 1) end
    tip('Move the selected AA down (bought later in Priority Order).')
    imgui.SameLine()
    if imgui.Button('Enable / Disable') then togglePriority(gui.selectedPriorityIndex) end
    tip('Switch the selected AA ON or OFF. OFF AAs are never bought, but stay in the list.')

    if imgui.Button('Shown ON') then setShown(true) end
    tip('Switch ON every AA shown with the current filter\n(for example, all of the Class tab).')
    imgui.SameLine()
    if imgui.Button('Shown OFF') then setShown(false) end
    tip('Switch OFF every AA shown with the current filter\n(for example, all of the General tab).')
    imgui.SameLine()
    if imgui.Button('Save') then savePriorities() end
    tip('Save your list and settings now (changes also save automatically).\nCommand: /playeraa save')
    imgui.SameLine()
    if imgui.Button('Reload') then loadPriorities() end
    tip('Reload your list and settings from disk, undoing unsaved changes.\nCommand: /playeraa load')
end

local function drawGUIContents()
    -- Header: logo, name and version
    if logoTexture then
        imgui.Image(logoTexture:GetTextureID(), ImVec2(60, 60))
        imgui.SameLine()
    end
    imgui.BeginGroup()
    imgui.TextColored(1.0, 0.56, 0.0, 1.0, 'PlayerAA.lua')
    imgui.SameLine()
    imgui.Text('by')
    imgui.SameLine()
    imgui.TextColored(0.0, 1.0, 0.0, 1.0, 'Cannonballdex™')
    imgui.TextColored(0.0, 1.0, 1.0, 1.0, VERSION)
    imgui.TextDisabled('Buys regular AA when set AA threshold is met.')
    imgui.EndGroup()
    imgui.Separator()

    imgui.Text(string.format('AA Points: %d    Spent: %d', gui.points, gui.spent))
    local sub = gui.sub
    if sub == 'GOLD' then
        imgui.TextColored(1.0, 0.84, 0.0, 1.0, 'Membership: GOLD (All Access)')
        tip('All Access: no membership limits on buying AAs.')
    else
        imgui.TextColored(1.0, 0.6, 0.2, 1.0, string.format('Membership: %s - AA limits apply', sub))
        tip('This character is not All Access (Gold). EQ limits AAs for Free and Silver accounts.\n'
            .. 'PlayerAA starts paused on this character. AAs EQ will not let you train stay LOCKED\n'
            .. 'and are skipped - nothing is bought unless the Train button is enabled.\n'
            .. 'Click Resume if you still want it to buy automatically.')
    end

    imgui.Separator()
    -- Settings drop-down (closed by default); the header shows the threshold
    local settingsOpen = imgui.CollapsingHeader(
        string.format('Settings  (Threshold %d%s)###paaSettings', AA_THRESHOLD, TEST_MODE and ', Test Mode' or ''))
    tip('Click to show or hide the AA Threshold, Test Mode and Button Debug settings.')
    -- opening/closing a drop-down refits the window to its contents
    if gui.lastSettingsOpen ~= settingsOpen then
        if gui.lastSettingsOpen ~= nil then gui.fittedOnce = false end
        gui.lastSettingsOpen = settingsOpen
    end
    if settingsOpen then
        -- small typed box (room for 5 digits, no +/- buttons)
        imgui.SetNextItemWidth(imgui.CalcTextSize('00000') + imgui.GetStyle().FramePadding.x * 2)
        local newThreshold, thresholdChanged = imgui.InputInt('AA Threshold', AA_THRESHOLD, 0, 0)
        tip('Start buying automatically once your AA points reach this number,\n'
            .. 'then spend down on the AAs switched ON.\nType a number and press Enter or click away. Saved automatically.')
        if thresholdChanged then
            AA_THRESHOLD = math.max(1, math.floor(toNumber(newThreshold, AA_THRESHOLD)))
            thresholdHandled = false
            lastFailedScanTime = 0
            gui.status = string.format('AA threshold changed to %d.', AA_THRESHOLD)
            markConfigurationDirty()
        end

        local newTestMode, testModeChanged = imgui.Checkbox('Test Mode', TEST_MODE)
        tip('Go through the motions without actually buying anything.\n'
            .. 'The console lists what would be bought. Always starts OFF.')
        if testModeChanged then
            TEST_MODE = newTestMode
            thresholdHandled = false
            lastFailedScanTime = 0
            gui.status = string.format('Test Mode %s.', TEST_MODE and 'enabled' or 'disabled')
        end

        local newDebugMode, debugChanged = imgui.Checkbox('Button Debug', BUTTON_DEBUG)
        tip('Print extra details about every Train button lookup to the MacroQuest console.\n'
            .. 'Only needed when buying is not working. Always starts OFF.')
        if debugChanged then
            BUTTON_DEBUG = newDebugMode
            gui.status = string.format('Button Debug %s.', BUTTON_DEBUG and 'enabled' or 'disabled')
        end
    end -- settingsOpen

    imgui.Text(string.format('Paused: %s    Purchase Mode: %s', tostring(paused), modeDisplayName()))

    imgui.Separator()
    imgui.TextWrapped(gui.status)
    imgui.Separator()

    if imgui.Button('Status') then queueGUIAction('status') end
    tip('Print the current points, threshold, mode and settings to the MacroQuest console.\nCommand: /playeraa status')
    imgui.SameLine()
    if imgui.Button('Check Availability') then queueGUIAction('scan') end
    tip('Check which AAs can be bought right now and update the AVAILABLE / LOCKED / MAXED labels.\n'
        .. 'Also adds any new AAs to the list. Buys nothing.\nCommand: /playeraa scan')
    imgui.SameLine()
    if imgui.Button('Buy') then queueGUIAction('buy') end
    tip('Start a purchase cycle now, without waiting for the threshold.\nCommand: /playeraa buy')

    if imgui.Button(paused and 'Resume' or 'Pause') then queueGUIAction(paused and 'resume' or 'pause') end
    tip('Pause or resume the automatic threshold checks.\nCommands: /playeraa pause   /playeraa resume')
    imgui.SameLine()
    if imgui.Button('Reset') then queueGUIAction('reset') end
    tip('Re-arm the automatic trigger so it buys again the next time your points reach the threshold.\nCommand: /playeraa reset')
    imgui.SameLine()

    imgui.Separator()
    imgui.Text('Purchase Mode')
    if imgui.Button('Priority Order') then
        priority.mode = 'priority'
        gui.status = 'Mode changed to Priority Order.'
        markConfigurationDirty()
    end
    tip('Buy the AAs switched ON in your list, top to bottom.\nUse Move Up / Move Down to set the order.')
    imgui.SameLine()
    if imgui.Button('EQ List Order') then
        priority.mode = 'eq_order'
        gui.status = 'Mode changed to EQ List Order.'
        markConfigurationDirty()
    end
    tip('Buy the AAs switched ON in the order EQ lists them:\nGeneral, Archetype, Class, Special, then Focus.')

    imgui.Separator()
    -- Purchase List drop-down (closed by default); the header shows the counts
    local onCount = 0
    for _, e in ipairs(priority.entries) do if e.enabled then onCount = onCount + 1 end end
    local listOpen = imgui.CollapsingHeader(string.format(
        'Purchase List  (%d AAs, %d ON)###paaList', #priority.entries, onCount))
    tip('Every regular AA is in this list. New ones are added at the end, switched ON.\n'
        .. 'Only AAs switched ON are bought; LOCKED ones are skipped until they unlock.')
    if gui.lastListOpen ~= listOpen then
        if gui.lastListOpen ~= nil then gui.fittedOnce = false end
        gui.lastListOpen = listOpen
    end
    if listOpen then
        drawPurchaseList()
    end
end

local function drawGUI()
    if not gui.open then return end

    if gui.applyInitialLayout then
        pcall(function()
            local viewport = imgui.GetMainViewport()
            if gui.windowX ~= nil and gui.windowY ~= nil then
                imgui.SetNextWindowPos(gui.windowX, gui.windowY, ImGuiCond.Always)
            elseif viewport and viewport.WorkPos then
                imgui.SetNextWindowPos(viewport.WorkPos.x + 500, viewport.WorkPos.y + 40, ImGuiCond.Always)
            end
        end)
        gui.applyInitialLayout = false
    end

    local okBegin, open, draw = pcall(function()
        -- fits its contents on open and whenever a drop-down opens/closes; resizable in between
        if not gui.fittedOnce then
            gui.fittedOnce = true
            pcall(function() imgui.SetNextWindowSize(ImVec2(0, 0), ImGuiCond.Always) end)
        end
        return imgui.Begin(WINDOW_TITLE, gui.open)
    end)
    if not okBegin then
        fail('GUI Begin error: ' .. tostring(open))
        return
    end

    gui.open = open
    if draw then
        local okDraw, drawError = pcall(drawGUIContents)
        if not okDraw then fail('GUI draw error: ' .. tostring(drawError)) end
    end

    pcall(function()
        local first, second = imgui.GetWindowPos()
        local x, y
        if type(first) == 'number' and type(second) == 'number' then
            x, y = first, second
        elseif first ~= nil then
            x, y = first.x, first.y
        end
        if x ~= nil and y ~= nil then
            if gui.windowX == nil or gui.windowY == nil
                or math.abs(gui.windowX - x) > 0.5 or math.abs(gui.windowY - y) > 0.5 then
                gui.windowX, gui.windowY = x, y
                markConfigurationDirty()
            end
        end
    end)

    imgui.End()
end

local function processGUIAction()
    local action = gui.pendingAction
    if action == nil then return end
    gui.pendingAction = nil

    if action == 'status' then
        showStatus()
        gui.status = 'Status printed to the MacroQuest console.'
    elseif action == 'scan' then
        local wasOpen = isAAWindowOpen()
        local ok, err = pcall(scanAllAAs)
        if CLOSE_AA_WINDOW_WHEN_FINISHED and not wasOpen then closeAAWindow() end
        if not ok then
            fail('Check error: ' .. tostring(err))
            gui.status = 'The check failed - see the MacroQuest console.'
        end
    elseif action == 'buy' then
        if inCombat() then
            gui.status = "Can't buy while in combat - try again after the fight."
            warn(gui.status)
        else
            gui.status = 'Running purchase cycle...'
            local success, errored = runPurchaseCycle()
            if errored then
                gui.status = 'Purchase cycle failed - see the MacroQuest console.'
            else
                gui.status = success and 'Purchase cycle completed.' or 'No verified purchase was completed.'
            end
        end
    elseif action == 'pause' then
        paused = true
        markConfigurationDirty()
        gui.status = 'Automatic checking paused.'
        log(gui.status)
    elseif action == 'resume' then
        paused = false
        markConfigurationDirty()
        thresholdHandled = false
        lastFailedScanTime = 0
        gui.status = 'Automatic checking resumed.'
        log(gui.status)
    elseif action == 'reset' then
        thresholdHandled = false
        lastFailedScanTime = 0
        gui.status = 'Automatic trigger reset.'
        log(gui.status)
    end
end

local function showHelp()
    log('PlayerAA commands:')
    log('/playeraa help     - show this command list')
    log('/playeraa ui       - show or hide the GUI')
    log('/playeraa status   - show current state')
    log('/playeraa scan     - check which AAs are available (buys nothing)')
    log('/playeraa buy      - start a purchase cycle now')
    log('/playeraa pause    - pause automatic checks')
    log('/playeraa resume   - resume automatic checks')
    log('/playeraa priority - print the purchase list')
    log('/playeraa save     - save configuration to disk')
    log('/playeraa load     - reload configuration from disk')
    log('/playeraa reset    - reset the threshold trigger')
end

local function handlePlayerAACommand(command)
    command = trim(command):lower()

    if command == '' or command == 'status' then
        showStatus()
    elseif command == 'help' then
        showHelp()
    elseif command == 'ui' then
        gui.open = not gui.open
        if gui.open then
            gui.applyInitialLayout = true
            gui.fittedOnce = false
        end
        log(string.format('GUI %s.', gui.open and 'opened' or 'closed'))
    elseif command == 'scan' then
        queueGUIAction('scan')
    elseif command == 'buy' then
        log('Manual purchase cycle queued.')
        queueGUIAction('buy')
    elseif command == 'pause' then
        queueGUIAction('pause')
    elseif command == 'resume' then
        queueGUIAction('resume')
    elseif command == 'priority' then
        log(string.format('Mode: %s | Entries: %d.', modeDisplayName(), #priority.entries))
        for index, entry in ipairs(priority.entries) do
            local tab = TAB_BY_KEY[entry.tab or '']
            log(string.format('%d. [%s] %s%s', index, entry.enabled and 'ON' or 'OFF', entry.name,
                tab and (' (' .. tab.label .. ')') or ''))
        end
    elseif command == 'save' then
        savePriorities()
    elseif command == 'load' then
        loadPriorities()
    elseif command == 'reset' then
        queueGUIAction('reset')
    else
        warn(string.format('Unknown command: "%s"', command))
        showHelp()
    end
end

-- ============================================================
-- RGMercs module hooks
-- ============================================================

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)

    running = true

    loadConfiguration()
    log('Configuration file: ' .. CONFIG_FILE)
    if not isGold() then
        paused = true
        gui.status = string.format('Membership is %s, not Gold: EQ limits AAs on this account. '
            .. 'Started paused - click Resume if you still want automatic buying.', getSubscription())
        warn(gui.status)
    end
    log(string.format('Started. Threshold: %d. Available AA points: %d.', AA_THRESHOLD, getAvailableAAPoints()))

    mq.imgui.init('PlayerAABuyerGUI', drawGUI)
    mq.bind('/playeraa', handlePlayerAACommand)
end

function Module:GiveTime()
    if not running then return end

    local actionOk, actionError = pcall(processGUIAction)
    if not actionOk then
        fail('Action error: ' .. tostring(actionError))
        gui.status = 'That action failed - see the MacroQuest console.'
    end
    getAvailableAAPoints()
    getSpentAAPoints()
    getSubscription()

    local now = mq.gettime()
    if now - lastAutomaticCheckTime >= CHECK_INTERVAL_MS then
        lastAutomaticCheckTime = now

        if not paused and isInGame() and not isZoning() and not inCombat() then
            local availablePoints = getAvailableAAPoints()

            -- Re-arm after available points fall below the threshold.
            if availablePoints < AA_THRESHOLD then thresholdHandled = false end

            local cooldownFinished = mq.gettime() - lastFailedScanTime >= FAILED_SCAN_COOLDOWN_MS
            if availablePoints >= AA_THRESHOLD and not thresholdHandled and cooldownFinished then
                thresholdHandled = true
                log(string.format('AA threshold reached: %d/%d.', availablePoints, AA_THRESHOLD))

                local success = runPurchaseCycle()
                if TEST_MODE then
                    log('Test-mode cycle completed.')
                elseif not success or getAvailableAAPoints() >= availablePoints then
                    lastFailedScanTime = mq.gettime()
                    warn('No points were spent. It will try again after your points drop below the threshold and reach it again, or press Reset.')
                end
            end
        end
    end

    if settingsDirty and mq.gettime() - lastSettingsSaveTime >= SETTINGS_SAVE_DELAY_MS then
        saveConfiguration(true)
    end
end

function Module:ShouldRender()
    return Config:GetSetting('PlayerAAShowTab') and true or false
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    imgui.Text(string.format('AA Points: %d    Spent: %d', gui.points, gui.spent))
    imgui.Text(string.format('Threshold: %d    Paused: %s    Mode: %s', AA_THRESHOLD, tostring(paused), modeDisplayName()))
    imgui.Text(string.format('Purchase list entries: %d', #priority.entries))

    imgui.Spacing()
    if imgui.SmallButton(gui.open and 'Close PlayerAA GUI' or 'Open PlayerAA GUI') then
        gui.open = not gui.open
        if gui.open then
            gui.applyInitialLayout = true
            gui.fittedOnce = false
        end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('If you close the PlayerAA window (X), re-open it by clicking this button\nor by typing /playeraa ui in the MQ chat window. Use /playeraa help for all commands.')
    end
    imgui.SameLine()
    if imgui.SmallButton(paused and 'Resume' or 'Pause') then
        queueGUIAction(paused and 'resume' or 'pause')
    end

    imgui.TextWrapped('Full controls (purchase list, scan, threshold, etc.) are on the floating PlayerAA GUI - /playeraa ui.')
end

function Module:Shutdown()
    running = false

    if settingsDirty then
        saveConfiguration(true)
    end

    if mq.imgui and mq.imgui.destroy then
        pcall(function()
            mq.imgui.destroy('PlayerAABuyerGUI')
        end)
    end

    mq.unbind('/playeraa')
    log('Stopped.')
end

return Module
