-- bridge/frameworks/vrp.lua
-- vRP (solis, zirix e derivados). No servidor o framework é sempre montado
-- como 'vrp', então nada aqui depende do nome da pasta original.
--
-- A interface do vRP não é exposta por exports: ela vem do próprio lib
-- (module + Proxy). O lib é carregado na hora, e não pelo fxmanifest, para o
-- solis_sound abrir também em servidores sem vRP (@vrp/lib/utils.lua ausente
-- derrubaria o recurso inteiro).

SolisFrameworks = SolisFrameworks or {}

local options = (Config.FrameworkOptions or {}).vrp or {}
local resource = options.resource or 'vrp'

local function LoadVrpLib()
    if type(module) == 'function' then return true end

    local code = LoadResourceFile(resource, 'lib/utils.lua')
    if type(code) ~= 'string' then
        return false, ('%s/lib/utils.lua não encontrado'):format(resource)
    end

    local chunk, err = load(code, '@' .. resource .. '/lib/utils.lua')
    if not chunk then return false, ('utils.lua inválido: %s'):format(tostring(err)) end

    local ok, runErr = pcall(chunk)
    if not ok then return false, ('utils.lua falhou: %s'):format(tostring(runErr)) end

    -- Os módulos internos do vRP chamam module("lib/Tools") fixo em 'vrp'.
    -- Se a pasta do framework tiver outro nome, o wrapper mantém a resolução.
    if resource ~= 'vrp' and type(module) == 'function' then
        local loadModule = module
        module = function(rsc, path)
            if path == nil then return loadModule(resource, rsc) end
            return loadModule(rsc, path)
        end
    end

    return true
end

SolisFrameworks.vrp = {
    name = 'vrp',
    resource = resource,
    vehicles = false,   -- o vRP já resolve dono de placa no core (PassportPlate)

    activate = function()
        local ok, err = LoadVrpLib()
        if not ok then return false, err end

        local loaded, Proxy = pcall(module, resource, 'lib/Proxy')
        if not loaded or type(Proxy) ~= 'table' then
            return false, ('não foi possível carregar %s/lib/Proxy.lua'):format(resource)
        end

        local interface = Proxy.getInterface('vRP')
        if not interface then return false, 'interface vRP indisponível' end

        return interface
    end,

    getId = function(interface, src)
        local passport = interface.Passport(src)
        if passport == nil or passport == false then return nil end
        return passport
    end,

    getName = function(interface, id)
        local identity = interface.Identity(tonumber(id) or id)
        local full = type(identity) == 'table' and identity.Name or nil
        if type(full) ~= 'string' then return nil end
        return full:match('%S+') or full
    end,

    getSource = function(interface, id)
        return interface.Source(tonumber(id) or id)
    end,

    getPlateOwner = function(interface, plate)
        local passport = interface.PassportPlate(plate)
        if passport == nil or passport == false then return nil end
        return passport
    end
}
