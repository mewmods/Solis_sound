-- bridge/frameworks/esx.lua
-- ESX Legacy: o identificador é o identifier (license/steam).

SolisFrameworks = SolisFrameworks or {}

local options = (Config.FrameworkOptions or {}).esx or {}
local resource = options.resource or 'es_extended'

SolisFrameworks.esx = {
    name = 'esx',
    resource = resource,
    vehicles = (Config.FrameworkVehicles or {}).esx,

    activate = function()
        local ok, esx = pcall(function()
            return exports[resource]:getSharedObject()
        end)

        if not ok or type(esx) ~= 'table' or type(esx.GetPlayerFromId) ~= 'function' then
            return false, ('%s não respondeu a getSharedObject'):format(resource)
        end

        return esx
    end,

    getId = function(esx, src)
        local player = esx.GetPlayerFromId(src)
        return player and player.identifier or nil
    end,

    getName = function(esx, id)
        local player = esx.GetPlayerFromIdentifier(id)
        if not player or type(player.getName) ~= 'function' then return nil end

        local full = player.getName()
        if type(full) ~= 'string' then return nil end
        return full:match('%S+') or full
    end,

    getSource = function(esx, id)
        local player = esx.GetPlayerFromIdentifier(id)
        return player and player.source or nil
    end
}
