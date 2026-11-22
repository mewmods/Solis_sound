-- bridge/frameworks/qbcore.lua
-- QBCore: o identificador é o citizenid (texto).

SolisFrameworks = SolisFrameworks or {}

local options = (Config.FrameworkOptions or {}).qbcore or {}
local resource = options.resource or 'qb-core'

SolisFrameworks.qbcore = {
    name = 'qbcore',
    resource = resource,
    vehicles = (Config.FrameworkVehicles or {}).qbcore,

    activate = function()
        local ok, core = pcall(function()
            return exports[resource]:GetCoreObject()
        end)

        if not ok or type(core) ~= 'table' or type(core.Functions) ~= 'table' then
            return false, ('%s não respondeu a GetCoreObject'):format(resource)
        end

        return core
    end,

    getId = function(core, src)
        local player = core.Functions.GetPlayer(src)
        local data = player and player.PlayerData
        return data and data.citizenid or nil
    end,

    getName = function(core, id)
        local player = core.Functions.GetPlayerByCitizenId(id)
        local info = player and player.PlayerData and player.PlayerData.charinfo
        return info and info.firstname or nil
    end,

    getSource = function(core, id)
        local player = core.Functions.GetPlayerByCitizenId(id)
        return player and player.PlayerData and player.PlayerData.source or nil
    end
}
