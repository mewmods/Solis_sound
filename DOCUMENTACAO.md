# solis_sound — Documentação Técnica

> **Versão documentada:** 2.0.0 (`fxmanifest.lua`)
> **Plataforma:** FiveM / GTA V (`fx_version 'cerulean'`, `game 'gta5'`)
> **Framework:** ponte própria (`Config.Framework`): vRP (solis/zirix), QBCore, ESX ou standalone
> **Banco:** MySQL via `oxmysql`
> **Autor:** Solis

---

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquitetura](#2-arquitetura)
3. [Estrutura de arquivos](#3-estrutura-de-arquivos)
4. [Conceitos centrais](#4-conceitos-centrais)
5. [Funcionalidades e fluxos](#5-funcionalidades-e-fluxos)
6. [Motor de áudio (DUI)](#6-motor-de-áudio-dui)
7. [Áudio espacial e DSP](#7-áudio-espacial-e-dsp)
8. [Interface (NUI)](#8-interface-nui)
9. [Rede: eventos e callbacks](#9-rede-eventos-e-callbacks)
10. [Banco de dados](#10-banco-de-dados)
11. [Escalabilidade e desempenho](#11-escalabilidade-e-desempenho)
12. [Segurança](#12-segurança)
13. [Referência de configuração](#13-referência-de-configuração)
14. [Instalação e operação](#14-instalação-e-operação)
15. [API pública](#15-api-pública)
16. [Solução de problemas](#16-solução-de-problemas)
17. [Limitações conhecidas e dívida técnica](#17-limitações-conhecidas-e-dívida-técnica)

---

## 1. Visão geral

O **solis_sound** é um sistema de música completo para servidores FiveM, com ponte de framework (vRP, QBCore, ESX ou standalone). Ele não depende de `xsound` nem de `interact-sound`: o recurso traz **motor de áudio próprio**, **sessões espaciais autoritativas no servidor** e **interface própria** (NUI).

Três blocos formam o produto:

| Bloco | O que é |
|---|---|
| **Motor de áudio** | Página DUI (`html/audio.html` + `html/audio.js`) que toca YouTube, SoundCloud, HLS/MP3 e aplica DSP (lowpass de carro fechado) via Web Audio. |
| **Sessões espaciais** | Fones privados, som de veículo, palcos de festa e Jam. O servidor guarda o estado, decide quem ouve o quê e quem pode controlar. |
| **Interface** | Player completo em `html/index.html` + `app.js` + `style.css`: busca, playlists, Bluetooth, sessões, Jam, fila, progresso. |

Catálogo suportado:

* **YouTube** — busca por *YouTube Data API v3* direto da NUI; quando a cota acaba, o servidor lê os dados públicos do próprio YouTube (*fallback* sem chave, sem proxy externo).
* **SoundCloud** — busca e resolução pelo servidor usando a API interna do site (`api-v2`), que a NUI não pode chamar por CORS. O áudio toca por **stream direto** (MP3 progressivo ou HLS via `hls.js`) para permitir DSP; o *widget* oficial é o último recurso.
* **Spotify** — **somente catálogo**. A Web API não entrega áudio reproduzível, então cada faixa é resolvida para YouTube ou SoundCloud antes de entrar na fila, mantendo o selo `provider = "spotify"`.

Além da reprodução, o recurso entrega:

* pareamento **Bluetooth** com veículos e palcos (com aprovação do dono, tecla `Y`/`U`);
* **transferência de reprodução** (handoff) entre fones, carro e palco sem perder posição nem fila;
* **Jam** (sala por código `JAM-XXXX`, até 24 membros);
* **playlists** com colaboradores, AirDrop e importação de playlists do Spotify;
* **histórico de recentes**;
* volume individual persistido por jogador;
* compatibilidade com os exports do `xsound` e ponte para o celular (`fphone2`).

---

## 2. Arquitetura

```
┌─────────────────────────────────────────────────────────────────────┐
│ NUI (CEF)                                                           │
│  index.html / app.js / style.css   →  painel do jogador             │
│  audio.html  / audio.js           →  motor de áudio (DUI)           │
│  player.html                      →  ponte https do YouTube         │
└───────────────▲───────────────────────────────┬─────────────────────┘
                │ SendNUIMessage / post()       │ RegisterNUICallback
┌───────────────┴───────────────────────────────▼─────────────────────┐
│ CLIENTE (client.lua + audio/client.lua)                             │
│  • estado local: me, queue, qIndex, repeat, shuffle, heldVeh/Stage  │
│  • varredura de interesse (raio 90 m, 500 ms)                       │
│  • gerenciador espacial (volume, distância, muffle, posição)        │
│  • fachada Audio.* → mensagens para a DUI                           │
└───────────────▲───────────────────────────────┬─────────────────────┘
                │ eventos solis:cl:*            │ eventos solis:sv:*
┌───────────────┴───────────────────────────────▼─────────────────────┐
│ SERVIDOR (server.lua + audio/server.lua)                            │
│  • Sessions / Watchers / Interests / Jams / Pending (memória)       │
│  • validação, autorização, rate limit, sanitização                  │
│  • HTTP: YouTube (API + scraping), SoundCloud, Spotify              │
└───────────────┬─────────────────────────────────────────────────────┘
                │ oxmysql
        ┌───────▼────────┐
        │ MySQL          │  playlists, membros, recentes, pareamentos
        └────────────────┘
```

### Princípio de autoridade

* **O servidor é a única fonte de verdade sobre sessões.** O cliente pede (`connect`, `play`, `control`, `leave`), o servidor valida distância, dono, lotação, limites e só então fala com quem precisa ouvir — **nunca com `-1` para iniciar reprodução**.
* **A fila, o modo de repetição e o shuffle vivem no cliente.** Só o *controlador* da sessão (`me.owns`) avança faixa; o servidor apenas replica a nova URL.
* **A NUI não tem poder**: ela só renderiza e chama callbacks; todo dado enviado por ela é revalidado no cliente (limites de fila, clamps de volume) e novamente no servidor (URL, tamanho, autorização).
* **O tempo de reprodução é calculado, não consultado.** O cliente deriva de `GetGameTimer()` (`Audio.Time`), o servidor de `os.time()` (`Elapsed`), evitando polling entre CEF e Lua.

---

## 3. Estrutura de arquivos

| Arquivo | Linhas (aprox.) | Papel |
|---|---:|---|
| `fxmanifest.lua` | 49 | Manifesto: scripts, `ui_page`, `files` da NUI, dependência `oxmysql`, `client_exports`. |
| `config.lua` | 407 | Configuração compartilhada (framework, chaves de API, limites, rede, DSP, palcos, prop de fone). |
| `bridge/client.lua` | 62 | Chamadas cliente → servidor com retorno (substitui o `Tunnel` do vRP). |
| `bridge/server.lua` | 257 | Núcleo da ponte: escolhe a base, normaliza o id e expõe `GetId/GetName/GetSource/GetPlateOwner` + `bindInterface`. |
| `bridge/frameworks/vrp.lua` | 84 | vRP (solis, zirix, derivados) via `Proxy` do próprio lib. |
| `bridge/frameworks/qbcore.lua` | 42 | QBCore (`citizenid`). |
| `bridge/frameworks/esx.lua` | 44 | ESX Legacy (`identifier`). |
| `bridge/frameworks/standalone.lua` | 51 | Sem framework: identidade pela licença. |
| `audio/client.lua` | 460 | Motor de áudio: gerencia a DUI, expõe `Audio.*`, callbacks `audio/*`, exports compatíveis com `xsound`. |
| `audio/server.lua` | 52 | Exports server-side no formato `xsound` (`PlayUrl`, `PlayUrlPos`, etc.). |
| `client.lua` | 1798 | Estado do jogador, fila, ponte NUI, Bluetooth, sessões, Jam, playlists, comandos, exports e ponte do celular. |
| `server.lua` | 2975 | Sessões, watchers, Jam, catálogo (YouTube/SoundCloud/Spotify), playlists, migrações de banco. |
| `html/index.html` | 318 | Markup do painel (rail, views, player, toasts, prompt, sheet, menu). |
| `html/style.css` | 1311 | Tema visual do painel. |
| `html/app.js` | 2185 | Lógica da NUI: busca, playlists, fila, Bluetooth, Jam, teclado. |
| `html/audio.html` | 10 | Casca da página do motor (carrega `audio.js`). |
| `html/audio.js` | 1353 | Motor real: backends YouTube/SoundCloud/HTML5, grafo Web Audio, watchdog. |
| `html/player.html` | 155 | Ponte https do YouTube (evita erro 153 do CEF). |
| `html/hls.min.js` | minificado | `hls.js` para streams HLS do SoundCloud. |
| `html/yt.html` | 222 | Página auxiliar de embed; **não está em `files`** do manifesto, não é servida por este recurso. |

Ordem de carregamento (importa):

```lua
shared_scripts { 'config.lua' }

client_scripts { 'bridge/client.lua', 'audio/client.lua', 'client.lua' }
server_scripts {
    'bridge/frameworks/vrp.lua', 'bridge/frameworks/qbcore.lua',
    'bridge/frameworks/esx.lua', 'bridge/frameworks/standalone.lua',
    'bridge/server.lua',
    'audio/server.lua', 'server.lua'
}
```

`Config` precisa existir antes de tudo; as implementações de framework precisam carregar antes de `bridge/server.lua` (é ele que escolhe a base); `Audio` precisa existir antes de `client.lua`. Nenhum `@vrp/...` está no manifesto: o lib do vRP é carregado em tempo de execução só quando a base é `vrp`.

---

## 4. Conceitos centrais

### 4.1 Sessões

Uma **sessão** é um "dispositivo que está tocando". Vive apenas em memória no servidor:

| Campo | Significado |
|---|---|
| `id` | `vehicle_<netId>`, `stage_<stageId>` (fones e Jam não são sessões de servidor). |
| `kind` | `vehicle` ou `stage`. |
| `netId` / `stageId` | Identificador do veículo em rede / chave do palco em `Config.Stages`. |
| `plate` | Placa (veículo) ou `STAGE_<id>`. |
| `name` | Rótulo exibido: `"Sultan de João"`, `"Palco: Beach Party"`. |
| `ownerPassport` | Id do dono (via `state.Passport` da entidade ou `Bridge.GetPlateOwner`). |
| `users` | Conjunto `[src] = true` de quem está conectado (máx. 2 em veículo, 64 em palco). |
| `controller` | Quem controla a reprodução (play/pause/seek/volume/troca de faixa). |
| `url`, `title`, `thumb` | Faixa atual. |
| `vol` | Volume **base** da sessão (0–1), definido pelo controlador. |
| `playing`, `base`, `startedAt` | Relógio: tempo decorrido = `base + (agora - startedAt)`. |
| `queue`, `queueIndex` | Fila replicada para reabrir a sessão com contexto. |
| `misses` | Contador de ciclos em que a entidade do veículo não existiu. |

### 4.2 Estado do cliente (`me`)

```lua
me = {
    kind    = 'headphones' | 'vehicle' | 'stage',
    sessId  = 'headphones' | 'vehicle_<netId>' | 'stage_<id>',
    netId   = 0,
    stageId = nil,
    name    = 'Fones privados',
    url, title, thumb,
    vol     = 0.5,
    playing = false,
    owns    = true   -- true quando é o controlador
}
```

**Fones privados** são o estado neutro: não existem no servidor, tocam só para o jogador, e qualquer "sair da sessão" volta para eles.

### 4.3 Identificadores de som no motor

| Contexto | `sessId` | `soundId` na DUI |
|---|---|---|
| Fones | `headphones` | `hp` |
| Veículo | `vehicle_123` | `veh_123` |
| Palco | `stage_beach_party` | `stg_beach_party` |

### 4.4 Fila

* `queue` = lista de `{ url, title, thumb, provider }`.
* `qIndex` = posição 1-based da faixa atual; a NUI recebe `index = qIndex - 1` (0-based).
* `repeatMode`: `0` = off, `1` = repetir fila, `2` = repetir faixa.
* `shuffleOn`: próximo/avançar escolhem índice aleatório diferente do atual.
* Limite: `Config.Limits.MaxQueue` (250) por fila — validado na NUI, no cliente e no servidor.

### 4.5 "Owns" e "focus"

`owns` = este jogador é o `controller` da sessão. A NUI mostra o botão de tocar/trocar faixa apenas quando `owns` é verdadeiro. O servidor calcula `focus = (sess.controller == src)` em `SessionInfo`; o cliente usa isso em `SetFocused`.

---

## 5. Funcionalidades e fluxos

### 5.1 Abrir e fechar o painel

* `/som` (sem argumento) **alterna** o painel: `SetNuiFocus(true, true)` + `SendNUIMessage({ type = 'visibility', open = true, boot = <payload> })`.
* `/som <0-100>`, `/som on`, `/som off` controlam o **volume individual** (independente do volume da sessão).
* `/som1 ...` é um alias que repassa para `/som`.
* Fechar: botão ✕, tecla `Esc` (a NUI chama o callback `close`, que faz `SetNuiFocus(false,false)`), ou o próprio comando.
* Handshake: a NUI envia `ready` ao carregar; se o painel já estava aberto, o cliente reenvia o `boot` completo — evita painel vazio quando o CEF sobe depois do comando.

### 5.2 Busca e reprodução

1. A NUI decide a fonte pelo texto:
   * link/ID do YouTube → `ytVideo` / `ytPlaylist`;
   * link do SoundCloud → `scResolve`;
   * link do Spotify (`open.spotify.com/track|playlist` ou `spotify:...`) → `spotifyLink`;
   * texto livre → **busca mista**: YouTube + SoundCloud + Spotify (quando habilitados), intercalados para não virar "YouTube + apêndice".
2. YouTube usa a Data API **direto da NUI** com `Config.YoutubeAPIKey`. Em erro de cota, rede ou ausência de chave, cai para `ytFallback`, que roda no servidor (scraping das páginas públicas).
3. SoundCloud e Spotify **sempre** passam pelo servidor (`scSearch`, `scResolve`, `spotifySearch`, `spotifyLink`, `spotifyBatch`), porque exigem credenciais e não têm CORS.
4. Ao tocar, a NUI envia `play` com `queue` e `index`; o cliente:
   * sanitiza a fila (limite, URL, provider);
   * posiciona `qIndex` e chama `PlayIndex(qIndex, 0, true)` → `StartPlayback`;
   * grava a faixa nos **recentes** (`solis:sv:recent`).
5. `StartPlayback` se comporta conforme o dispositivo:
   * **fones**: `Audio.Play('hp', url, vol, false)` local + `Audio.OnEnd('hp', MaybeTrackEnded)`;
   * **veículo/palco**: `TriggerServerEvent('solis:sv:play', ...)`; o som local é criado **pelo eco** `solis:cl:play` (`Audio.PlayPos`). O controlador **não** toca localmente — é o eco que cria/troca o som, garantindo que todos ouçam a mesma coisa.
   * se for anfitrião de uma Jam, replica o estado (`solis:sv:jam`, ação `play`).

### 5.3 Fila, avanço e fim de faixa

* O progresso é lido do motor (`Audio.Time` / `Audio.Duration`) e enviado à NUI só com o painel aberto.
* Fim de faixa tem três gatilhos: callback `audio/ended` da DUI, `Audio.OnEnd`, e uma checagem `time >= duration - 0.6` na thread de progresso.
* `MaybeTrackEnded` usa **geração de reprodução + janela de 800 ms** para não avançar duas vezes nem entrar em loop quando o player emite eventos duplicados.
* `AdvanceQueue`: repetir faixa → mesma faixa; shuffle → índice aleatório; senão próxima; no fim, `repeatMode == 1` reinicia, caso contrário `StopPlayback`.

### 5.4 Troca de dispositivo e Bluetooth

1. O painel pede `bluetooth`; o cliente varre veículos num raio de **`Config.Bluetooth.ScanRadius` (12 m)** e palcos com `radius + 25 m`, envia a lista ao servidor (`API.scan`).
2. O servidor devolve `paired` (já pareados ou do próprio jogador) e `others`, com `connections`/`maxConnections`, `playing` e faixa atual.
3. `bluetoothConnect` monta o payload (`kind`, `netId`/`stageId`, `plate`, `name`, `driver`) e, se o jogador pediu **handoff**, anexa URL, título, thumb, volume, `playing`, tempo atual, fila e índice.
4. `API.connect` valida:
   * palco existente e jogador a até `radius + 25 m`;
   * veículo existente e a até **25 m**;
   * lotação (2 em veículo, `MaxStageListeners` em palco);
   * `MaxSessions` (3) sessões simultâneas por jogador;
   * se não é dono/motorista nem está pareado → `API.requestAccess` gera um pedido e mostra o prompt ao dono.
5. O dono aceita (`Y`) ou recusa (`U`). Aceito: o solicitante entra em `sess.users`, é salvo em `player_bluetooth_paired` e recebe `solis:cl:granted` com a sessão.
6. Entrar numa sessão que já toca dispara `solis:cl:play` com a posição calculada — a música chega "no ponto".
7. `headphones` volta para os fones preservando URL, tempo e volume atuais.

### 5.5 Ouvir o som de quem está perto (interesse espacial)

* A cada `Config.Net.ScanInterval` (500 ms) o cliente varre `GetGamePool('CVehicle')` num raio de **90 m** (`InterestRadius`), limita a **96 netIds** (`InterestMaxVehicles`) e lista os palcos ao alcance (`radius + 25`).
* Monta uma chave ordenada `"id1,id2|palcoA,palcoB"`. Só envia `solis:sv:interest` quando a chave muda ou a cada `Heartbeat` (5 s).
* O servidor compara com `Interests[src]`:
  * remove watchers de sessões que saíram do raio;
  * adiciona watchers novos e, se a sessão estiver tocando, envia `solis:cl:play` na hora.
* "Fora de alcance": se o jogador está focado num veículo e se afasta mais de `RangeWarn` (25 m), a NUI mostra aviso (`type = 'range'`), apenas na transição de estado.
* Com o painel aberto, a lista de sessões é reconciliada a cada `SessionPoll` (15 s). Sem painel, não há polling.

### 5.6 Palcos / festas

* Definidos em `Config.Stages`: `label`, `coords`, `radius`, `mapBlip` (ícone no radar) e `marker` (marcador 3D).
* O cliente desenha blips ao iniciar e marcadores por proximidade (`drawDist`), com `Wait(0)` só quando algum marcador está visível.
* Qualquer jogador próximo pode abrir/usar o palco; o controle é permitido ao controlador **ou a quem está fisicamente perto** — a distância é conferida no servidor (`NearStage`), nunca no cliente.
* O som do palco é posicional na `coords` do palco, com `dist = stage.radius`.

### 5.7 Jam

* `jamCreate` gera código `JAM-XXXX` (alfabeto sem caracteres ambíguos), registra anfitrião, membros e playback atual.
* `jamJoin` aceita código com ou sem prefixo, normaliza, valida lotação (`Config.Jam.MaxMembers`, 24).
* **Modo `own`**: cada membro toca a faixa **localmente**; o servidor sincroniza URL, título, thumb, tempo e fila. Não há streaming de áudio entre jogadores.
* Controle: o anfitrião sempre pode; cada membro só depois que ele liberar (`jamAllow` → `member.canControl`). `Config.Jam.AnyoneCanControl = true` libera todos que entram. Quem não tem permissão vê os controles travados, recebe o toast **"Nesta jam você está apenas como ouvinte"** e o servidor recusa a ação — a música não troca só para ele.
* `jamAction` (`play`, `pause`, `resume`, `seek`) atualiza o playback e emite `solis:cl:jamApply` para todos os membros com `senderSrc`.
* Convite (`jamInvite`), remoção (`jamKick`), permissão de controle (`jamAllow`), saída e encerramento. Se o anfitrião sai/desconecta, a Jam termina para todos.
* A Jam aparece na lista de sessões como `jam_<código>` e pode ser "focada" como qualquer dispositivo.

### 5.8 Playlists

* **Criar**: `playlistCreate(name, songs)` — nome sanitizado (80 chars), até 500 faixas, limite de 60 playlists por passaporte.
* **Adicionar / remover / mover**: gravam o JSON completo em `player_playlists.songs` e atualizam `song_count`, `thumb` (capa = primeira faixa) e `updated_at`.
* **Ler**: `playlistSongs` pagina de 100 em 100; `playlistQueue` monta a fila **a partir da faixa clicada**, limitada a `MaxQueue` (playlists grandes não começam na faixa errada).
* **Excluir**: dono apaga playlist e membros; colaborador apenas sai da tabela de membros.
* **Colaboração**: convite gera prompt no convidado; aceito, insere em `player_playlist_members` e sincroniza a coluna legada `collaborators`.
* **AirDrop**: envia uma **cópia** da playlist para outro jogador online (com aprovação dele).
* **Importar do Spotify**: a playlist é criada imediatamente com metadados reais e linhas `pending`; cada faixa é resolvida em segundo plano (`ResolveDelay`, 120 ms entre faixas) e a linha é atualizada ao vivo na NUI (`playlistTrack`). `SpPatchSong` só substitui o slot se ele ainda for o placeholder do mesmo `spId` — edições do usuário não são atropeladas.

### 5.9 Recentes

* `solis:sv:recent` grava em `player_spotify_recent` com `ON DUPLICATE KEY UPDATE` (chave única `passport + url`), mantendo a música uma única vez, com timestamp renovado.
* `recent` devolve as 12 últimas para a seção "Continue ouvindo".

### 5.10 Volume individual

* `localVolume` (0–1) e `muted` são persistidos em KVP (`solis_local_volume`, `solis_local_muted`).
* `ListenVol(base) = muted ? 0 : base * localVolume` — aplicado a **todos** os sons (fones, veículos, palcos).
* Slider e `/som` aplicam no mesmo frame em todos os sons ativos (sem esperar o próximo tick espacial).

### 5.11 Fones como prop

* Enquanto o jogador está no modo individual com uma faixa carregada (tocando **ou pausado**), o ped recebe o prop de ouvido — slot, drawable masculino e feminino vêm de `Config.Headphones` (padrão: slot 2, 41/22).
* Se o drawable não existir no ped, o console avisa uma vez (`ajuste Config.Headphones`) em vez de falhar calado.
* O prop anterior é salvo e restaurado ao parar, trocar de dispositivo ou no `onResourceStop`. Respawn/troca de personagem reaplica o fone no ped novo.

### 5.12 Integrações externas

* **Celular (`fphone2`)**: todo `SendNUIMessage` é espelhado com `TriggerEvent('fphone2:syncSpotifive', msg)`.
* **Ponte `spotifive`**: `spotifive:bridge:requestInit` devolve o `BootPayload`; `spotifive:bridge:handleAction` aceita `playMusic`, `controlMusic`, `setIndividualVolume`, `switchToHeadphones`.
* **Exports de telefone**: `PlayPhoneMusic`, `PausePhoneMusic`, `ResumePhoneMusic`, `SeekPhoneMusic`, `SetPhoneVolume`, `GetPhoneAudioState`, `GetIndividualVolume`, `SetIndividualVolume`.
* **Compatibilidade `xsound`**: exports de cliente e servidor com os mesmos nomes, mais o evento `solis:audio` (play/playpos/position/distance/destroy/pause/resume/volume/timestamp).

---

## 6. Motor de áudio (DUI)

### 6.1 Ciclo de vida da DUI

* Página criada com `CreateDui`, 1280×720, alternando entre duas formas a cada recriação:
  1. `https://cfx-nui-<recurso>/html/audio.html` (recomendada: contexto seguro, callbacks same-origin);
  2. `nui://<recurso>/html/audio.html` (algumas builds só carregam DUI por esse esquema).
* `CreateDuiText` é chamado se existir (nativo opcional de certas builds).
* A página envia `audio/ping` a cada **3 s**, com `boot: true` no primeiro envio.
* Recuperação automática:
  * **9 s** após criar a DUI sem nenhum ping → recria (até 12 tentativas, com log);
  * **14 s** sem ping depois de já ter funcionado → recria (crash do CEF, troca de resolução);
  * ao ficar pronta, `Audio.Sync()` reenvia **todo** o estado (play/pause, volume, distância, posição, tempo, muffle) — recriar nunca deixa música "presa".
* `onResourceStop` destrói a DUI.

### 6.2 Fachada `Audio.*` (client)

| Função | Efeito |
|---|---|
| `Audio.Play(id, url, vol, loop)` | Cria som não-posicional (fones, mídia direta). |
| `Audio.PlayPos(id, url, vol, pos, loop)` | Cria som posicional (`dynamic = true`). |
| `Audio.Pause` / `Resume` / `Seek` / `SetVolume` / `Distance` / `Position` / `Muffle` | Controles; atualizam o estado local e emitem mensagem. |
| `Audio.Time(id)` | Tempo derivado de `GetGameTimer` (sem consultar a DUI). |
| `Audio.Duration(id)` | Duração informada pela página. |
| `Audio.OnStart` / `OnEnd` | Callbacks disparados por `audio/ready` / `audio/ended`. |
| `Audio.Sync()` | Reenvia o estado completo. |
| `Audio.StopAll()` / `Count()` / `HasDynamic()` / `Exists()` / `Get()` | utilitários. |

### 6.3 Protocolo Lua → página

| `t` | Campos | Ação |
|---|---|---|
| `play` | `id, url, vol, loop, dynamic, x, y, z, dist, time, paused` | (Re)cria o som; **sempre recria** se já existir. |
| `stop` | `id` | Destrói mídia, grafo e watchers. |
| `pause` / `resume` | `id` | Pausa/retoma o backend atual. |
| `seek` | `id, time` | Salta (com `pendingSeek` se a mídia ainda não abriu). |
| `volume` | `id, vol` | Novo volume base (posicional recalcula). |
| `dist` | `id, dist` | Novo alcance. |
| `pos` | `id, x, y, z` | Nova posição da fonte. |
| `muffle` | `id, muffled, params` | Liga/desliga o lowpass e aplica perfil DSP. |
| `listener` | `x, y, z` | Posição do ouvinte; recalcula todos os dinâmicos. |
| `config` | `youtubePlayer, soundCloudWidget` | URLs das páginas/widget. |
| `scStream` / `scStreamFailed` | `id, result` | Resultado da resolução do stream do SoundCloud. |
| `muteAll` / `unmuteAll` | — | Mute global do motor. |

### 6.4 Protocolo página → Lua (callbacks NUI)

| Callback | Conteúdo |
|---|---|
| `audio/ping` | `boot`, `origin` (mostra em qual esquema o motor subiu). |
| `audio/ready` | `id` — mídia pronta (dispara `onStart`). |
| `audio/duration` | `id, time` — duração real. |
| `audio/ended` | `id` — fim de faixa (dispara `onEnd`). |
| `audio/failed` | `id, message` — falha de mídia (log + estado). |
| `audio/scStream` | `id, url` — o motor pede a resolução do stream do SoundCloud ao servidor. |

### 6.5 Backends de reprodução

**YouTube (local)** — `YT.Player` num `div` oculto (320×180, opacidade 0.01), com `playerVars.origin = 'https://www.youtube.com/'`. Esse `origin` é o que faz o embed tocar no CEF do FiveM, que não envia `Referer`. O estado é lido por polling de 1 s (`getPlayerState`, `getDuration`), porque com esse `origin` o `onStateChange` pode não disparar.

**YouTube (remoto)** — se `Config.Audio.YoutubePlayer` estiver preenchido, o motor usa um `iframe` para uma página https (por exemplo `html/player.html` servida em `https://cfx-nui-<recurso>/html/player.html`), com `referrerpolicy="strict-origin-when-cross-origin"`. A página hospeda o iframe do YouTube e conversa por `postMessage`:
* motor → página: `{ t:'yt', id, op:'play'|'pause'|'seek'|'vol', time, value }`;
* página → motor: `{ t:'yt', id, ev:'ready'|'state'|'error', state, duration, code }`.
* Se a página não responder em **9 s**, o som é recriado no modo local (nunca fica mudo).
* Erro **153** (Referer ausente) é tratado com até 3 recriações dentro do `player.html`.

**SoundCloud (direto)** — o motor pede `audio/scStream`; o servidor resolve:
1. `transcodings` **progressivo (MP3)** não-`snipped`;
2. senão **HLS**;
3. devolve `{ url, kind, duration }`.
O cliente toca num `<audio>` próprio com `crossOrigin="anonymous"` (MP3) ou via `hls.js` com `enableWorker: false` (HLS). Isso é o que permite o grafo Web Audio (lowpass) alcançar o áudio.

**SoundCloud (widget)** — fallback após **6 s** sem stream, erro de mídia no modo direto ou falha do HLS. O widget oficial toca, mas **sem DSP** (iframe cross-origin).

**HTML5 direto** — qualquer outra URL http(s) de mídia vira `<audio>` com CORS.

### 6.6 Grafo DSP (Web Audio)

```
<video>/<audio> ──► peaking (bassFreq, bassQ, gain) ──► lowpass #1 (cutoff, resonance)
                ──► lowpass #2 (cutoff, Q 0.7) ──► analyser (fftSize 1024) ──► destination
```

* `createMediaElementSource` só pode ser chamado **uma vez por elemento**; o motor guarda os elementos já ligados num `WeakSet` e recria a cadeia quando o elemento muda (troca de faixa).
* Se o elemento ainda não existe (iframe do YouTube demorando), há retry a cada 250 ms por até 40 tentativas.
* `updateFilter` usa `setTargetAtTime` com `smooth` (0.12) — sem estalos ao abrir/fechar o carro.
* **Watchdog**: a cada 500 ms mede RMS no `analyser`. Se há silêncio digital (RMS < 0.0005) **e** o tempo da mídia avança, por 8 ciclos seguidos, o roteamento Web Audio é descartado (`dropFilter`) e a mídia é recriada sem filtro. Buffering e pausa não contam, porque o tempo não avança.
* Se a mídia ficar "tainted" (servidor sem CORS), o som é reaberto sem `crossOrigin` — toca, mas sem filtro.

### 6.7 Volume e espacialização

```lua
dynamic = false → volume = vol
dynamic = true  → d = distância(ouvinte, fonte)
                  fora do alcance (d >= dist) → 0
                  dentro → vol * (1 - d/dist)^1.2
allMuted → 0
```

* Posição do ouvinte é enviada a cada `Config.Audio.Refresh` (100 ms) **somente** quando existe som dinâmico, e apenas se o jogador andou `Moved` (0.25 m).
* A posição de cada fonte é atualizada quando muda mais de 0.5 m.
* O volume de cada `<audio>` é escrito direto; o widget do SoundCloud e o player do YouTube usam escala 0–100.

---

## 7. Áudio espacial e DSP

### 7.1 Alcances e perfis

| Situação | Alcance | Volume extra | Filtro |
|---|---:|---|---|
| Veículo com porta/vidro aberto | 60 m (`VehicleOpen`) | — | não |
| Veículo fechado (fora dele) | 4 m (`VehicleClosed`) | `MuffledVolume` (0.95) | sim |
| Motocicleta (classes 8 e 13) | 6 m (`Motorbike`) | — | não |
| Dentro do veículo | ∞ (1000) | volume cheio | não |
| Palco | `stage.radius` | — | não |
| Boombox | — | — | **declarado, sem uso no código atual** |

`ShouldMuffle` só é verdadeiro quando: o jogador **não** está no veículo, **não** é moto e **não** há porta/vidro aberto.

### 7.2 Perfis de filtro (`Config.VehicleFilter`)

| Perfil | Cutoff | Resonance | BassFreq | BassGain | BassQ | Smoothing |
|---|---:|---:|---:|---:|---:|---:|
| `leve` | 420 Hz | 1.6 | 100 Hz | 7 dB | 1.4 | 0.12 |
| `medio` (padrão) | 260 Hz | 2.4 | 95 Hz | 10 dB | 1.7 | 0.12 |
| `forte` | 150 Hz | 4.0 | 90 Hz | 13 dB | 1.5 | 0.12 |

### 7.3 Gerenciador espacial do cliente

* Loop com `sleep = 0` (todo frame) **enquanto** houver qualquer som de veículo/palco ativo; `Wait(1000)` caso contrário.
* Por som, guarda um cache (`vol`, `dist`, `muffled`, `pos`, `at`) e só envia mensagem quando o valor muda; o muffle é reenviado a cada `MuffleRefresh` (4 s) como *keepalive*.
* Veículo que deixa de existir acumula `misses`; após **20** ciclos o som é destruído e o rastreio liberado. (O `Config.Audio.TrackingMaxMisses` existe, mas o valor usado é 20 fixo — ver §17.)
* `ApplyControlVolume` aplica volume de controle **na hora**, sem esperar o tick — antes havia ~300 ms de atraso em cada ajuste de slider.
* Fechar porta/vidro responde no mesmo frame: é por isso que o tick é 0 ms com som aberto.

---

## 8. Interface (NUI)

### 8.1 Views

| View | Conteúdo |
|---|---|
| `home` | Hero "tocando agora", **Continue ouvindo** (recentes) e grade de playlists. |
| `search` | Resultados mistos, com botão **Importar** para salvar o resultado como playlist. |
| `playlist` | Cabeçalho (nome, metadados, AirDrop, Convidar, Tocar), lista paginada com *scroll* infinito (`row-sentinel`) e menu de contexto. |
| `bluetooth` | "Meus dispositivos" e "Outros dispositivos", com estado de conexão e faixa atual; atualiza a cada 5 s enquanto aberta. |
| `sessions` | Sessões ativas do jogador + Jams, com limite exibido. |
| `jam` | Código, anfitrião, copiar, convidar, encerrar, lista de membros. |

### 8.2 Player e controles

* Barra inferior: capa, título, dispositivo, aviso de "fora de alcance", seek, shuffle, anterior, play/pause, próxima, repetir, mute e volume.
* Atalhos: `Esc` fecha camadas/menu/painel; `Espaço` toca/pausa; `←`/`→` movem 5 s.
* Toasts (`success`, `warning`, `error`, `info`) e prompt `Y`/`U` para pedidos de Bluetooth/AirDrop/colaboração.

### 8.3 Mensagens NUI (`type`)

`visibility`, `toast`, `queue`, `progress`, `focus`, `sessions`, `playlists`, `playlistTrack`, `localVolume`, `prompt`, `jam`, `jamEvent`, `jamPlayback`, `range`.

---

## 9. Rede: eventos e callbacks

### 9.1 Callbacks NUI → cliente (principais grupos)

| Grupo | Callbacks |
|---|---|
| Sessão/player | `boot`, `ready`, `close`, `play`, `control`, `queue`, `repeat`, `shuffle`, `volumeLocal`, `headphones` |
| Sessões | `sessions`, `sessionsFocus`, `sessionsLeave` |
| Bluetooth | `bluetooth`, `bluetoothConnect`, `bluetoothAuto`, `bluetoothForget` |
| Playlists | `playlists`, `playlistSongs`, `playlistQueue`, `playlistCreate`, `playlistDelete`, `playlistAdd`, `playlistMove`, `playlistRemove`, `airdropSend`, `collabInvite`, `nearbyPlayers`, `recent` |
| Jam | `jamCreate`, `jamJoin`, `jamLeave`, `jamEnd`, `jamKick`, `jamAllow`, `jamInvite`, `jamCode` |
| Catálogo | `scSearch`, `scResolve`, `spotifySearch`, `spotifyLink`, `spotifyBatch`, `ytFallback` |
| Motor | `audio/ping`, `audio/ready`, `audio/duration`, `audio/ended`, `audio/failed`, `audio/scStream` |

Chamadas NUI→servidor que precisam de retorno usam a ponte (`Server.sessions()`, `Server.connect(...)`, etc. → eventos `solis_sound:bridge:req` / `solis_sound:bridge:res`, com timeout de 20 s); as demais usam `TriggerServerEvent` + evento de resposta.

### 9.2 Eventos cliente → servidor

| Evento | Payload | Validação |
|---|---|---|
| `solis:sv:interest` | `vehicles[], stages[]` | rate limit; teto de 96 netIds; só sessões existentes. |
| `solis:sv:play` | `sessId, url, vol, time, title, thumb, queue, queueIndex` | sessão existe + `CanControl` + URL segura. |
| `solis:sv:control` | `sessId, action, value` | `CanControl`; `pause/resume/seek/volume/stop`. |
| `solis:sv:ended` | `sessId` | **não é emitido pelo cliente atual** (ver §17). |
| `solis:sv:answer` | `id, accepted` | só o dono do pedido responde. |
| `solis:sv:recent` | `song` | passaporte + payload sanitizado. |
| `solis:sv:scSearch` / `scResolve` / `scStream` | consulta/URL/faixa | rate limit. |
| `solis:sv:spotifySearch` / `spotifyLink` / `spotifyBatch` | consulta/link/faixas | rate limit. |
| `solis:sv:ytFallback` | `kind, query/videoId/playlistId` | rate limit + cache 5 min. |
| `solis:sv:playlistCreate/Delete/Add/Move/Remove` | … | permissão de escrita + posse/colaboração. |
| `solis:sv:playlistAirdrop` / `playlistInvite` | `id, passport` | dono/colaborador + jogador online. |
| `solis:sv:jam` / `jamLeave` / `jamInvite` | `code, action, data` | membro + regra de controle. |

### 9.3 Eventos servidor → cliente

| Evento | Quando |
|---|---|
| `solis:cl:play` | Alguém começou/trocou faixa numa sessão (usuários + watchers). |
| `solis:cl:control` | Pause/resume/seek/volume — **broadcast `-1`**, clientes sem o som ignoram. |
| `solis:cl:sessionEnded` | Sessão morreu (sem ouvintes, veículo sumiu). |
| `solis:cl:sessionLeft` | O jogador saiu de uma sessão que continua viva. |
| `solis:cl:granted` / `denied` | Resposta de pareamento. |
| `solis:cl:sessions` / `playlists` / `playlistTrack` | Atualizações de estado/lista. |
| `solis:cl:prompt` | Pedido de aceite (Bluetooth, AirDrop, colaboração). |
| `solis:cl:toast` | Mensagem de feedback. |
| `solis:cl:jam*` | Membros, eventos, convite, playback, encerramento. |
| `solis:audio` | Compatibilidade `xsound` (server → client). |
| `solis:audio:scStream` | Resultado do stream direto do SoundCloud. |

---

## 10. Banco de dados

### 10.1 Tabelas (criadas automaticamente)

O recurso cria as tabelas **1 s após o start** (`CreateThread` + `Wait(1000)`), com `IF NOT EXISTS`:

```sql
CREATE TABLE IF NOT EXISTS player_playlists (
    id INT NOT NULL AUTO_INCREMENT,
    passport VARCHAR(64) NOT NULL,
    name VARCHAR(100) NOT NULL,
    songs LONGTEXT NOT NULL,
    collaborators LONGTEXT NOT NULL DEFAULT '[]',
    song_count INT NOT NULL DEFAULT 0,
    thumb VARCHAR(512) NOT NULL DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_passport (passport)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS player_playlist_members (
    playlist_id INT NOT NULL,
    passport VARCHAR(64) NOT NULL,
    PRIMARY KEY (playlist_id, passport),
    KEY idx_passport (passport)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS player_spotify_recent (
    id INT NOT NULL AUTO_INCREMENT,
    passport VARCHAR(64) NOT NULL,
    url VARCHAR(255) NOT NULL,
    title VARCHAR(255) NOT NULL,
    thumb VARCHAR(512) NOT NULL,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY unique_song (passport, url),
    KEY idx_recent (passport, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS player_bluetooth_paired (
    id INT NOT NULL AUTO_INCREMENT,
    passport VARCHAR(64) NOT NULL,
    plate VARCHAR(20) NOT NULL,
    device_name VARCHAR(100) NOT NULL,
    authorized TINYINT(1) DEFAULT 1,
    auto_reconnect TINYINT(1) DEFAULT 1,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY unique_pair (passport, plate)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

`passport` é o **id da base, sempre em texto**: passaporte numérico no vRP, `citizenid` no QBCore, `identifier` no ESX. Instalações anteriores (coluna `INT`) são alargadas para `VARCHAR(64)` automaticamente na primeira inicialização, sem perder dados.

### 10.2 Papel de cada tabela

| Tabela | Conteúdo | Chave de acesso |
|---|---|---|
| `player_playlists` | Playlist completa em **JSON** (`songs`), com `song_count` e `thumb` desnormalizados para a lista. | `passport` (dono) + `player_playlist_members` (colaboradores). |
| `player_playlist_members` | Fonte de verdade dos colaboradores (N:N). | `playlist_id + passport` (PK). |
| `player_spotify_recent` | Histórico de faixas tocadas (12 exibidas). | `passport + url` (único). |
| `player_bluetooth_paired` | Pareamentos por placa, com `auto_reconnect`. | `passport + plate` (único). |

### 10.3 Formato de `songs`

```json
[
  {
    "url": "https://www.youtube.com/watch?v=XXXXXXXXXXX",
    "title": "Nome da faixa",
    "thumb": "https://...",
    "provider": "youtube | soundcloud | spotify",
    "spId": "id do Spotify (somente em linhas de importação)",
    "artist": "Artista (somente em linhas de importação)",
    "pending": false,
    "failed": false
  }
]
```

* `provider` é sempre normalizado (`soundcloud` ou `youtube`; `spotify` é preservado como selo).
* O caminho comum de gravação (`SongPayload`) persiste **apenas** `url`, `title`, `thumb` e `provider`. `artist`, `spId`, `pending` e `failed` aparecem nas linhas criadas pela importação do Spotify (`SpImportCreate`/`SpPatchSong`).
* Linhas `pending: true` são placeholders de importação do Spotify, substituídas em background.
* Ao ler para a fila, o servidor revalida cada item (`SongPayload`): URL http(s) válida, título até 160, thumb até 512.

### 10.4 Migrações

A thread de migração é **sequencial e tolerante a falhas parciais**:

1. Cria as 4 tabelas.
2. Para cada upgrade (`collaborators`, `song_count`, `thumb`, `updated_at`, `auto_reconnect`), espera a tabela existir (`WaitForTable`, até 40 tentativas de 250 ms), confere em `information_schema.columns` e só então roda o `ALTER TABLE`.
3. Cada `ALTER` avança a fila **no callback** (ou após 8 s de timeout). Isso é essencial: `oxmysql` despacha queries em paralelo, e um `UPDATE` disparado junto com o `ALTER` chegaria antes da coluna existir.
4. Backfill único (KVP `members_backfill = "2"`): converte `collaborators` (JSON legado) em linhas de `player_playlist_members`.
5. Recalcula `song_count` (`JSON_LENGTH`) e `thumb` (`JSON_EXTRACT(songs,'$[0].thumb')`).

### 10.5 Escritas e caches

* `SaveSongs` reescreve o JSON inteiro — simples e consistente para até 500 faixas.
* `SyncCollaborators` mantém a coluna legada `collaborators` espelhando a tabela de membros.
* Caches em memória:
  * `PlaylistCache[passport]` — 30 s, invalidado por `BustPlaylist`;
  * `Names[passport]` — 300 s (com reset ao passar de 4000 entradas);
  * `Plates[plate]` — 120 s;
  * `PairCache[passport]` — por sessão, mantido em sincronia nas alterações.
* Escritas são limitadas por jogador: **6 por 10 s** (`Config.RateLimit.Writes`).

---

## 11. Escalabilidade e desempenho

### 11.1 O que já é escalável por design

* **Interesse em vez de broadcast global**: reprodução só vai para `users` + `watchers` daquela sessão. Um jogador a 500 m não recebe pacote nenhum daquela música.
* **Heartbeat**: o cliente só fala quando o conjunto de interesse muda ou a cada 5 s — não há tráfego por frame.
* **Sem polling de áudio**: tempo é derivado de timers locais; a DUI não é consultada a cada tick.
* **Fanout com deduplicação**: `Fanout` monta um `set` de destinatários (usuários + watchers) e envia uma vez por `src`.
* **Cache de catálogo**: YouTube público 5 min por chave de consulta; listas de playlist 30 s; token do Spotify reaproveitado até ~2 min antes de expirar.
* **Limites duros**: 3 sessões por jogador, 2 ouvintes por veículo, 64 por palco, 96 veículos por mensagem de interesse, 250 faixas por fila, 500 por playlist, 60 playlists por passaporte.
* **Rate limit**: 600 mensagens de controle e 6 escritas por 10 s por jogador.

### 11.2 Custos por jogador / por sessão

| Recurso | Custo |
|---|---|
| Varredura de interesse | `GetGamePool('CVehicle')` a cada 500 ms no cliente (CPU local). |
| Tick espacial | 0 ms enquanto houver som de veículo/palco ativo (CPU local, por frame). |
| Servidor | `Sessions`, `Watchers`, `Interests`, `Jams`, `Pending` em memória — dezenas de bytes por entrada. |
| Monitor de veículos | Thread de 5 s percorrendo sessões de veículo. |
| DUI | Uma página CEF por jogador, com 1 grafo Web Audio por som ativo. |
| HTTP | Somente em busca/importação; nunca no caminho de reprodução. |

### 11.3 Pontos de saturação e o que fazer

1. **`solis:cl:control` usa `-1`.** É um pacote por jogador por ação (pause, seek, volume). O slider de volume só emite ao soltar/alterar de forma controlada, mas em picos (muitos DJs ajustando volume ao mesmo tempo) isso é O(N). *Mitigação:* trocar por envio apenas a `users + watchers` da sessão, com o cliente já sabendo que ignora o resto.
2. **`GetGamePool('CVehicle')` a cada 500 ms** em cada cliente é o maior custo de CPU local em cidades cheias. *Mitigação:* varrer só entidades próximas via `GetClosestVehicle`/grid, ou aumentar `ScanInterval` em servidores com 200+ jogadores.
3. **Estado só em memória.** Reinício do recurso/servidor derruba todas as sessões e Jams. Para múltiplos servidores (grid), seria necessário estado compartilhado (Redis/DB) e um barramento de eventos — não implementado.
4. **JSON de playlist reescrito por inteiro.** Com 500 faixas, cada add/remove regrava o documento completo. Aceitável no limite atual; acima disso, normalizar em `playlist_songs`.
5. **Threads por frame** no cliente com som aberto (sleep 0). É intencional (resposta imediata de porta/vidro), mas limita o número de clientes por máquina em cenários de muitos sons simultâneos no mesmo raio.

### 11.4 Dimensionamento prático

* **Até ~100 jogadores**: configuração padrão é confortável; o gargalo é o CEF de cada cliente, não o servidor.
* **100–200**: considerar `InterestRadius` 70–80, `InterestMaxVehicles` 64, `ScanInterval` 750 ms.
* **200+**: revisar o broadcast `-1` do controle, migrar caches de nome/placa para storage compartilhado e separar o catálogo (HTTP) em um worker.

---

## 12. Segurança

### 12.1 O que o servidor valida

* **URLs**: `SafeUrl` aceita apenas `http(s)` e um conjunto restrito de caracteres; rejeita acima de `MaxUrl` (512) ou `MaxThumb` (512).
* **Texto**: `Trim` remove caracteres de controle, espaços nas pontas e corta no limite (`MaxTitle` 160, `MaxPlaylistName` 80).
* **Números**: `Clamp` limita volume a 0–1 e tempo a 0–86400.
* **Filas**: `TrimQueue` limita a 250 itens, valida cada URL e normaliza `provider`.
* **Autorização de controle**: `CanControl` = controlador, ou (palco) quem está a `radius + 25 m` do palco — distância medida **no servidor**.
* **Conexão**: palco existente; veículo existente e a até 25 m; lotação; limite de sessões; dono/motorista/pareado para entrar sem aprovação.
* **Pedidos**: só o destinatário (`request.owner == src`) pode aceitar/recusar; pedidos pendentes são limpos no `playerDropped`.
* **Propriedade**: o id vem de `Bridge.GetId(src)` (passaporte no vRP, citizenid no QBCore, identifier no ESX) — nunca do cliente. Dono do veículo vem de `state.Passport` da entidade ou `Bridge.GetPlateOwner` (com cache de 120 s).
* **Rate limit**: baldes por `src` para ações e escritas.
* **Escritas em playlist**: `PlaylistRow` exige posse ou participação; convidar exige ser o criador.

### 12.2 Riscos e recomendações

| Risco | Situação | Recomendação |
|---|---|---|
| **Credenciais em `config.lua`** | `Config.YoutubeAPIKey`, `Config.Spotify.ClientId` e **`ClientSecret`** estão em texto plano no repositório. | Rotacionar as chaves, remover o `ClientSecret` do controle de versão e carregar de variável de ambiente/secret do servidor. |
| **Chave do YouTube vai para a NUI** | Necessário para a busca direta na Data API; qualquer jogador pode lê-la no CEF. | Restringir a chave por referrer/quota no Google Cloud ou operar **sem chave**, usando só o `ytFallback` do servidor. |
| **Broadcast `-1` no controle** | Pacotes de controle vão a todos, que ignoram sessões desconhecidas. | Migrar para fanout por sessão se houver abuso ou escala. |
| **Jam por código** | Quem tem o código entra; não há senha. | Aceitável para uso social; adicionar senha/convite-only se necessário. |
| **Nome do veículo vem do cliente** | Usado apenas como rótulo (`device.name`, 60 chars). | Já sanitizado; não afeta autorização. |
| **Sessões voláteis** | Reinício derruba tudo. | Aceitável (áudio é efêmero); documentar para staff. |

---

## 13. Referência de configuração

### 13.1 Framework

| Chave | Padrão | Efeito |
|---|---|---|
| `Config.Framework` | `'auto'` | Base do servidor: `'vrp'`, `'qbcore'`, `'esx'`, `'standalone'` ou `'auto'` (detecta na ordem vrp → qbcore → esx → standalone). |
| `Config.FrameworkOptions.vrp.resource` | `'vrp'` | Pasta do vRP. Em qualquer distro (solis, zirix) o recurso é montado como `vrp`. |
| `Config.FrameworkOptions.qbcore.resource` | `'qb-core'` | Pasta do QBCore. |
| `Config.FrameworkOptions.esx.resource` | `'es_extended'` | Pasta do ESX. |
| `Config.FrameworkVehicles.qbcore` | `{ player_vehicles, citizenid, plate }` | Tabela/colunas do garage para achar o dono do veículo. |
| `Config.FrameworkVehicles.esx` | `{ owned_vehicles, owner, plate }` | Idem para ESX. |
| `Config.FrameworkVehicles.standalone` | `false` | Sem framework não há tabela de dono; só o `state.Passport` da entidade. |

O contrato que cada base implementa é pequeno e vive em `bridge/frameworks/<base>.lua`:

| Função | Contrato |
|---|---|
| `activate()` | Devolve a interface da base (ou `nil, motivo`). |
| `getId(src)` | Id do jogador (texto após normalização). |
| `getName(id)` | Primeiro nome exibido como dono do veículo. |
| `getSource(id)` | `src` online do id, ou `nil`. |
| `getPlateOwner(plate)` | Opcional; sem ela a ponte usa `Config.FrameworkVehicles`. |

### 13.2 Catálogo

| Chave | Padrão | Efeito |
|---|---|---|
| `Config.YoutubeAPIKey` | string | Chave da YouTube Data API v3 usada pela NUI e pela resolução do Spotify. Vazia → só fallback público. |
| `Config.SoundCloud.Enabled` | `true` | Liga busca/resolução do SoundCloud. |
| `Config.SoundCloud.ApiBase` | `https://api-v2.soundcloud.com` | Base da API interna. |
| `Config.SoundCloud.SiteUrl` | `https://soundcloud.com` | Usada no header `Origin`. |
| `Config.SoundCloud.WidgetUrl` | `https://w.soundcloud.com/player/` | Widget de fallback. |
| `Config.SoundCloud.ClientId` | string | `client_id` extraído do bundle do site; **expira** e precisa ser atualizado em caso de 401. |
| `Config.SoundCloud.SearchLimit` | `18` | Resultados por busca. |
| `Config.Spotify.Enabled` | `true` | Liga o catálogo Spotify. |
| `Config.Spotify.ClientId` / `ClientSecret` | string | Credenciais do app (client credentials). |
| `Config.Spotify.ApiBase` / `TokenUrl` | URLs oficiais | Endpoints. |
| `Config.Spotify.Market` | `BR` | Mercado das buscas. |
| `Config.Spotify.SearchLimit` | `18` | Resultados por busca. |
| `Config.Spotify.PlaylistLimit` | `250` | Máximo de faixas importadas por playlist. |
| `Config.Spotify.Resolver` | `youtube` | Preferência de resolução (`youtube` ou `soundcloud`); o outro é fallback. |
| `Config.Spotify.ResolveDelay` | `120` | Pausa (ms) entre faixas na importação em background. |

### 13.3 Áudio e volume

| Chave | Padrão | Efeito |
|---|---|---|
| `Config.VolumeMulti` | `2.0` | **Não usado no código atual.** |
| `Config.Distances.Boombox` | `15.0` | **Não usado no código atual.** |
| `Config.Distances.VehicleOpen` | `60.0` | Alcance com porta/vidro aberto. |
| `Config.Distances.VehicleClosed` | `4.0` | Alcance com carro fechado. |
| `Config.Distances.Motorbike` | `6.0` | Alcance de moto. |
| `Config.MuffledVolume` | `0.95` | Atenuação extra fora do carro fechado. |
| `Config.VehicleFilter.Profile` | `"medio"` | Perfil de lowpass ativo. |
| `Config.VehicleFilter.Profiles` | 3 perfis | `cutoff`, `resonance`, `bassFreq`, `bassGain`, `bassQ`, `smoothing`. |
| `Config.Audio.Refresh` | `100` | Intervalo de envio da posição do ouvinte (ms). |
| `Config.Audio.Moved` | `0.25` | Distância mínima para reenviar posição (m). |
| `Config.Audio.MuffleRefresh` | `4000` | Reenvio do estado do filtro (ms). |
| `Config.Audio.TrackingMaxMisses` | `1200` | **Declarado, mas não usado** (o código usa 20). |
| `Config.Audio.YoutubePlayer` | `''` | Vazio → `https://cfx-nui-<recurso>/html/player.html`. Preencha para usar outro domínio https. |
| `Config.Headphones.Enabled` | `true` | Liga o acessório de fone no ouvido no modo "fones individuais" (tocando ou pausado). |
| `Config.Headphones.Prop` | `2` | Slot de prop do fone (`2` = orelha). |
| `Config.Headphones.Male` / `Female` | `41` / `22` | Drawables do ped freemode. O script avisa no console se o drawable não existir no ped. |

### 13.4 Limites e rede

| Chave | Padrão | Efeito |
|---|---|---|
| `Limits.MaxSessions` | `3` | Sessões simultâneas por jogador. |
| `Limits.MaxQueue` | `250` | Faixas por fila. |
| `Limits.MaxPlaylists` | `60` | Playlists por passaporte. |
| `Limits.MaxSongsPerPlaylist` | `500` | Faixas por playlist. |
| `Limits.MaxPlaylistName` | `80` | Nome da playlist. |
| `Limits.MaxTitle` | `160` | Título de faixa. |
| `Limits.MaxUrl` | `512` | URL de mídia. |
| `Limits.MaxThumb` | `512` | URL de capa. |
| `Limits.MaxStageListeners` | `64` | Ouvintes por palco. |
| `Net.InterestRadius` | `90.0` | Raio da varredura de veículos (m). |
| `Net.InterestMaxVehicles` | `96` | Teto de netIds por mensagem. |
| `Net.ScanInterval` | `500` | Intervalo da varredura (ms). |
| `Net.Heartbeat` | `5000` | Reenvio do interesse sem mudança (ms). |
| `Net.SessionPoll` | `15000` | Reconciliação da lista de sessões com painel aberto (ms). |
| `Net.RangeWarn` | `25.0` | Distância para marcar "fora de alcance" (m). |

### 13.5 Bluetooth, Jam e anti-flood

| Chave | Padrão | Efeito |
|---|---|---|
| `Bluetooth.ScanRadius` | `12.0` | Raio de descoberta de veículos (m). |
| `Bluetooth.PairLimit` | `80` | Pareamentos por passaporte. |
| `Jam.MaxMembers` | `24` | Membros por Jam. |
| `Jam.AnyoneCanControl` | `false` | `false` = o anfitrião libera cada membro pelo botão "Dar controle"; `true` = todos que entram já controlam. |
| `RateLimit.Actions` | `600` | Mensagens de controle por janela. |
| `RateLimit.Writes` | `6` | Escritas em banco por janela. |
| `RateLimit.Window` | `10000` | Janela em ms. |

### 13.6 Palcos

```lua
Config.Stages["beach_party"] = {
    label  = "Beach Party",
    coords = vector3(-1524.45, -1487.74, 6.9),
    radius = 80.0,
    mapBlip = { enable = true, sprite = 484, color = 4, scale = 0.8, name = "Festa na Praia" },
    marker  = { enable = true, type = 1, color = { r = 29, g = 185, b = 84, a = 100 },
                scale = { x = 1.5, y = 1.5, z = 0.5 }, drawDist = 80.0 }
}
```

* A chave é o `stageId` (aparece em `sessId = "stage_<chave>"`).
* `radius` define o alcance do som e o limite de proximidade para controlar.
* `mapBlip` desenha o ícone no radar; `marker` desenha o marcador 3D até `drawDist` metros.

---

## 14. Instalação e operação

### 14.1 Requisitos

* FiveM server (artifacts recentes; o recurso usa DUI, `CreateDuiText` opcional, `RegisterKeyMapping`).
* Uma das bases em `Config.Framework`: **vRP** (solis, zirix e derivados — usa `Passport`, `Identity`, `PassportPlate`, `Source`; o lib é carregado na hora, nada de `@vrp` no manifesto), **QBCore** (`GetCoreObject`, `citizenid`), **ESX Legacy** (`getSharedObject`, `identifier`) ou **standalone** (licença do jogador). Só a base escolhida é exigida.
* `oxmysql` configurado e funcionando.
* Acesso de rede de saída do servidor para `youtube.com`, `googleapis.com`, `api-v2.soundcloud.com`, `accounts.spotify.com`, `api.spotify.com` e `w.soundcloud.com`.

### 14.2 Ordem no `server.cfg`

```cfg
ensure oxmysql
ensure vrp          # ou qb-core / es_extended (ou nada, em standalone)
ensure solis_sound
```

### 14.3 Primeiro start

1. As tabelas são criadas automaticamente após 1 s; não é necessário rodar SQL manual.
2. As migrações conferem coluna por coluna — pode rodar sobre um banco antigo (`som`/versões anteriores) sem perder dados.
3. Faça login, use `/som` para abrir o painel e teste uma busca.
4. Verifique o console: `[solis_sound] motor de áudio pronto. (https://cfx-nui-...)` indica DUI saudável. Se aparecer `motor de áudio sem resposta; recriando`, veja §16.

### 14.4 Arquivos que precisam estar em `files`

`html/index.html`, `html/style.css`, `html/app.js`, `html/audio.html`, `html/audio.js`, `html/hls.min.js`, `html/player.html`. Sem qualquer um deles o motor não sobe ou o fallback do YouTube não funciona.

### 14.5 Operação

* Reiniciar o recurso derruba sessões, Jams e caches (o banco permanece).
* `solis_sound` não usa comandos administrativos; a staff controla por `restart`/`ensure`.
* Os KVPs do cliente (`solis_local_volume`, `solis_local_muted`) são por jogador e por máquina.
* O KVP `members_backfill` é do **servidor** e marca a migração de colaboradores como concluída.

---

## 15. API pública

### 15.1 Exports de cliente (telefone / outros recursos)

```lua
exports.solis_sound:PlayPhoneMusic(url, title, thumb)
exports.solis_sound:PausePhoneMusic()
exports.solis_sound:ResumePhoneMusic()
exports.solis_sound:SeekPhoneMusic(time)
exports.solis_sound:SetPhoneVolume(0.0..1.0)
exports.solis_sound:GetPhoneAudioState()  -- { playing, currentTime, duration, volume, mode, device }
exports.solis_sound:GetIndividualVolume() -- localVolume, muted
exports.solis_sound:SetIndividualVolume(0.0..1.0)
```

### 15.2 Motor de áudio (compatível com `xsound`)

Cliente:

```lua
exports.solis_sound:PlayUrl(id, url, volume, loop)
exports.solis_sound:PlayUrlPos(id, url, volume, pos, loop)
exports.solis_sound:Destroy(id)
exports.solis_sound:Pause(id)
exports.solis_sound:Resume(id)
exports.solis_sound:setVolume(id, volume)
exports.solis_sound:setVolumeMax(id, volume)
exports.solis_sound:Distance(id, distance)
exports.solis_sound:Position(id, pos)
exports.solis_sound:setTimeStamp(id, time)
exports.solis_sound:getTimeStamp(id)
exports.solis_sound:getMaxDuration(id)
exports.solis_sound:soundExists(id)
exports.solis_sound:isPlaying(id)
exports.solis_sound:onPlayEnd(id, fn)
exports.solis_sound:onPlayStart(id, fn)
exports.solis_sound:setMuffled(id, on, params)
```

Servidor (envia para um `src` específico):

```lua
exports.solis_sound:PlayUrl(src, id, url, volume, loop)
exports.solis_sound:PlayUrlPos(src, id, url, volume, pos, loop)
exports.solis_sound:Position(src, id, pos)
exports.solis_sound:Distance(src, id, distance)
exports.solis_sound:Destroy(src, id)
exports.solis_sound:Pause(src, id)
exports.solis_sound:Resume(src, id)
exports.solis_sound:setVolume(src, id, volume)
exports.solis_sound:setTimeStamp(src, id, time)
exports.solis_sound:DestroyAll(src)   -- emite 'destroyall' (ver §17)
```

### 15.3 Comandos

| Comando | Efeito |
|---|---|
| `/som` | Abre/fecha o painel. |
| `/som 0-100` | Define o volume individual em %. |
| `/som on` / `/som off` | Restaura/muta o volume individual. |
| `/som1 ...` | Alias de `/som`. |
| `Y` / `U` (keymapping) | Aceitar / recusar pedidos (Bluetooth, AirDrop, colaboração). |

---

## 16. Solução de problemas

| Sintoma | Causa provável | Correção |
|---|---|---|
| Nenhum som, console com `motor de áudio sem resposta; recriando` | `html/audio.html` ou `html/audio.js` fora de `files`, ou CEF não carregou a DUI. | Conferir `fxmanifest.files`; reiniciar o recurso; ver a mensagem final `motor de áudio não carregou`. |
| Motor pronto mas sem áudio no YouTube (erro 153) | CEF sem `Referer`. | Deixar `Config.Audio.YoutubePlayer = ''` (usa `player.html` em `https://cfx-nui-...`) ou apontar para uma página https própria. |
| Música toca, mas o filtro do carro não abafa | Elemento de mídia cross-origin (widget) ou WebAudio desativado. | Preferir SoundCloud por stream direto; ver logs `Web Audio LPF`. O widget é fallback sem DSP por design. |
| Filtro "morre" depois de um tempo | Watchdog detectou silêncio digital e desativou o grafo (CORS). | Normal; o som volta limpo. Se acontecer sempre, o servidor de mídia não envia CORS. |
| Busca do SoundCloud retorna 401 | `client_id` expirado. | Atualizar `Config.SoundCloud.ClientId` com o valor atual do bundle do site. |
| Busca do YouTube para de funcionar | Cota diária da Data API esgotada. | O fallback público assume automaticamente; se nem ele responder, checar saída de rede do servidor. |
| Spotify não aparece | `Enabled = false` ou credenciais vazias. | Preencher `ClientId`/`ClientSecret` e reiniciar. |
| Faixas do Spotify não tocam | Resolução falhou (`failed: true`). | Verificar `Config.Spotify.Resolver` e conectividade com YouTube/SoundCloud; reimportar. |
| Não consigo entrar no carro de outra pessoa | Não é dono/motorista nem pareado. | Pedir pareamento; o dono precisa aceitar com `Y` (e estar online). |
| "Dispositivo ocupado no momento" | Limite de 2 ouvintes por veículo. | Sair de outra sessão ou usar palco. |
| "Você está longe do palco" | Distância > `radius + 25 m` (medida no servidor). | Aproximar-se. |
| Painel abre vazio | CEF subiu depois do comando. | A NUI envia `ready` e recebe o boot; se persistir, fechar e reabrir com `/som`. |
| Sessão sumiu após restart | Sessões e Jams são só memória. | Comportamento esperado. |
| Playlists não aparecem | Banco indisponível ou migração incompleta. | Conferir logs do `oxmysql` e a existência das 4 tabelas. |

---

## 17. Limitações conhecidas e dívida técnica

Levantadas diretamente do código atual — úteis antes de refatorar:

1. **`Config.VolumeMulti` não é usado.** Ficou de uma versão anterior do cálculo de volume.
2. **`Config.Distances.Boombox` não é usado.** Não existe hoje lógica de boombox.
3. **`Config.Audio.TrackingMaxMisses` não é lido.** O gerenciador espacial usa `20` ciclos fixos; o comentário da config fala em 1200.
4. **`solis:sv:ended` nunca é emitido.** O cliente avança a fila localmente (`MaybeTrackEnded`), então o handler do servidor é código morto.
5. **`DestroyAll` (server) emite `destroyall`**, mas o cliente não trata esse estado em `solis:audio` — o export não tem efeito prático.
6. **Sessões, Jams e watchers são voláteis** (memória). Não há persistência nem compartilhamento entre servidores.
7. **`player_spotify_recent.url` é `VARCHAR(255)`**, enquanto `MaxUrl` aceita 512. URLs muito longas podem ser truncadas/rejeitadas na gravação de recentes.
8. **Importação do Spotify deixa placeholders** (`pending`) quando a resolução falha; eles ficam no JSON com `failed: true` e não tocam.
9. **Jam é "cada um toca localmente"** (`mode = 'own'`). A sincronia depende do relógio de cada cliente e do momento em que a faixa é resolvida; não há correção de drift.
10. **Sem foreign keys/cascade.** A exclusão de playlist e membros é feita em duas queries no código; uma falha entre elas pode deixar membros órfãos.
11. **`html/yt.html` não está no manifesto.** Está no diretório, mas não é servido por este recurso.
12. **A única porta de entrada do painel é `/som`.** Não há evento/exports de "abrir UI" para outros recursos.
13. **Credenciais em `config.lua`** (incluindo o `ClientSecret` do Spotify) — ver §12.2.

### Melhorias de maior retorno

* Remover o `-1` de `solis:cl:control` e enviar só para `users + watchers`.
* Tornar o tick espacial adaptativo (0 ms só quando o estado realmente importa: portas/vidro/entrada-saída), reduzindo CPU em cidades cheias.
* Mover as credenciais para variáveis de ambiente e desligar a busca direta na NUI (usar só o fallback do servidor), eliminando a exposição da chave.
* Normalizar `playlist_songs` caso o limite de 500 faixas cresça.
* Adicionar teste de fumaça no start: se a DUI não responder em 30 s, emitir um aviso claro no console com a lista de arquivos faltantes.

---

*Documento gerado a partir da leitura integral de `fxmanifest.lua`, `config.lua`, `client.lua`, `server.lua`, `audio/client.lua`, `audio/server.lua`, `html/audio.js`, `html/player.html`, `html/index.html` e dos handlers de `html/app.js`.*
