fx_version 'cerulean'
game 'gta5'

name 'solis_sound'
author 'mewmods'
description 'Streaming de música: motor de áudio próprio, sessões espaciais e UI própria'
version '2.0.0'

shared_scripts {
    'config.lua'
}

client_scripts {
    'bridge/client.lua',
    'audio/client.lua',
    'client.lua'
}

server_scripts {
    'bridge/frameworks/vrp.lua',
    'bridge/frameworks/qbcore.lua',
    'bridge/frameworks/esx.lua',
    'bridge/frameworks/standalone.lua',
    'bridge/server.lua',
    'audio/server.lua',
    'server.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/audio.html',
    'html/audio.js',
    'html/hls.min.js',
    'html/player.html'
}

dependencies {
    'oxmysql'
}

client_exports {
    'PlayPhoneMusic',
    'PausePhoneMusic',
    'ResumePhoneMusic',
    'SeekPhoneMusic',
    'SetPhoneVolume',
    'GetPhoneAudioState',
    'GetIndividualVolume',
    'SetIndividualVolume'
}
