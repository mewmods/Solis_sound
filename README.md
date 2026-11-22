# solis_sound

Sistema de música completo para servidores **FiveM**, com **motor de áudio próprio** (sem `xsound`/`interact-sound`), **sessões espaciais autoritativas no servidor**, **Jam**, playlists e interface própria em NUI.

`Versão 2.0.0` · `FiveM / GTA V` · `oxmysql` · **vRP (solis/zirix/creative)**, **QBCore**, **ESX** ou **standalone**

---

## O que tem dentro

- **Motor de áudio próprio** — página DUI com Web Audio: YouTube (iframe via `player.html`), SoundCloud (stream direto MP3/HLS) e DSP de *lowpass* para carro fechado. Se a Web Audio for bloqueada por CORS, o filtro se desliga sozinho e o som continua limpo.
- **Sessões espaciais** — fones privados, som de veículo (aberto/fechado/moto), palcos de festa e Jam. O servidor guarda o estado, decide quem ouve o quê, a que distância e **quem pode controlar**.
- **Jam** — sala por código `JAM-XXXX` (até 24 membros). O anfitrião define quem, além dele, pode trocar faixa, pausar e mexer na fila; quem não tem permissão fica como **ouvinte** (controles travados + aviso).
- **Catálogo** — busca no YouTube (API v3 com fallback público sem chave), SoundCloud (API interna via servidor) e Spotify **somente como catálogo** (cada faixa é resolvida para YouTube/SoundCloud antes de tocar).
- **Playlists** — criação, colaboradores, AirDrop entre jogadores e importação de playlists do Spotify com resolução em segundo plano.
- **Bluetooth** — pareamento com veículos e palcos por placa, com aprovação do dono e reconexão automática.
- **Fones como prop** — acessório de ouvido no ped enquanto o jogador usa o modo "fones individuais", configurável e restaurado ao sair.
- **Compatibilidade** — exports no formato `xsound` (cliente e servidor) e ponte pronta para o celular (`fphone2`).
- **Agnóstico de framework** — ponte própria (`bridge/`) com vRP, QBCore, ESX e standalone. Nenhum `@vrp` no manifesto: o recurso abre em qualquer base e detecta a certa sozinho.

---

## Requisitos

- FiveM server com artifacts recentes (DUI, `RegisterKeyMapping`).
- [`oxmysql`](https://github.com/overextended/oxmysql) configurado e funcionando.
- Uma base: **vRP** (solis, zirix e derivados — usa `Passport`, `Identity`, `PassportPlate`), **QBCore** (citizenid), **ESX Legacy** (identifier) ou **standalone** (licença do jogador).
- Saída de rede do servidor para `youtube.com`, `googleapis.com`, `api-v2.soundcloud.com`, `accounts.spotify.com`, `api.spotify.com` e `w.soundcloud.com`.

---

## Instalação

1. Copie a pasta `solis_sound` para `resources/` (de preferência em `[solis]/`).
2. Coloque no `server.cfg`, nesta ordem:

```cfg
ensure oxmysql
ensure vrp            # ou qb-core / es_extended (ou nada, em standalone)
ensure solis_sound
```

3. Inicie o servidor. As tabelas são criadas automaticamente ~1 s após o start — **não é preciso rodar SQL**.
4. Entre no jogo e use `/som` para abrir o painel.
5. Confira o console: `[solis_sound] motor de áudio pronto. (https://cfx-nui-...)` significa DUI saudável.

> O recurso **não** tem comandos administrativos. Staff controla por `restart`/`ensure`. Reiniciar derruba sessões e Jams (o banco permanece).

---

## Configuração rápida

Tudo fica em `config.lua`, comentado em português.

### Framework

```lua
Config.Framework = 'auto'   -- 'auto' | 'vrp' | 'qbcore' | 'esx' | 'standalone'

Config.FrameworkOptions = {
    vrp = { resource = 'vrp' },
    qbcore = { resource = 'qb-core' },
    esx = { resource = 'es_extended' }
}
```

`auto` tenta na ordem **vrp → qbcore → esx → standalone**. Em servidor vRP o recurso é sempre montado como `vrp`, então o mesmo valor serve para solis, zirix e derivados.

Para dono de veículo no QBCore/ESX (usado no Bluetooth), ajuste as colunas do seu garage em `Config.FrameworkVehicles` — ou use `false` para desligar e ficar só com o `state.Passport` gravado no veículo.

### Fones (prop no ouvido)

```lua
Config.Headphones = {
    Enabled = true,
    Prop = 2,        -- slot do prop (2 = orelha)
    Male = 41,       -- drawable no mp_m_freemode_01
    Female = 22      -- drawable no mp_f_freemode_01
}
```

O fone aparece enquanto houver faixa carregada no modo individual (tocando **ou pausado**), reaplica após respawn e devolve o prop original ao sair. Se o drawable não existir no ped, o console avisa uma vez — troque os valores por um válido do seu servidor.

### Jam

```lua
Config.Jam = {
    MaxMembers = 24,
    AnyoneCanControl = false   -- true libera todos que entram
}
```

Com `false` (padrão), **quem entra começa como ouvinte**. Na aba **Jam** do painel, o anfitrião usa **"Dar controle" / "Remover controle"** ao lado de cada membro. O anfitrião sempre controla. Quem não pode, vê os controles travados e recebe o aviso *"Nesta jam você está apenas como ouvinte"* — a faixa não muda só para ele.

### Chaves de API

`Config.YoutubeAPIKey`, `Config.SoundCloud.ClientId` e `Config.Spotify` já vêm preenchidos com valores de exemplo. Para produção, gere os seus:

| Serviço | Onde gerar |
|---|---|
| YouTube Data API v3 | [console.cloud.google.com](https://console.cloud.google.com/) |
| Spotify | [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) |
| SoundCloud | valor atual de `client_id` no bundle de `soundcloud.com` (se a busca der 401) |

---

## Comandos

| Comando | Efeito |
|---|---|
| `/som` | Abre/fecha o painel. |
| `/som 0-100` | Volume individual em %. |
| `/som on` / `/som off` | Restaura / muta o volume individual. |
| `/som1 ...` | Alias de `/som`. |
| `Y` / `U` | Aceitar / recusar pedidos (Bluetooth, AirDrop, colaboração). |

---

## Exports

### Celular / outros recursos

```lua
exports.solis_sound:PlayPhoneMusic(url, title, thumb)
exports.solis_sound:PausePhoneMusic()
exports.solis_sound:ResumePhoneMusic()
exports.solis_sound:SeekPhoneMusic(time)
exports.solis_sound:SetPhoneVolume(0.0)      -- 0.0 a 1.0
exports.solis_sound:GetPhoneAudioState()     -- { playing, currentTime, duration, volume, mode, device }
exports.solis_sound:GetIndividualVolume()
exports.solis_sound:SetIndividualVolume(0.0)
```

As exports de música do celular respeitam a permissão da Jam: chamadas de quem é apenas ouvinte são ignoradas com o aviso.

### Motor de áudio (compatível com `xsound`)

```lua
exports.solis_sound:PlayUrl(id, url, volume, loop)
exports.solis_sound:PlayUrlPos(id, url, volume, pos, loop)
exports.solis_sound:Destroy(id)
exports.solis_sound:Pause(id)
exports.solis_sound:Resume(id)
exports.solis_sound:setVolume(id, volume)
exports.solis_sound:Distance(id, distance)
exports.solis_sound:Position(id, pos)
exports.solis_sound:setTimeStamp(id, time)
exports.solis_sound:onPlayEnd(id, fn)
exports.solis_sound:setMuffled(id, on, params)
```

No servidor, as mesmas funções recebem `src` como primeiro argumento (`PlayUrl(src, id, ...)`, `Destroy(src, id)`, `DestroyAll(src)`, etc.).

---

## Banco de dados

Criadas automaticamente com `IF NOT EXISTS`; bancos antigos são migrados coluna por coluna sem perder dados (`passport` é sempre texto).

| Tabela | Conteúdo |
|---|---|
| `player_playlists` | Playlist completa em JSON, com contagem e capa desnormalizadas. |
| `player_playlist_members` | Colaboradores (N:N). |
| `player_spotify_recent` | Histórico das últimas faixas (12 exibidas). |
| `player_bluetooth_paired` | Pareamentos por placa, com reconexão automática. |

---

## Estrutura

```
solis_sound/
├── fxmanifest.lua
├── config.lua              # framework, chaves, limites, DSP, palcos, fones
├── client.lua              # estado do jogador, fila, NUI, Bluetooth, sessões, Jam
├── server.lua              # autoridade: sessões, Jam, playlists, banco
├── bridge/                 # ponte de framework (VRP, QBCore, ESX, standalone)
│   ├── client.lua · server.lua
│   └── frameworks/
├── audio/                  # motor de áudio (DUI) no cliente e no servidor
└── html/                   # NUI: painel, motor, player https do YouTube
    ├── index.html · app.js · style.css
    ├── audio.html · audio.js · hls.min.js
    └── player.html
```

> Os arquivos de `html/` precisam estar em `files` no manifesto. Sem `audio.html`/`audio.js` o motor não sobe; sem `player.html` o YouTube cai no erro 153.

---

## Problemas comuns

| Sintoma | Correção |
|---|---|
| `motor de áudio sem resposta; recriando` | Confira `html/audio.html` e `html/audio.js` em `files` e reinicie o recurso. |
| YouTube sem áudio (erro 153) | Deixe `Config.Audio.YoutubePlayer = ''` (usa `player.html` em `https://cfx-nui-...`). |
| Busca do SoundCloud com 401 | Atualize `Config.SoundCloud.ClientId`. |
| Faixas do Spotify não tocam | Resolução falhou: veja `Config.Spotify.Resolver` e a saída de rede do servidor; reimporte. |
| "Dispositivo ocupado no momento" | Limite de 2 ouvintes por veículo — saia de outra sessão ou use um palco. |
| Sessão/Jam sumiu após restart | Esperado: sessões vivem em memória. |
| Fone não aparece no ped | Drawable inválido para o modelo — o console avisa; ajuste `Config.Headphones`. |

---

## Documentação

O detalhamento técnico (arquitetura, protocolo da DUI, eventos, referência completa de configuração, segurança e dimensionamento) está em **[DOCUMENTACAO.md](DOCUMENTACAO.md)**.

Autor: **mewmods**
