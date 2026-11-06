-- RGMercs User Module: Mercenary AA Buyer
-- Author: Cannonballdex
--
-- Install:
--   1. Copy this file to: <MQ config dir>/rgmercs/modules/mercaa.lua
--   2. RGMercs UserModules tab -> Refresh -> Enable "MercAA"
--
-- Watches your Mercenary AA points and automatically trains Mercenary AAs
-- once you cross a configurable threshold, using a priority list you build
-- from the in-game Mercenary AA window (so it buys the Merc AA you actually
-- want instead of whatever MQ2AASpend happens to pick). Keeps its own
-- floating GUI (/mercaa ui) and its own per-character settings file on disk,
-- same as it did as a standalone script - this port just moves it to run
-- inside RGMercs instead of as its own /lua script.
--
-- ============================================================
-- Mercenary AA Buyer with GUI
-- Version: 1.0.0-priority
--
-- Commands:
--   /mercaa ui
--   /mercaa status
--   /mercaa scan
--   /mercaa buy
--   /mercaa pause
--   /mercaa resume
--   /mercaa priority
--   /mercaa save
--   /mercaa load
--   /mercaa reset
-- ============================================================

local mq = require('mq')
local PackageMan = require('mq/PackageMan')
local lfs = PackageMan.Require(
    'luafilesystem',
    'lfs',
    '[MercAA] LuaFileSystem is required to create the config directory.'
)
local imgui = require('ImGui')
local ImGui = imgui
local Base = require("modules.base")
local Combat = require("utils.combat")
local Config = require('utils.config')

local VERSION = 'v1.0'
-- the ### part keeps the window's saved size and position when the version changes
local WINDOW_TITLE = ('MercAA.lua by Cannonballdex™ %s###MercAABuyerGUI'):format(VERSION)

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
    _name    = "MercAA",
    _author  = "Cannonballdex",
    _about   = "Automatically trains Mercenary AAs from a priority list once your Merc AA points cross a threshold.",
}
Module.__index = Module
setmetatable(Module, { __index = Base, })

-- Base:HandleBind indexes this unconditionally, so it must exist even empty.
Module.CommandHandlers = {}

Module.FAQ = {
    {
        Question = "Why not just use MQ2AASpend?",
        Answer   = "MQ2AASpend doesn't know which specific ranked ability you want when several share a category - it tried " ..
            "to buy Defy the Aureate when only Aureate's Bane was actually available, for example. This module lets you " ..
            "build an explicit priority list from the Mercenary AA window instead, so it trains exactly what you chose.",
        Settings_Used = "",
    },
}

Module.DefaultConfig = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ['MercAAShowTab'] = {
        DisplayName = "Show MercAA Tab",
        Category = Module._name,
        Index = 1,
        Tooltip = "Add a MercAA tab to the main window. Turn off if you don't need the status display and just want it running quietly.",
        Default = true,
    },
}

-- ============================================================
-- Configuration
-- ============================================================

-- Begin purchasing when this many Mercenary AA points are available.
local AA_THRESHOLD = 22

-- Keep true until /mercaa scan correctly detects enabled buttons.
local TEST_MODE = false

-- Print extra information about every Train button lookup.
local BUTTON_DEBUG = false

-- How often to check the available Mercenary AA points.
local CHECK_INTERVAL_MS = 5000

-- Mercenary AA tab number.
local MERC_TAB_INDEX = 6

-- UI delays.
local WINDOW_OPEN_TIMEOUT_MS = 5000
local TAB_CHANGE_TIMEOUT_MS = 5000
local ROW_SELECT_DELAY_MS = 750
local PURCHASE_TIMEOUT_MS = 5000
local PURCHASE_DELAY_MS = 1000

-- Do not immediately repeat a failed automatic scan.
local FAILED_SCAN_COOLDOWN_MS = 60000

-- Close the AA window after a real purchase cycle.
local CLOSE_AA_WINDOW_WHEN_FINISHED = true

-- ============================================================
-- UI control names
-- ============================================================

local AA_WINDOW = 'AAWindow'
local TAB_BOX = 'AAW_Subwindows'
local MERC_PAGE = 'AAW_MercAAPAGE'
local MERC_LIST = 'AAW_MercAAList'
local TRAIN_BUTTON = 'AAW_TrainButton'

-- Column containing the Mercenary AA name.
local AA_NAME_COLUMN = 1

-- ============================================================
-- Runtime state
-- ============================================================

local running = true
local paused = false
local thresholdHandled = false
local lastFailedScanTime = 0

-- GUI state.
local gui = {
    open = true,
    applyInitialLayout = true,
    status = 'Ready. Availability is checked when your points reach the threshold, or click Check Availability.',
    availability = {},      -- [aa name] = true (AVAILABLE) / false (LOCKED), from the last check
    pendingAction = nil,
    scanResults = {},
    selectedScanName = nil,
    selectedPriorityIndex = 0,
    points = 0,             -- last Mercenary AA point count read by the main loop; the window only draws this
    windowX = nil,
    windowY = nil,
}

local settingsDirty = false
local lastSettingsSaveTime = 0
local SETTINGS_SAVE_DELAY_MS = 750

local priority = {
    -- Modes:
    -- priority_only  = buy only enabled entries in this list
    -- priority_first = try this list first, then fall back to list order
    -- list_order     = ignore priorities and use the original row order
    mode = 'list_order',
    entries = {},
}

-- Keep the main loop responsive for ImGui while preserving the configured
-- automatic-check interval.
local lastAutomaticCheckTime = 0

-- ============================================================
-- Logging
-- ============================================================

local function log(message)
    printf('\ag[MercAA]\ax %s', tostring(message))
end

local function warn(message)
    printf('\ay[MercAA]\ax %s', tostring(message))
end

local function fail(message)
    printf('\ar[MercAA]\ax %s', tostring(message))
end

local function debugLog(message)
    if BUTTON_DEBUG then
        printf('\at[MercAA Debug]\ax %s', tostring(message))
    end
end

-- ============================================================
-- General helpers
-- ============================================================

local function trim(value)
    if value == nil then
        return ''
    end

    return tostring(value):match('^%s*(.-)%s*$')
end

local function toNumber(value, defaultValue)
    local result = tonumber(value)

    if result == nil then
        return defaultValue or 0
    end

    return result
end

local function toBoolean(value)
    if value == true then
        return true
    end

    if value == false or value == nil then
        return false
    end

    if type(value) == 'number' then
        return value ~= 0
    end

    local text = tostring(value):upper()

    return text == 'TRUE'
        or text == '1'
        or text == 'YES'
        or text == 'ON'
        or text == 'ENABLED'
end

local function waitUntil(timeoutMs, condition)
    local startTime = mq.gettime()

    while running and mq.gettime() - startTime < timeoutMs do
        local success, result = pcall(condition)

        if success and result then
            return true
        end

        mq.delay(50)
    end

    return false
end

local function isInGame()
    local success, gameState = pcall(function()
        return mq.TLO.MacroQuest.GameState()
    end)

    return success and gameState == 'INGAME'
end

local function isZoning()
    local success, zoning = pcall(function()
        return mq.TLO.Me.Zoning()
    end)

    return success and toBoolean(zoning)
end

-- Scanning and buying open the AA window and click through it, and GiveTime runs on RGMercs'
-- main loop, so they wait for a quiet moment
local function inCombat()
    local success, state = pcall(function()
        return Combat.GetCachedCombatState()
    end)

    return success and state == "Combat"
end


-- ============================================================
-- Per-character configuration
-- ============================================================


local function sanitizeFileName(value)
    local text = trim(value)

    if text == '' then
        return 'Unknown'
    end

    return text
        :gsub('[<>:"/\\|%?%*]', '_')
        :gsub('%s+', '_')
end

local function getCharacterName()
    local success, name = pcall(function()
        return mq.TLO.Me.CleanName()
    end)

    if success and trim(name) ~= '' then
        return trim(name)
    end

    return 'UnknownCharacter'
end

local function getServerName()
    local lookups = {
        function()
            return mq.TLO.EverQuest.Server()
        end,
        function()
            return mq.TLO.MacroQuest.Server()
        end,
    }

    for _, lookup in ipairs(lookups) do
        local success, name = pcall(lookup)

        if success and trim(name) ~= '' then
            return trim(name)
        end
    end

    return 'UnknownServer'
end

local function normalizeWindowsPath(path)
    return tostring(path):gsub('/', '\\')
end

local function directoryExists(path)
    if not lfs or type(lfs.attributes) ~= 'function' then
        return false
    end

    return lfs.attributes(normalizeWindowsPath(path), 'mode') == 'directory'
end

local function ensureDirectoryExists(path)
    if not lfs or type(lfs.mkdir) ~= 'function' then
        fail('LuaFileSystem could not be loaded.')
        return false
    end

    local windowsPath = normalizeWindowsPath(path)

    if directoryExists(windowsPath) then
        return true
    end

    -- Preserve a Windows drive prefix such as C:\\ while creating each
    -- remaining directory one level at a time.
    local drive, remainder = windowsPath:match('^(%a:[\\]?)(.*)$')
    local currentPath = drive or ''

    if drive == nil then
        remainder = windowsPath
    end

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
                fail(string.format(
                    'Could not create directory "%s": %s',
                    currentPath,
                    tostring(mkdirError)
                ))
                return false
            end
        elseif mode ~= 'directory' then
            fail('Configuration path is not a directory: ' .. currentPath)
            return false
        end
    end

    return directoryExists(windowsPath)
end

-- Store one configuration file per server and character under:
-- MacroQuest\config\mercaa
local MQ_ROOT = normalizeWindowsPath(tostring(mq.TLO.MacroQuest.Path()))
local PRIORITY_DIRECTORY = MQ_ROOT .. "\\config\\mercaa"

ensureDirectoryExists(PRIORITY_DIRECTORY)

local CONFIG_FILE = string.format(
    '%s\\mercaa_priority_%s_%s.lua',
    PRIORITY_DIRECTORY,
    sanitizeFileName(getServerName()),
    sanitizeFileName(getCharacterName())
)

local markConfigurationDirty

local function escapeLuaString(value)
    return string.format('%q', tostring(value))
end

local function priorityContains(name)
    for index, entry in ipairs(priority.entries) do
        if entry.name == name then
            return index
        end
    end

    return nil
end

local function addPriority(name)
    name = trim(name)

    if name == '' then
        gui.status = 'Select an AA before adding it.'
        return false
    end

    if priorityContains(name) then
        gui.status = string.format(
            '"%s" is already in the priority list.',
            name
        )
        return false
    end

    priority.entries[#priority.entries + 1] = {
        name = name,
        enabled = true,
    }

    gui.selectedPriorityIndex = #priority.entries
    gui.status = string.format(
        'Added "%s" to priority position %d.',
        name,
        #priority.entries
    )

    markConfigurationDirty()
    return true
end

local function removePriority(index)
    local entry = priority.entries[index]

    if entry == nil then
        gui.status = 'Select a priority entry first.'
        return false
    end

    table.remove(priority.entries, index)

    if #priority.entries == 0 then
        gui.selectedPriorityIndex = 0
    elseif index > #priority.entries then
        gui.selectedPriorityIndex = #priority.entries
    else
        gui.selectedPriorityIndex = index
    end

    gui.status = string.format(
        'Removed "%s" from the priority list.',
        entry.name
    )

    markConfigurationDirty()
    return true
end

local function movePriority(index, direction)
    local destination = index + direction

    if index < 1
        or index > #priority.entries
        or destination < 1
        or destination > #priority.entries
    then
        return false
    end

    priority.entries[index], priority.entries[destination] =
        priority.entries[destination], priority.entries[index]

    gui.selectedPriorityIndex = destination
    gui.status = string.format(
        'Moved "%s" to priority position %d.',
        priority.entries[destination].name,
        destination
    )

    markConfigurationDirty()
    return true
end

local function togglePriority(index)
    local entry = priority.entries[index]

    if entry == nil then
        gui.status = 'Select a priority entry first.'
        return false
    end

    entry.enabled = not entry.enabled

    gui.status = string.format(
        '%s "%s".',
        entry.enabled and 'Enabled' or 'Disabled',
        entry.name
    )

    markConfigurationDirty()
    return true
end

local function saveConfiguration(silent)
    if not ensureDirectoryExists(PRIORITY_DIRECTORY) then
        fail('Could not create configuration directory: ' .. PRIORITY_DIRECTORY)
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
    file:write('    testMode = ', tostring(TEST_MODE), ',\n')
    file:write('    debugMode = ', tostring(BUTTON_DEBUG), ',\n')
    file:write('    paused = ', tostring(paused), ',\n')
    file:write('    windowX = ', tostring(gui.windowX or 'nil'), ',\n')
    file:write('    windowY = ', tostring(gui.windowY or 'nil'), ',\n')
    file:write('    mode = ', escapeLuaString(priority.mode), ',\n')
    file:write('    entries = {\n')

    for _, entry in ipairs(priority.entries) do
        file:write(
            '        { name = ',
            escapeLuaString(entry.name),
            ', enabled = ',
            tostring(entry.enabled ~= false),
            ' },\n'
        )
    end

    file:write('    },\n')
    file:write('}\n')
    file:close()

    settingsDirty = false
    lastSettingsSaveTime = mq.gettime()

    if not silent then
        gui.status = string.format(
            'Saved settings and %d priorities.',
            #priority.entries
        )
        log(gui.status)
    end

    return true
end

markConfigurationDirty = function()
    settingsDirty = true
end

local function loadConfiguration()
    local chunk, loadError = loadfile(CONFIG_FILE)

    if chunk == nil then
        gui.status = 'No saved configuration for this character yet.'
        return false
    end

    local success, loaded = pcall(chunk)

    if not success or type(loaded) ~= 'table' then
        fail('Could not load configuration file: ' .. tostring(loadError or loaded))
        gui.status = 'Configuration file could not be loaded.'
        return false
    end

    AA_THRESHOLD = math.max(1, math.floor(toNumber(loaded.threshold, AA_THRESHOLD)))
    -- Test Mode and Button Debug always start OFF; they are not restored from the saved file
    if loaded.paused ~= nil then paused = toBoolean(loaded.paused) end

    if tonumber(loaded.windowX) ~= nil and tonumber(loaded.windowY) ~= nil then
        gui.windowX = tonumber(loaded.windowX)
        gui.windowY = tonumber(loaded.windowY)
    end

    local validModes = {
        priority_only = true,
        priority_first = true,
        list_order = true,
    }

    if validModes[loaded.mode] then
        priority.mode = loaded.mode
    end

    priority.entries = {}

    if type(loaded.entries) == 'table' then
        for _, entry in ipairs(loaded.entries) do
            if type(entry) == 'table' and trim(entry.name) ~= '' then
                priority.entries[#priority.entries + 1] = {
                    name = trim(entry.name),
                    enabled = entry.enabled ~= false,
                }
            end
        end
    end

    gui.selectedPriorityIndex = 0
    gui.status = string.format(
        'Loaded settings and %d saved priorities.',
        #priority.entries
    )
    log(gui.status)

    return true
end

-- Keep the existing button/command names working.
local function savePriorities()
    return saveConfiguration(false)
end

local function loadPriorities()
    return loadConfiguration()
end

-- ============================================================
-- Mercenary AA points
-- ============================================================

local function getAvailableMercAAPoints()
    local success, points = pcall(function()
        return mq.TLO.Me.MercAAPoints()
    end)

    if not success or points == nil then
        gui.points = 0
        return 0
    end

    gui.points = toNumber(points, 0)
    return gui.points
end

-- ============================================================
-- AA window and tab handling
-- ============================================================

local function isAAWindowOpen()
    local success, open = pcall(function()
        return mq.TLO.Window(AA_WINDOW).Open()
    end)

    return success and toBoolean(open)
end

local function openAAWindow()
    if isAAWindowOpen() then
        return true
    end

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
    if isAAWindowOpen() then
        mq.cmd('/windowstate AAWindow close')
    end
end

local function getTabContainer()
    return mq.TLO.Window('AAWindow/AAW_Subwindows')
end

local function getMercPage()
    return getTabContainer().Child(MERC_PAGE)
end

local function isMercPageOpen()
    local success, open = pcall(function()
        return getMercPage().Open()
    end)

    return success and toBoolean(open)
end

local function selectMercenaryTab()
    if not openAAWindow() then
        return false
    end

    if isMercPageOpen() then
        return true
    end

    mq.cmdf(
        '/notify %s %s tabselect %d',
        AA_WINDOW,
        TAB_BOX,
        MERC_TAB_INDEX
    )

    mq.doevents()

    local pageOpened = waitUntil(TAB_CHANGE_TIMEOUT_MS, function()
        return getMercPage().Open()
    end)

    if not pageOpened then
        fail(string.format(
            'Selected tab %d, but %s did not report as open.',
            MERC_TAB_INDEX,
            MERC_PAGE
        ))

        return false
    end

    mq.delay(500)
    return true
end

-- ============================================================
-- Mercenary AA list
-- ============================================================

local function getMercAAList()
    return getMercPage().Child(MERC_LIST)
end

local function getRowCount()
    local success, count = pcall(function()
        return getMercAAList().Items()
    end)

    if not success or count == nil then
        return 0
    end

    return toNumber(count, 0)
end

local function getRowName(row)
    local success, text = pcall(function()
        return getMercAAList().List(row, AA_NAME_COLUMN)()
    end)

    if not success or text == nil then
        return ''
    end

    return trim(text)
end

local function getSelectedRow()
    local success, selectedIndex = pcall(function()
        return getMercAAList().SelectedIndex()
    end)

    if not success or selectedIndex == nil then
        return 0
    end

    return toNumber(selectedIndex, 0)
end

local function selectRow(row)
    -- This method was already successfully selecting each row.
    mq.cmdf(
        '/notify %s %s listselect %d',
        AA_WINDOW,
        MERC_LIST,
        row
    )

    mq.doevents()

    -- Wait for the selected row and Train button state to update.
    mq.delay(ROW_SELECT_DELAY_MS)

    local selectedRow = getSelectedRow()

    if BUTTON_DEBUG then
        debugLog(string.format(
            'Requested row %d; SelectedIndex reports %d.',
            row,
            selectedRow
        ))
    end

    -- Some custom UIs may report zero even when selection worked.
    if selectedRow ~= 0 and selectedRow ~= row then
        warn(string.format(
            'Requested row %d, but SelectedIndex reports row %d.',
            row,
            selectedRow
        ))
    end
end

-- ============================================================
-- Train button lookup
-- ============================================================

local function describeButton(button, location)
    local name = nil
    local screenID = nil
    local enabled = nil

    pcall(function()
        name = button.Name()
    end)

    pcall(function()
        screenID = button.ScreenID()
    end)

    pcall(function()
        enabled = button.Enabled()
    end)

    debugLog(string.format(
        '%s: Name="%s", ScreenID="%s", Enabled raw="%s"',
        location,
        tostring(name),
        tostring(screenID),
        tostring(enabled)
    ))

    return name, screenID, enabled
end

local function buttonIsValid(button)
    if button == nil then
        return false
    end

    local success, screenID = pcall(function()
        return button.ScreenID()
    end)

    if success
        and screenID ~= nil
        and tostring(screenID) ~= ''
        and tostring(screenID) ~= 'NULL'
    then
        return true
    end

    local nameSuccess, name = pcall(function()
        return button.Name()
    end)

    return nameSuccess
        and name ~= nil
        and tostring(name) ~= ''
        and tostring(name) ~= 'NULL'
end

local function getTrainButton()
    -- Different UI layouts may expose the button at different levels.
    local candidates = {
        {
            location = 'Mercenary page child',
            get = function()
                return getMercPage().Child(TRAIN_BUTTON)
            end,
        },
        {
            location = 'AAWindow child',
            get = function()
                return mq.TLO.Window(AA_WINDOW).Child(TRAIN_BUTTON)
            end,
        },
        {
            location = 'AAWindow slash path',
            get = function()
                return mq.TLO.Window('AAWindow/AAW_TrainButton')
            end,
        },
        {
            location = 'Global button lookup',
            get = function()
                return mq.TLO.Window(TRAIN_BUTTON)
            end,
        },
    }

    for _, candidate in ipairs(candidates) do
        local success, button = pcall(candidate.get)

        if success and buttonIsValid(button) then
            if BUTTON_DEBUG then
                describeButton(button, candidate.location)
            end

            return button, candidate.location
        end
    end

    return nil, nil
end

local function isTrainButtonEnabled(verbose)
    local button, location = getTrainButton()

    if button == nil then
        if verbose then
            warn('AAW_TrainButton could not be located.')
        end

        return false
    end

    local success, rawEnabled = pcall(function()
        return button.Enabled()
    end)

    if not success then
        if verbose then
            warn(string.format(
                'Could not read Enabled() from %s.',
                tostring(location)
            ))
        end

        return false
    end

    local enabled = toBoolean(rawEnabled)

    if verbose or BUTTON_DEBUG then
        debugLog(string.format(
            'Using %s: Enabled raw="%s", converted=%s.',
            tostring(location),
            tostring(rawEnabled),
            tostring(enabled)
        ))
    end

    return enabled
end

local function clickTrainButton()
    -- Verify immediately before clicking.
    if not isTrainButtonEnabled(true) then
        warn('Train button is not enabled.')
        return false
    end

    -- /notify works with the top-level window and control ScreenID.
    mq.cmd('/notify AAWindow AAW_TrainButton leftmouseup')
    mq.doevents()
    mq.delay(250)

    return true
end

-- ============================================================
-- Confirmation dialog
-- ============================================================

local function isConfirmationOpen()
    local success, open = pcall(function()
        return mq.TLO.Window('ConfirmationDialogBox').Open()
    end)

    return success and toBoolean(open)
end

local function acceptConfirmation()
    mq.delay(250)

    if not isConfirmationOpen() then
        return
    end

    mq.cmd('/yes')
    mq.doevents()

    waitUntil(3000, function()
        return not isConfirmationOpen()
    end)
end

-- ============================================================
-- Scan Mercenary AA rows
-- ============================================================

local function findFirstPurchasableRow(verbose)
    if not selectMercenaryTab() then
        return nil
    end

    local rowCount = getRowCount()

    if rowCount <= 0 then
        fail('AAW_MercAAList contains no rows or could not be read.')
        return nil
    end

    if verbose then
        log(string.format(
            'Scanning %d Mercenary AA rows.',
            rowCount
        ))
    end

    for row = 1, rowCount do
        if not running or paused or isZoning() then
            return nil
        end

        local aaName = getRowName(row)

        if aaName == '' then
            aaName = string.format('Unknown AA at row %d', row)
        end

        selectRow(row)

        local enabled = isTrainButtonEnabled(verbose)
        gui.availability[aaName] = enabled

        if verbose then
            log(string.format(
                'Row %d: %s | Train enabled: %s',
                row,
                aaName,
                tostring(enabled)
            ))
        end

        if enabled then
            return {
                row = row,
                name = aaName,
            }
        end
    end

    return nil
end

local function findRowByName(name)
    local rowCount = getRowCount()

    for row = 1, rowCount do
        if getRowName(row) == name then
            return row
        end
    end

    return nil
end

-- Every Merc AA belongs in the purchase list. Reads just the names (no
-- clicking) and adds any missing ones at the end, switched ON. Your existing
-- order and ON/OFF settings are kept. The Mercenary tab must be open.
local function syncPriorityWithWindow()
    local added = 0
    local newState = #priority.entries == 0
    for row = 1, getRowCount() do
        local name = getRowName(row)
        if name ~= '' and not priorityContains(name) then
            priority.entries[#priority.entries + 1] = { name = name, enabled = newState }
            added = added + 1
        end
    end
    if added > 0 then
        log(string.format('Added %d Mercenary AA(s) to the end of the purchase list (%s).', added, newState and 'ON' or 'OFF'))
        markConfigurationDirty()
    end
    return added
end

local function findPriorityPurchasableRow(verbose)
    if not selectMercenaryTab() then
        return nil
    end

    if #priority.entries == 0 then
        if priority.mode == 'priority_only' then
            warn('Priority Only mode is active, but the priority list is empty.')
            return nil
        end

        return findFirstPurchasableRow(verbose)
    end

    for position, entry in ipairs(priority.entries) do
        if not running or paused or isZoning() then
            return nil
        end

        if entry.enabled then
            local row = findRowByName(entry.name)

            if row ~= nil then
                selectRow(row)

                local enabled = isTrainButtonEnabled(verbose)
                gui.availability[entry.name] = enabled

                if verbose then
                    log(string.format(
                        'Priority %d: %s | Row %d | Train enabled: %s',
                        position,
                        entry.name,
                        row,
                        tostring(enabled)
                    ))
                end

                if enabled then
                    return {
                        row = row,
                        name = entry.name,
                        priority = position,
                    }
                end
            elseif verbose then
                warn(string.format(
                    'Priority %d was not found in the current list: "%s".',
                    position,
                    entry.name
                ))
            end
        end
    end

    if priority.mode == 'priority_first' then
        return findFirstPurchasableRow(verbose)
    end

    return nil
end

local function findPurchasableRow(verbose)
    if priority.mode == 'list_order' then
        return findFirstPurchasableRow(verbose)
    end

    return findPriorityPurchasableRow(verbose)
end


-- Scan all Mercenary AA rows for display in the GUI.
-- This function never clicks the Train button.
local function scanAllMercenaryAAs()
    local results = {}

    if not selectMercenaryTab() then
        gui.status = 'Could not open the Mercenary AA page.'
        gui.scanResults = results
        return false
    end

    local rowCount = getRowCount()

    if rowCount <= 0 then
        gui.status = 'No Mercenary AA rows were found.'
        gui.scanResults = results
        return false
    end

    syncPriorityWithWindow()

    gui.status = string.format(
        'Checking %d Mercenary AAs...',
        rowCount
    )

    for row = 1, rowCount do
        if not running or isZoning() or inCombat() then
            break
        end

        local aaName = getRowName(row)

        if aaName == '' then
            aaName = string.format(
                'Unknown AA at row %d',
                row
            )
        end

        selectRow(row)

        results[#results + 1] = {
            row = row,
            name = aaName,
            purchasable = isTrainButtonEnabled(false),
        }
        gui.availability[aaName] = results[#results].purchasable
    end

    gui.scanResults = results

    local availableCount = 0

    for _, aa in ipairs(results) do
        if aa.purchasable then
            availableCount = availableCount + 1
        end
    end

    gui.status = string.format(
        'Checked %d Merc AAs: %d available now, %d locked.',
        #results,
        availableCount,
        #results - availableCount
    )

    return true
end

-- ============================================================
-- Purchasing
-- ============================================================

local function purchaseFirstAvailableAA()
    local aa = findPurchasableRow(false)

    if aa == nil then
        warn('No permitted AA had an enabled Train button.')
        return false
    end

    local pointsBefore = getAvailableMercAAPoints()

    if TEST_MODE then
        log(string.format(
            'TEST MODE: row %d is purchasable: "%s". Points: %d.',
            aa.row,
            aa.name,
            pointsBefore
        ))

        return true
    end

    -- The correct row should still be selected.
    -- Check the button one more time before clicking.
    if not isTrainButtonEnabled(true) then
        warn(string.format(
            'Train button became disabled for "%s".',
            aa.name
        ))

        return false
    end

    log(string.format(
        'Purchasing row %d: "%s".',
        aa.row,
        aa.name
    ))

    if not clickTrainButton() then
        return false
    end

    acceptConfirmation()

    local pointsChanged = waitUntil(PURCHASE_TIMEOUT_MS, function()
        return getAvailableMercAAPoints() < pointsBefore
    end)

    local pointsAfter = getAvailableMercAAPoints()

    if not pointsChanged then
        warn(string.format(
            'Purchase was not verified for "%s". '
                .. 'Points before: %d; points now: %d.',
            aa.name,
            pointsBefore,
            pointsAfter
        ))

        return false
    end

    log(string.format(
        'Purchased "%s". Points changed from %d to %d.',
        aa.name,
        pointsBefore,
        pointsAfter
    ))

    mq.delay(PURCHASE_DELAY_MS)
    return true
end

-- Buy one row: select it, check Train once, click, confirm, verify points dropped.
local function buyRow(row, name)
    selectRow(row)
    if not isTrainButtonEnabled(false) then
        gui.availability[name] = false
        return false
    end

    local pointsBefore = getAvailableMercAAPoints()
    log(string.format('Purchasing "%s".', name))
    if not clickTrainButton() then return false end
    acceptConfirmation()

    local pointsChanged = waitUntil(PURCHASE_TIMEOUT_MS, function()
        return getAvailableMercAAPoints() < pointsBefore
    end)
    local pointsAfter = getAvailableMercAAPoints()
    if not pointsChanged then
        warn(string.format('Purchase was not verified for "%s". Points before: %d; now: %d.',
            name, pointsBefore, pointsAfter))
        return false
    end
    log(string.format('Purchased "%s". Points %d -> %d.', name, pointsBefore, pointsAfter))
    mq.delay(PURCHASE_DELAY_MS)
    return true
end

-- The AAs to buy this cycle, in order, from the one availability check.
local function buildPurchaseOrder()
    local order, seen = {}, {}
    local function add(name)
        if name and not seen[name] and gui.availability[name] == true then
            seen[name] = true
            order[#order + 1] = name
        end
    end
    if priority.mode == 'list_order' then
        for _, aa in ipairs(gui.scanResults) do add(aa.name) end
    else
        -- Priority Only / Priority First: your list, top to bottom, ON entries only.
        -- (Every Merc AA is in the list, so there is nothing else to fall back to.)
        for _, entry in ipairs(priority.entries) do
            if entry.enabled then add(entry.name) end
        end
    end
    return order
end

local function runPurchaseCycleBody()
    if not selectMercenaryTab() then
        return false
    end
    syncPriorityWithWindow()

    local startingPoints = getAvailableMercAAPoints()
    log(string.format('Purchase cycle started with %d available points.', startingPoints))

    if startingPoints < AA_THRESHOLD then
        warn(string.format('Points are below the threshold: %d/%d.', startingPoints, AA_THRESHOLD))
        return false
    end

    -- Check every Merc AA once, then buy from that - no re-checking the whole list.
    scanAllMercenaryAAs()
    local order = buildPurchaseOrder()

    if #order == 0 then
        warn('No permitted Merc AA can be bought right now.')
        return false
    end

    if TEST_MODE then
        log(string.format('TEST MODE: would buy, in order: %s', table.concat(order, ', ')))
        return true
    end

    local purchaseCount = 0
    for _, name in ipairs(order) do
        if not running or paused or isZoning() or inCombat() then break end
        if getAvailableMercAAPoints() < AA_THRESHOLD then
            log(string.format('Available points are now below threshold: %d/%d.',
                getAvailableMercAAPoints(), AA_THRESHOLD))
            break
        end

        local row = findRowByName(name)
        if row then
            -- keep buying this AA while it has ranks left and points allow
            while running and not paused and not isZoning() and not inCombat()
                and getAvailableMercAAPoints() >= AA_THRESHOLD
                and buyRow(row, name)
            do
                purchaseCount = purchaseCount + 1
            end
        end
    end

    log(string.format('Purchase cycle finished. Purchases: %d. Points remaining: %d.',
        purchaseCount, getAvailableMercAAPoints()))

    return purchaseCount > 0
end

-- Every way out of a cycle (bought, nothing to buy, below threshold, test mode,
-- could not open the tab) closes the AA window the cycle opened
local function runPurchaseCycle()
    -- an error mid-cycle is reported and the script keeps running
    local ok, result = pcall(runPurchaseCycleBody)

    if not ok then
        fail('Purchase cycle error: ' .. tostring(result))
        result = false
    end

    if CLOSE_AA_WINDOW_WHEN_FINISHED then
        closeAAWindow()
    end

    -- second value: true when the cycle raised an error
    return result, not ok
end

-- ============================================================
-- Commands
-- ============================================================

local function showStatus()
    log(string.format(
        'Points: %d | Threshold: %d | Test mode: %s | Paused: %s',
        getAvailableMercAAPoints(),
        AA_THRESHOLD,
        tostring(TEST_MODE),
        tostring(paused)
    ))

    log(string.format(
        'AA window open: %s | Mercenary page open: %s',
        tostring(isAAWindowOpen()),
        tostring(isMercPageOpen())
    ))

    if isMercPageOpen() then
        log(string.format(
            'Rows: %d | Selected row: %d',
            getRowCount(),
            getSelectedRow()
        ))

        local button, location = getTrainButton()

        log(string.format(
            'Train button found: %s | Location: %s',
            tostring(button ~= nil),
            tostring(location)
        ))

        if button ~= nil then
            log(string.format(
                'Train button enabled: %s',
                tostring(isTrainButtonEnabled(true))
            ))
        end
    end
end


-- ============================================================
-- GUI
-- ============================================================

local function getImVec2(x, y)
    if imgui.ImVec2 then
        return imgui.ImVec2(x, y)
    end

    if ImVec2 then
        return ImVec2(x, y)
    end

    return nil
end

local function queueGUIAction(action)
    if gui.pendingAction ~= nil then
        gui.status = 'Another action is already queued.'
        return
    end

    gui.pendingAction = action
    gui.status = 'Queued: ' .. action
end


local function drawSelectable(label, selected)
    local success, clicked = pcall(function()
        return imgui.Selectable(label, selected)
    end)

    if success then
        return clicked
    end

    return imgui.Button(label)
end

local function modeDisplayName()
    if priority.mode == 'priority_only' then
        return 'Priority Only'
    end

    if priority.mode == 'priority_first' then
        return 'Priority First'
    end

    return 'List Order'
end

-- hover help for the window's buttons and settings
local function tip(text)
    if imgui.IsItemHovered() then imgui.SetTooltip(text) end
end

local function drawGUIContents()
    -- Header: logo, name and version
    if logoTexture then
        imgui.Image(logoTexture:GetTextureID(), ImVec2(60, 60))
        imgui.SameLine()
    end
    imgui.BeginGroup()
    imgui.TextColored(1.0, 0.56, 0.0, 1.0, 'MercAA.lua')
    imgui.SameLine()
    imgui.Text('by')
    imgui.SameLine()
    imgui.TextColored(0.0, 1.0, 0.0, 1.0, 'Cannonballdex™')
    imgui.TextColored(0.0, 1.0, 1.0, 1.0, VERSION)
    imgui.TextDisabled('Buys Merc AA when set AA threshold is met.')
    imgui.EndGroup()
    imgui.Separator()

    imgui.Text(string.format(
        'Mercenary AA Points: %d',
        gui.points
    ))

    imgui.Separator()
    -- Settings drop-down (closed by default); the header shows the threshold
    local settingsOpen = imgui.CollapsingHeader(
        string.format('Settings  (Threshold %d%s)###mercaaSettings', AA_THRESHOLD, TEST_MODE and ', Test Mode' or ''))
    tip('Click to show or hide the AA Threshold, Test Mode and Button Debug settings.')
    -- opening/closing a drop-down refits the window to its contents
    if gui.lastSettingsOpen ~= settingsOpen then
        if gui.lastSettingsOpen ~= nil then gui.fittedOnce = false end
        gui.lastSettingsOpen = settingsOpen
    end
    if settingsOpen then

    -- small typed box (room for 5 digits, no +/- buttons)
    imgui.SetNextItemWidth(imgui.CalcTextSize('00000') + imgui.GetStyle().FramePadding.x * 2)
    local newThreshold, thresholdChanged = imgui.InputInt(
        'AA Threshold',
        AA_THRESHOLD,
        0,
        0
    )
    tip('Buy Merc AAs automatically once your Mercenary AA points reach this number.\nType a number and press Enter or click away. Saved automatically.')

    if thresholdChanged then
        AA_THRESHOLD = math.max(1, math.floor(toNumber(newThreshold, AA_THRESHOLD)))
        thresholdHandled = false
        lastFailedScanTime = 0
        gui.status = string.format('AA threshold changed to %d.', AA_THRESHOLD)
        markConfigurationDirty()
    end

    local newTestMode, testModeChanged = imgui.Checkbox(
        'Test Mode',
        TEST_MODE
    )
    tip('Go through the motions without actually buying anything.\nUse it to check what would be bought before turning it off.')

    if testModeChanged then
        TEST_MODE = newTestMode
        thresholdHandled = false
        lastFailedScanTime = 0
        gui.status = string.format('Test Mode %s.', TEST_MODE and 'enabled' or 'disabled')
        markConfigurationDirty()
    end

    local newDebugMode, debugChanged = imgui.Checkbox(
        'Button Debug',
        BUTTON_DEBUG
    )
    tip('Print extra details about every Train button lookup to the MacroQuest console.\nOnly needed when buying is not working.')

    if debugChanged then
        BUTTON_DEBUG = newDebugMode
        gui.status = string.format('Button Debug %s.', BUTTON_DEBUG and 'enabled' or 'disabled')
        markConfigurationDirty()
    end
    end -- settingsOpen

    imgui.Text(string.format(
        'Paused: %s    Purchase Mode: %s',
        tostring(paused),
        modeDisplayName()
    ))

    imgui.Separator()
    imgui.TextWrapped(gui.status)
    imgui.Separator()

    if imgui.Button('Status') then
        queueGUIAction('status')
    end
    tip('Print the current points, threshold, mode and settings to the MacroQuest console.\nCommand: /mercaa status')

    imgui.SameLine()

    if imgui.Button('Check Availability') then
        queueGUIAction('scan')
    end
    tip('Check which Merc AAs can be bought right now and update the AVAILABLE / LOCKED labels.\nAlso adds any new Merc AAs to the list. Buys nothing.\nCommand: /mercaa scan')

    imgui.SameLine()

    if imgui.Button('Buy') then
        queueGUIAction('buy')
    end
    tip('Start a purchase cycle now, without waiting for the threshold.\nCommand: /mercaa buy')

    if imgui.Button(paused and 'Resume' or 'Pause') then
        queueGUIAction(paused and 'resume' or 'pause')
    end
    tip('Pause or resume the automatic threshold checks.\nCommands: /mercaa pause   /mercaa resume')

    imgui.SameLine()

    if imgui.Button('Reset') then
        queueGUIAction('reset')
    end
    tip('Re-arm the automatic trigger so it buys again the next time your points reach the threshold.\nCommand: /mercaa reset')

    imgui.Separator()
    imgui.Text('Purchase Mode')

    if imgui.Button('Priority Only') then
        priority.mode = 'priority_only'
        gui.status = 'Mode changed to Priority Only.'
        markConfigurationDirty()
    end
    tip('Only buy the AAs that are turned ON in your priority list, in that order.')

    imgui.SameLine()

    if imgui.Button('Priority First') then
        priority.mode = 'priority_first'
        gui.status = 'Mode changed to Priority First.'
        markConfigurationDirty()
    end
    tip('Buy from your list, top to bottom, ON entries only.\nNow that every Merc AA is in the list, this works the same as Priority Only.')

    imgui.SameLine()

    if imgui.Button('List Order') then
        priority.mode = 'list_order'
        gui.status = 'Mode changed to List Order.'
        markConfigurationDirty()
    end
    tip('Ignore the priority list and buy in the order EQ lists the Mercenary AAs.')

    imgui.Separator()
    -- Purchase List drop-down (closed by default); the header shows the counts
    local onCount = 0
    for _, e in ipairs(priority.entries) do if e.enabled then onCount = onCount + 1 end end
    local listOpen = imgui.CollapsingHeader(string.format(
        'Purchase List  (%d Merc AAs, %d ON)###mercaaList', #priority.entries, onCount))
    if gui.lastListOpen ~= listOpen then
        if gui.lastListOpen ~= nil then gui.fittedOnce = false end
        gui.lastListOpen = listOpen
    end
    if listOpen then
    tip('Every Mercenary AA is in this list. New ones are added at the end, switched ON.\n'
        .. 'Priority modes buy them top to bottom; LOCKED ones are skipped until they unlock.\n'
        .. 'Select an entry, then Move Up / Move Down or Enable / Disable it.')

    if #priority.entries == 0 then
        imgui.TextWrapped('The list fills itself from the AA window - click Check Availability.')
    else
        local beganPriorityChild = pcall(function()
            imgui.BeginChild('MercAAPriorityResults', 0, 240, true)
        end)

        if beganPriorityChild then
            for index, entry in ipairs(priority.entries) do
                local known = gui.availability[entry.name]
                local stateText = known == true and '[AVAILABLE]' or (known == false and '[LOCKED]' or '[?]')
                local label = string.format(
                    '%d. %s %s %s###priority_%d',
                    index,
                    entry.enabled and '[ON] ' or '[OFF]',
                    stateText,
                    entry.name,
                    index
                )

                -- green = ON and available now; grey = switched OFF
                local pushed = false
                if not entry.enabled then
                    imgui.PushStyleColor(ImGuiCol.Text, 0.55, 0.55, 0.55, 1.0)
                    pushed = true
                elseif known == true then
                    imgui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0)
                    pushed = true
                end
                if drawSelectable(label, gui.selectedPriorityIndex == index) then
                    gui.selectedPriorityIndex = index
                end
                if pushed then imgui.PopStyleColor() end
            end

            imgui.EndChild()
        end
    end
    imgui.TextDisabled('[?] = not checked yet - Check Availability or a purchase updates it.')

    if imgui.Button('Move Up') then
        movePriority(gui.selectedPriorityIndex, -1)
    end
    tip('Move the selected priority entry up (bought sooner).')

    imgui.SameLine()

    if imgui.Button('Move Down') then
        movePriority(gui.selectedPriorityIndex, 1)
    end
    tip('Move the selected priority entry down (bought later).')

    imgui.SameLine()

    if imgui.Button('Enable / Disable') then
        togglePriority(gui.selectedPriorityIndex)
    end
    tip('Switch the selected AA ON or OFF. OFF AAs are never bought, but stay in the list.')


    if imgui.Button('Save Priorities') then
        savePriorities()
    end
    tip('Save your priority list and settings to disk now (changes also save automatically).\nCommand: /mercaa save')

    imgui.SameLine()

    if imgui.Button('Reload Priorities') then
        loadPriorities()
    end
    tip('Reload your priority list and settings from disk, undoing unsaved changes.\nCommand: /mercaa load')
    end -- listOpen

end

local function drawGUI()
    if not gui.open then
        return
    end

    if gui.applyInitialLayout then
        local condAlways = 1

        if ImGuiCond then
            condAlways = ImGuiCond.Always
        end

        pcall(function()
            local viewport = imgui.GetMainViewport()

            if gui.windowX ~= nil and gui.windowY ~= nil then
                imgui.SetNextWindowPos(gui.windowX, gui.windowY, condAlways)
            elseif viewport and viewport.WorkPos then
                imgui.SetNextWindowPos(
                    viewport.WorkPos.x + 500,
                    viewport.WorkPos.y + 40,
                    condAlways
                )
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
        return imgui.Begin(
            WINDOW_TITLE,
            gui.open
        )
    end)

    if not okBegin then
        fail('GUI Begin error: ' .. tostring(open))
        return
    end

    gui.open = open

    if draw then
        local okDraw, drawError = pcall(drawGUIContents)

        if not okDraw then
            fail('GUI draw error: ' .. tostring(drawError))
        end
    end

    pcall(function()
        local first, second = imgui.GetWindowPos()
        local x = nil
        local y = nil

        if type(first) == 'number' and type(second) == 'number' then
            x = first
            y = second
        elseif first ~= nil then
            x = first.x
            y = first.y
        end

        if x ~= nil and y ~= nil then
            if gui.windowX == nil or gui.windowY == nil
                or math.abs(gui.windowX - x) > 0.5
                or math.abs(gui.windowY - y) > 0.5
            then
                gui.windowX = x
                gui.windowY = y
                markConfigurationDirty()
            end
        end
    end)

    imgui.End()
end

local function processGUIAction()
    local action = gui.pendingAction

    if action == nil then
        return
    end

    gui.pendingAction = nil

    if action == 'status' then
        showStatus()
        gui.status = 'Status printed to the MacroQuest console.'

    elseif action == 'scan' then
        if inCombat() then
            gui.status = "Can't check while in combat - try again after the fight."
            warn(gui.status)
        else
            scanAllMercenaryAAs()
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
                gui.status = success
                    and 'Purchase cycle completed.'
                    or 'No verified purchase was completed.'
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
    log('MercAA commands:')
    log('/mercaa help     - show this command list')
    log('/mercaa ui       - show or hide the GUI')
    log('/mercaa status   - show current state')
    log('/mercaa scan     - check which AAs are available (buys nothing)')
    log('/mercaa buy      - manually start a purchase cycle')
    log('/mercaa pause    - pause automatic checks')
    log('/mercaa resume   - resume automatic checks')
    log('/mercaa priority - show saved purchase priorities')
    log('/mercaa save     - save configuration to disk')
    log('/mercaa load     - reload configuration from disk')
    log('/mercaa reset    - reset the threshold trigger')
end

local function handleMercAACommand(command)
    command = trim(command):lower()

    if command == '' or command == 'status' then
        showStatus()

    elseif command == 'help' then
        showHelp()

    elseif command == 'ui' then
        gui.open = not gui.open

        if gui.open then
            gui.applyInitialLayout = true
        end

        log(string.format(
            'GUI %s.',
            gui.open and 'opened' or 'closed'
        ))

    elseif command == 'scan' then
        queueGUIAction('scan')

    elseif command == 'buy' then
        log('Manual purchase cycle queued.')
        queueGUIAction('buy')

    elseif command == 'pause' then
        paused = true
        markConfigurationDirty()
        log('Automatic checking paused.')

    elseif command == 'resume' then
        paused = false
        markConfigurationDirty()
        thresholdHandled = false
        lastFailedScanTime = 0
        log('Automatic checking resumed.')

    elseif command == 'priority' then
        log(string.format(
            'Priority mode: %s | Entries: %d.',
            priority.mode,
            #priority.entries
        ))

        for index, entry in ipairs(priority.entries) do
            log(string.format(
                '%d. [%s] %s',
                index,
                entry.enabled and 'ON' or 'OFF',
                entry.name
            ))
        end

    elseif command == 'save' then
        savePriorities()

    elseif command == 'load' then
        loadPriorities()

    elseif command == 'reset' then
        thresholdHandled = false
        lastFailedScanTime = 0
        log('Automatic trigger reset.')

    else
        warn(string.format(
            'Unknown command: "%s"',
            command
        ))
        showHelp()
    end
end

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Base.Init(self)

    running = true

    loadConfiguration()

    log('Configuration file: ' .. CONFIG_FILE)

    log(string.format(
        'Started. Threshold: %d. Test mode: %s.',
        AA_THRESHOLD,
        tostring(TEST_MODE)
    ))

    log(string.format(
        'Available Mercenary AA points: %d.',
        getAvailableMercAAPoints()
    ))

    mq.imgui.init('MercAABuyerGUI', drawGUI)
    log('GUI registered. Use /mercaa ui to show or hide it.')
    mq.bind('/mercaa', handleMercAACommand)
end

function Module:GiveTime()
    if not running then return end

    local actionOk, actionError = pcall(processGUIAction)
    if not actionOk then
        fail('Action error: ' .. tostring(actionError))
        gui.status = 'That action failed - see the MacroQuest console.'
    end
    getAvailableMercAAPoints()

    local now = mq.gettime()

    if now - lastAutomaticCheckTime >= CHECK_INTERVAL_MS then
        lastAutomaticCheckTime = now

        if not paused and isInGame() and not isZoning() and not inCombat() then
            local availablePoints = getAvailableMercAAPoints()

            -- Re-arm after available points fall below the threshold.
            if availablePoints < AA_THRESHOLD then
                thresholdHandled = false
            end

            local cooldownFinished =
                mq.gettime() - lastFailedScanTime
                    >= FAILED_SCAN_COOLDOWN_MS

            if availablePoints >= AA_THRESHOLD
                and not thresholdHandled
                and cooldownFinished
            then
                thresholdHandled = true

                log(string.format(
                    'Mercenary AA threshold reached: %d/%d.',
                    availablePoints,
                    AA_THRESHOLD
                ))

                local pointsBefore = availablePoints
                local success = runPurchaseCycle()
                local pointsAfter = getAvailableMercAAPoints()

                if TEST_MODE then
                    log('Test-mode threshold scan completed.')

                elseif not success or pointsAfter >= pointsBefore then
                    lastFailedScanTime = mq.gettime()

                    warn('No points were spent. It will try again after your points drop below the threshold and reach it again, or press Reset.')
                end
            end
        end
    end

    if settingsDirty
        and mq.gettime() - lastSettingsSaveTime >= SETTINGS_SAVE_DELAY_MS
    then
        saveConfiguration(true)
    end
end

function Module:ShouldRender()
    return Config:GetSetting('MercAAShowTab') and true or false
end

function Module:Render()
    Base.Render(self)

    if not self.ModuleLoaded then return end

    ImGui.Text(string.format('Mercenary AA Points: %d', gui.points))
    ImGui.Text(string.format('Threshold: %d    Paused: %s    Mode: %s', AA_THRESHOLD, tostring(paused), modeDisplayName()))
    ImGui.Text(string.format('Priority entries: %d', #priority.entries))

    ImGui.Spacing()
    if ImGui.SmallButton(gui.open and 'Close MercAA GUI' or 'Open MercAA GUI') then
        gui.open = not gui.open
        if gui.open then
            gui.applyInitialLayout = true
            gui.fittedOnce = false
        end
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('If you close the MercAA window (X), re-open it by clicking this button\nor by typing /mercaa ui in the MQ chat window. Use /mercaa help for all commands.')
    end
    ImGui.SameLine()
    if ImGui.SmallButton(paused and 'Resume' or 'Pause') then
        paused = not paused
        markConfigurationDirty()
        if not paused then
            thresholdHandled = false
            lastFailedScanTime = 0
        end
    end

    ImGui.TextWrapped('Full controls (priority list, scan, threshold, etc.) are on the floating MercAA GUI - /mercaa ui.')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('To re-open the MercAA GUI window if it was closed:\n  - click the "Open MercAA GUI" button above, or\n  - type /mercaa ui in the MQ chat window (toggles show/hide).')
    end
end

function Module:Shutdown()
    running = false

    if settingsDirty then
        saveConfiguration(true)
    end

    if mq.imgui and mq.imgui.destroy then
        pcall(function()
            mq.imgui.destroy('MercAABuyerGUI')
        end)
    end

    mq.unbind('/mercaa')
    log('Stopped.')
end

return Module