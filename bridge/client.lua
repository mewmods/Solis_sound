-- bridge/client.lua — solis_sound
-- Chamadas cliente -> servidor com retorno, sem depender de framework.
-- Substitui o Tunnel do vRP mantendo a mesma forma de uso:
--   local Server = Bridge.getInterface()
--   local lista = Server.sessions()
--   local resultado = Server.connect(payload, handoff)

Bridge = Bridge or {}

local RES = GetCurrentResourceName()
local TIMEOUT = 20000

local requestId = 0
local pending = {}

RegisterNetEvent(RES .. ':bridge:res', function(id, results)
    local entry = pending[id]
    if not entry then return end

    pending[id] = nil
    entry.deferred:resolve(type(results) == 'table' and results or {})
end)

local function Call(method, ...)
    requestId = requestId + 1
    local id = requestId
    local deferred = promise.new()

    pending[id] = { deferred = deferred, method = method }

    -- Sem resposta (erro na API, recurso reiniciando) a chamada devolve vazio
    -- em vez de prender a thread do cliente para sempre.
    SetTimeout(TIMEOUT, function()
        local entry = pending[id]
        if not entry then return end

        pending[id] = nil
        entry.deferred:resolve({})
        print(('[solis_sound] sem resposta do servidor para "%s".'):format(entry.method))
    end)

    TriggerServerEvent(RES .. ':bridge:req', id, method, { ... })

    local results = Citizen.Await(deferred)
    if type(results) ~= 'table' then return end

    return table.unpack(results, 1, results.n or #results)
end

-- Uma tabela que resolve qualquer método na primeira chamada: o cliente só
-- precisa saber o nome da função do servidor.
function Bridge.getInterface()
    local interface = {}

    return setmetatable(interface, {
        __index = function(_, method)
            local fn = function(...) return Call(method, ...) end
            interface[method] = fn
            return fn
        end
    })
end
