fx_version 'cerulean'
game 'gta5'

description 'Simple Console Admin Commands'
author 'cuppacodes'

version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
    'discord_server.lua',
}

client_scripts {
    'client.lua',
}

lua54 'yes'
