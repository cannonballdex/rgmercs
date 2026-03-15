local mq = require('mq')
local RGMercUtils = require("utils.rgmercs_utils")
local RGMercsLogger = require("utils.rgmercs_logger")

local ClassLoader = {
    _version = '0.1',
    _name = "ClassLoader",
    _author = 'Derple',
}

---@param class string # EQ Class ShortName
function ClassLoader.load(class)
    local className = assert(class, "ClassLoader.load: class is required"):lower()

    local baseClassConfig = require(string.format("class_configs.%s_class_config", className))
    local overrideClassConfig = {}
    local customConfigLoaded = false

    local customConfigFile = string.format("%s/rgmercs/class_configs/%s_class_config.lua", mq.configDir, className)

    if RGMercUtils.file_exists(customConfigFile) then
        RGMercsLogger.log_info("Loading Custom Core Class Config: %s", customConfigFile)

        local chunk, loadErr = loadfile(customConfigFile)
        if not chunk then
            RGMercsLogger.log_error("Failed to load custom core class config: %s (%s)", customConfigFile, tostring(loadErr))
        else
            local ok, result = pcall(chunk)
            if not ok then
                RGMercsLogger.log_error("Failed to execute custom core class config: %s (%s)", customConfigFile, tostring(result))
            elseif type(result) ~= "table" then
                RGMercsLogger.log_error("Custom core class config did not return a table: %s", customConfigFile)
            else
                overrideClassConfig = result
                customConfigLoaded = true
            end
        end
    end

    local classConfig

    if overrideClassConfig.FullConfig == true then
        RGMercsLogger.log_info("\agFull Replacement Config Loaded")
        classConfig = overrideClassConfig
    else
        classConfig = ClassLoader.mergeTables(baseClassConfig, overrideClassConfig)
    end

    classConfig.IsCustom = customConfigLoaded
    return classConfig
end

function ClassLoader.writeCustomConfig(class)
    local className = assert(class, "ClassLoader.writeCustomConfig: class is required"):lower()

    local baseConfigFile = string.format("%s/rgmercs/class_configs/%s_class_config.lua", mq.luaDir, className)
    local customConfigFile = string.format("%s/rgmercs/class_configs/%s_class_config.lua", mq.configDir, className)
    local backupConfigFile = string.format(
        "%s/rgmercs/class_configs/BACKUP/%s_class_config_%s.lua",
        mq.configDir,
        className,
        os.date("%Y%m%d_%H%M%S")
    )

    local fileCustom = io.open(customConfigFile, "r")
    if fileCustom then
        mq.pickle(backupConfigFile, {}) -- ensure backup path exists

        local content = fileCustom:read("*all")
        fileCustom:close()

        local fileBackup, backupErr = io.open(backupConfigFile, "w")
        if not fileBackup then
            RGMercsLogger.log_error("Failed to backup custom core class config: %s (%s)", backupConfigFile, tostring(backupErr))
            return
        end

        fileBackup:write(content)
        fileBackup:close()
    end

    local file, openErr = io.open(baseConfigFile, "r")
    if not file then
        RGMercsLogger.log_error("Failed to load base class config: %s (%s)", baseConfigFile, tostring(openErr))
        return
    end

    local content = file:read("*all")
    file:close()

    local updatedContent, replacements = content:gsub("(_author%s*=%s*[%S%s]-\n)", "%1    FullConfig = true,\n")
    if replacements == 0 then
        RGMercsLogger.log_error("Failed to inject FullConfig into base class config: %s", baseConfigFile)
        return
    end

    mq.pickle(customConfigFile, {}) -- ensure custom path exists

    local customFile, writeErr = io.open(customConfigFile, "w")
    if not customFile then
        RGMercsLogger.log_error("Failed to write custom core class config: %s (%s)", customConfigFile, tostring(writeErr))
        return
    end

    customFile:write(updatedContent)
    customFile:close()

    RGMercsLogger.log_info("Custom Core Class Config Written: %s", customConfigFile)
end

function ClassLoader.mergeTables(tblA, tblB)
    for k, v in pairs(tblB) do
        if type(v) == "table" then
            if type(tblA[k]) == "table" then
                ClassLoader.mergeTables(tblA[k], v)
            else
                tblA[k] = v
            end
        else
            tblA[k] = v
        end
    end

    return tblA
end

return ClassLoader