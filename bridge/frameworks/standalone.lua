-- bridge/frameworks/standalone.lua
-- Base sem framework: a identidade é a licença (license:) do jogador.
-- Serve para servidores que não usam vRP/QBCore/ESX e como rede de segurança
-- quando a base escolhida ainda não subiu.

SolisFrameworks = SolisFrameworks or {}

local function LicenseOf(src)
    local identifiers = GetPlayerIdentifiers(src)

    for _, identifier in ipairs(identifiers) do
        if identifier:find('^license:') then return identifier:sub(9) end
    end

    return identifiers[1]
end

SolisFrameworks.standalone = {
    name = 'standalone',
    resource = nil,
    vehicles = (Config.FrameworkVehicles or {}).standalone,

    activate = function()
        return true
    end,

    getId = function(_, src)
        return LicenseOf(src)
    end,

    getName = function(_, id)
        for _, raw in ipairs(GetPlayers()) do
            local src = tonumber(raw)
            if src and LicenseOf(src) == id then
                local name = GetPlayerName(src)
                return name and name:match('%S+') or nil
            end
        end

        return nil
    end,

    getSource = function(_, id)
        for _, raw in ipairs(GetPlayers()) do
            local src = tonumber(raw)
            if src and LicenseOf(src) == id then return src end
        end

        return nil
    end
}
