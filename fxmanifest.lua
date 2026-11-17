fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Nevera Development'
description 'In-game debug tool for inspecting and editing entities, peds, vehicles and creating ox_target targets, built on ox_lib and ox_target.'
version '2.0.0'

dependencies { 'ox_lib', 'ox_target' }

shared_scripts { '@ox_lib/init.lua', 'config.lua' }
client_scripts { 'client/client.lua' }
