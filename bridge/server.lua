-- bridge/server.lua — solis_sound
-- Ponte de framework. O resto do recurso fala só com esta tabela e nunca com
-- vRP/QBCore/ESX direto. A base vem de Config.Framework:
--   'vrp' | 'qbcore' | 'esx' | 'standalone' | 'auto'
-- As implementações ficam em bridge/frameworks/<base>.lua e cada uma entrega
-- quatro primitivas: getId(src), getName(id), getSource(id), getPlateOwner(plate).
--
-- O identificador é normalizado sempre para texto: o passaporte do vRP é
-- numérico, o citizenid do QBCore e o identifier do ESX são texto. Assim as
-- tabelas e as comparações funcionam igual em qualquer base.

Bridge = Bridge or {}

local Frameworks = SolisFrameworks or {}

Bridge.Name = 'standalone'
Bridge.Module = nil
Bridge.Interface = nil

-- Ordem da detecção automática; sem nenhuma delas o recurso roda standalone.
local DETECT_ORDER = { 'vrp', 'qbcore', 'esx' }
local RETRY_AFTER = 5000

local warned = {}
local chosen = nil
local fallback = false
local retryAt = 0

local function Warn(key, message)
    if warned[key] then return end
    warned[key] = true
    print(('[solis_sound] %s'):format(message))
end

-- ==========================================
-- IDENTIFICADOR
-- ==========================================
function Bridge.Normalize(value)
    if value == nil or value == false then return nil end

    if type(value) == 'number' then
        -- Passaporte pode chegar como float do JSON/MySQL: evita "12.0".
        value = ('%d'):format(math.floor(value))
    end

    local text = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return nil end
    return text
end

function Bridge.Same(first, second)
    local left = Bridge.Normalize(first)
    if not left then return false end
    return left == Bridge.Normalize(second)
end

-- ==========================================
-- SELEÇÃO DA BASE
-- ==========================================
local function Detect()
    for _, name in ipairs(DETECT_ORDER) do
        local module = Frameworks[name]
        local resource = module and module.resource or name
        local state = GetResourceState(resource)

        if state == 'started' or state == 'starting' then return name end
    end

    return 'standalone'
end

local function Activate(name)
    local module = Frameworks[name]
    if not module then
        Warn('missing:' .. tostring(name), ('framework "%s" sem implementação em bridge/frameworks.'):format(tostring(name)))
        return nil
    end

    -- O lib do vRP responde mesmo com o resource parado; sem esta checagem a
    -- ponte ativaria uma interface que não responde a nada.
    if module.resource and GetResourceState(module.resource) ~= 'started' then return nil end

    local ok, interface, err = pcall(module.activate)
    if not ok then
        Warn('failed:' .. name, ('framework "%s" falhou ao ativar: %s'):format(name, tostring(interface)))
        return nil
    end

    if not interface then
        Warn('failed:' .. name, ('framework "%s" indisponível: %s'):format(name, tostring(err)))
        return nil
    end

    return interface
end

-- A ativação é preguiçosa: se o solis_sound subir antes do framework (ordem do
-- server.cfg), a próxima chamada tenta de novo em vez de ficar sem base.
local function Active()
    if Bridge.Interface and not fallback then return true end
    if fallback and GetGameTimer() < retryAt then return true end

    if not chosen then
        local wanted = tostring(Config.Framework or 'auto'):lower()
        if wanted == '' or wanted == 'auto' then wanted = Detect() end
        chosen = wanted
    end

    local interface = Activate(chosen)
    if interface then
        Bridge.Name = chosen
        Bridge.Module = Frameworks[chosen]
        Bridge.Interface = interface
        fallback = false

        print(('[solis_sound] framework: %s'):format(chosen))
        return true
    end

    -- Fallback temporário: mantém o recurso vivo até a base escolhida subir.
    if chosen ~= 'standalone' then
        retryAt = GetGameTimer() + RETRY_AFTER

        if not fallback then
            interface = Activate('standalone')
            if interface then
                Bridge.Name = 'standalone'
                Bridge.Module = Frameworks.standalone
                Bridge.Interface = interface
                fallback = true
            end
        end
    end

    return Bridge.Interface ~= nil
end

-- ==========================================
-- DONO DO VEÍCULO PELA TABELA DO GARAGE
-- ==========================================
-- vRP resolve isso no core; QBCore/ESX guardam o dono na tabela do garage
-- (Config.FrameworkVehicles). Se a tabela não existir, devolve nil e o recurso
-- continua usando o state.Passport da entidade.
local function PlateOwnerFromTable(plate)
    local config = Bridge.Module and Bridge.Module.vehicles
    if type(config) ~= 'table' or config.enabled == false then return nil end

    local tableName = tostring(config.table or '')
    local ownerColumn = tostring(config.owner or 'owner')
    local plateColumn = tostring(config.plate or 'plate')

    if not tableName:match('^[%w_%.]+$')
        or not ownerColumn:match('^[%w_]+$')
        or not plateColumn:match('^[%w_]+$') then
        return nil
    end

    if GetResourceState('oxmysql') ~= 'started' then return nil end

    local rows = exports.oxmysql:query_async(
        ('SELECT %s AS owner FROM %s WHERE %s = ? LIMIT 1'):format(ownerColumn, tableName, plateColumn),
        { (plate:gsub('^%s+', ''):gsub('%s+$', '')) }
    )

    local row = type(rows) == 'table' and rows[1]
    return row and row.owner or nil
end

-- ==========================================
-- CONTRATO USADO PELO RESTO DO RECURSO
-- ==========================================
local function Call(method, ...)
    if not Active() then return nil end

    local fn = Bridge.Module and Bridge.Module[method]
    if type(fn) ~= 'function' then return nil end

    local ok, result = pcall(fn, Bridge.Interface, ...)
    if not ok then return nil end
    return result
end

function Bridge.GetId(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end

    return Bridge.Normalize(Call('getId', src))
end

function Bridge.GetName(id)
    local key = Bridge.Normalize(id)
    if not key then return nil end

    local name = Call('getName', key)
    if type(name) ~= 'string' or name == '' then return nil end
    return name
end

function Bridge.GetSource(id)
    local key = Bridge.Normalize(id)
    if not key then return nil end

    local src = tonumber(Call('getSource', key))
    if not src or src <= 0 then return nil end
    return src
end

function Bridge.GetPlateOwner(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end

    local owner = Call('getPlateOwner', plate)
    if owner ~= nil and owner ~= false then return Bridge.Normalize(owner) end

    return Bridge.Normalize(PlateOwnerFromTable(plate))
end

-- ==========================================
-- CHAMADAS CLIENTE -> SERVIDOR (COM RETORNO)
-- ==========================================
-- Substitui o Tunnel do vRP com o mesmo formato (método + argumentos +
-- retorno), só que em cima de eventos nativos. O cliente continua chamando
-- Server.sessions(), Server.connect(...), etc.
local Interface = {}
local bound = false

function Bridge.bindInterface(name, interface)
    Interface = type(interface) == 'table' and interface or {}

    if bound then return end
    bound = true

    RegisterNetEvent(name .. ':bridge:req', function(requestId, method, args)
        local src = source
        if type(requestId) ~= 'number' or type(method) ~= 'string' then return end
        if type(args) ~= 'table' then args = {} end

        local member = Interface[method]
        if type(member) ~= 'function' then
            TriggerClientEvent(name .. ':bridge:res', src, requestId, table.pack())
            return
        end

        -- As funções da API leem o `source` do evento, como no Tunnel do vRP.
        -- Um erro na chamada responde vazio em vez de deixar o cliente 20 s
        -- esperando o timeout da ponte.
        local ok, results = pcall(function()
            return table.pack(member(table.unpack(args, 1, #args)))
        end)

        if not ok then
            Warn('rpc:' .. method, ('erro em "%s": %s'):format(method, tostring(results)))
            results = table.pack()
        end

        TriggerClientEvent(name .. ':bridge:res', src, requestId, results)
    end)
end
