aConfig = {}

-- ==========================================
-- FRAMEWORK
-- ==========================================
-- Base do servidor. 'auto' detecta pela ordem vrp -> qbcore -> esx -> standalone.
-- Em servidor vRP (solis, zirix e derivados) o recurso é sempre montado como
-- 'vrp', então 'vrp' vale para qualquer distro: a ponte usa só Passport,
-- Identity, PassportPlate e Source, que existem em todas elas.
Config.Framework = 'auto'

-- Pasta de cada framework no servidor. Só a base escolhida é usada.
Config.FrameworkOptions = {
    vrp = { resource = 'vrp' },
    qbcore = { resource = 'qb-core' },
    esx = { resource = 'es_extended' }
}

-- De onde sai o dono do veículo quando o framework não traz isso no core.
-- O vRP já responde por PassportPlate; QBCore/ESX guardam o dono na tabela do
-- garage. Ajuste para as colunas do seu garage, ou use false para desligar
-- (o recurso ainda tenta o state.Passport da entidade, que é o que os garages
-- costumam gravar no veículo).
Config.FrameworkVehicles = {
    qbcore = { table = 'player_vehicles', owner = 'citizenid', plate = 'plate' },
    esx = { table = 'owned_vehicles', owner = 'owner', plate = 'plate' },
    standalone = false
}

-- Chave da YouTube Data API v3 (https://console.cloud.google.com/).
-- Usada apenas para buscar/importar vídeos e playlists na interface.
-- Se a cota diária acabar, o recurso consulta os dados publicos do proprio
-- YouTube pelo servidor, entao a busca continua funcionando sem a chave.
Config.YoutubeAPIKey = ""

-- SoundCloud sem cadastro: usamos a mesma API interna do site (api-v2).
-- O client_id abaixo é o que vem nos bundles de soundcloud.com. Se a busca
-- parar de responder (401), atualize com o valor atual de:
--   https://a-v2.sndcdn.com/assets/<bundle principal>.js  ->  client_id:"..."
-- Toda a busca passa pelo servidor: a NUI não tem CORS com api-v2.soundcloud.com.
Config.SoundCloud = {
    Enabled = true,
    ApiBase = 'https://api-v2.soundcloud.com',
    SiteUrl = 'https://soundcloud.com',
    WidgetUrl = 'https://w.soundcloud.com/player/',
    ClientId = 'CChZD2mMycEGHhAlsLpujzw5abF8LkQX',
    SearchLimit = 18
}

-- Spotify entra só como CATÁLOGO: a Web API não entrega áudio tocável (o SDK
-- exige Premium por jogador e não deixa aplicar o lowpass). Crie um app em
-- https://developer.spotify.com/dashboard e cole o Client ID / Client Secret.
-- Não é preciso Premium para a busca; o Premium só serviria para o player real.
Config.Spotify = {
    Enabled = true,
    ClientId = '',
    ClientSecret = '',
    ApiBase = 'https://api.spotify.com/v1',
    TokenUrl = 'https://accounts.spotify.com/api/token',
    Market = 'BR',
    SearchLimit = 18,
    PlaylistLimit = 250,   -- máximo de faixas importadas por playlist
    Resolver = 'youtube',  -- 'youtube' ou 'soundcloud' (fallback sempre tentado)
    ResolveDelay = 120     -- pausa entre faixas na resolução em segundo plano (ms)
}

-- Multiplicador global de volume aplicado ao sair do cliente para o motor de áudio.
Config.VolumeMulti = 2.0

-- Alcance (metros) de cada tipo de dispositivo.
Config.Distances = {
    Boombox = 15.0,
    VehicleOpen = 60.0,
    VehicleClosed = 4.0,
    Motorbike = 6.0
}

-- Volume de quem está fora de um carro fechado. Perto de 1.0 o filtro é quem
-- abafa; valores menores somam atenuação.
Config.MuffledVolume = 0.95

-- Filtro DSP do carro fechado: lowpass em cascata + reforço de graves.
--   leve  -> abafa pouco          medio -> equilibrado (padrão)     forte -> corta quase tudo
Config.VehicleFilter = {
    Profile = "medio",

    Profiles = {
        leve = {
            Cutoff = 420.0,
            Resonance = 1.6,
            BassFreq = 100.0,
            BassGain = 7.0,
            BassQ = 1.4,
            Smoothing = 0.12
        },

        medio = {
            Cutoff = 260.0,
            Resonance = 2.4,
            BassFreq = 95.0,
            BassGain = 10.0,
            BassQ = 1.7,
            Smoothing = 0.12
        },

        forte = {
            Cutoff = 150.0,
            Resonance = 4.0,
            BassFreq = 90.0,
            BassGain = 13.0,
            BassQ = 1.5,
            Smoothing = 0.12
        }
    }
}

-- Limites de carga. O servidor recusa o que passar disto.
Config.Limits = {
    MaxSessions = 3,              -- sessões simultâneas por jogador
    MaxQueue = 250,               -- faixas por fila enviada ao servidor
    MaxPlaylists = 60,            -- playlists por passaporte
    MaxSongsPerPlaylist = 500,
    MaxPlaylistName = 80,
    MaxTitle = 160,
    MaxUrl = 512,
    MaxThumb = 512,
    MaxStageListeners = 64        -- ouvintes simultâneos por palco
}

-- Rede: quanto o cliente varre e com que frequência fala com o servidor.
-- Nada é enviado para -1; o servidor só fala com quem demonstrou interesse.
Config.Net = {
    InterestRadius = 90.0,        -- raio de varredura de veículos
    InterestMaxVehicles = 96,     -- teto de netIds por mensagem de interesse
    ScanInterval = 500,           -- varredura local de interesse (entrada no som de outro carro)
    Heartbeat = 5000,             -- reenvio do interesse mesmo sem mudança
    SessionPoll = 15000,          -- reconciliação da lista de sessões
    RangeWarn = 25.0              -- distância em que a sessão é marcada "fora de alcance"
}

-- Motor de áudio local.
Config.Audio = {
    Refresh = 100,                -- envio da posição do ouvinte (ms)
    Moved = 0.25,                 -- metros para reenviar a posição
    MuffleRefresh = 4000,         -- reenvio do estado do filtro (ms)
    TrackingMaxMisses = 1200,     -- ciclos sem som antes de soltar o rastreio

    -- Página do player do YouTube hospedada em https (html/player.html).
    -- O CEF do FiveM não envia Referer do cfx-nui e o YouTube responde com o
    -- erro 153; vindo de um domínio https a embed tem Referer e toca.
    -- Página que hospeda o iframe do YouTube. Vazio = a própria página do
    -- recurso servida em https://cfx-nui-<recurso>/html/player.html, que é a
    -- origem que o YouTube reconhece (o nui:// não tem Referer: erro 153).
    -- Preencha só se quiser usar outro domínio (worker, Pages...).
    YoutubePlayer = ''
}

-- Acessório de fone no ouvido (modo "fones individuais").
-- `Prop` é o slot de prop (2 = orelha) e os demais são os drawables do ped
-- freemode padrão. Se o seu servidor usa outro modelo/headset, troque aqui: o
-- script avisa no console quando o drawable não existe no ped.
Config.Headphones = {
    Enabled = true,
    Prop = 2,
    Male = 41,
    Female = 22
}

-- Pareamento de Bluetooth.
Config.Bluetooth = {
    ScanRadius = 12.0,            -- raio de descoberta de veículos/palcos
    PairLimit = 80                -- pareamentos por passaporte
}

-- Spotify Jam.
Config.Jam = {
    MaxMembers = 24,
    AnyoneCanControl = false      -- false = o anfitrião libera cada membro; true = todos controlam
}

-- Proteção contra flood de eventos vindos do cliente.
Config.RateLimit = {
    Actions = 600,                -- mensagens de controle (slider manda em cada input)
    Writes = 6,                   -- gravações em banco
    Window = 10000                -- janela em ms
}

-- Palcos / festas. `mapBlip` desenha o ícone no radar, `marker` o marcador 3D.
Config.Stages = {
    ["beach_party"] = {
        label = "Beach Party",
        coords = vector3(-1524.45, -1487.74, 6.9),
        radius = 80.0,

        mapBlip = { enable = true, sprite = 484, color = 4, scale = 0.8, name = "Festa na Praia" },

        marker = {
            enable = true,
            type = 1,
            color = { r = 29, g = 185, b = 84, a = 100 },
            scale = { x = 1.5, y = 1.5, z = 0.5 },
            drawDist = 80.0
        }
    },


    ["vanilla_unicorn"] = {
        label = "Vanilla Unicorn DJ",
        coords = vector3(121.0, -1281.0, 29.5),
        radius = 40.0,
        mapBlip = { enable = true },
        marker = {
            enable = true,
            type = 2,
            color = { r = 255, g = 0, b = 100, a = 150 },
            scale = { x = 0.5, y = 0.5, z = 0.5 },
            drawDist = 10.0
        }
    }


}
