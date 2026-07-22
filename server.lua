local config = require 'config'
local isFrozen = {}

local function hasPermission(source, perm)
    if source == 0 then return true end
    local requiredPerm = config.perms[perm]
    if not IsPlayerAceAllowed(source, requiredPerm) then return false end
    if not exports.qbx_core:IsOptin(source) then return false end
    return true
end

local function getTarget(source, argsId)
    if source == 0 then
        if not argsId then
            print('^1[cuppa_admin] Console requires a player ID^0')
            return nil
        end
        return tonumber(argsId)
    end
    return tonumber(argsId) or source
end

local function notify(source, msg, type)
    if source == 0 then
        print('[cuppa_admin] ' .. msg)
    else
        exports.qbx_core:Notify(source, msg, type or 'inform')
    end
end

local function parseBanDuration(str)
    if not str then return nil end
    local num, unit = str:match('^(%d+)([hdmy])$')
    if not num then return nil end
    num = tonumber(num)
    if unit == 'h' then return num * 3600 end
    if unit == 'd' then return num * 86400 end
    if unit == 'm' then return num * 2592000 end
    if unit == 'y' then return num * 31536000 end
    return nil
end

local function formatDuration(seconds)
    if not seconds then return 'permanent' end
    if seconds >= 31536000 then return math.floor(seconds / 31536000) .. 'y' end
    if seconds >= 2592000 then return math.floor(seconds / 2592000) .. 'm' end
    if seconds >= 86400 then return math.floor(seconds / 86400) .. 'd' end
    if seconds >= 3600 then return math.floor(seconds / 3600) .. 'h' end
    return seconds .. 's'
end

local function getAllIdentifiers(source)
    local ids = {}
    local types = {'license', 'license2', 'discord', 'ip', 'steam', 'fivem', 'xbl', 'live'}
    for _, idType in ipairs(types) do
        local val = GetPlayerIdentifierByType(source, idType)
        if val and val ~= '' then
            ids[idType] = val
        end
    end
    return ids
end

local function logBanToDiscord(banId, name, ids, reason, bannedBy, durationText)
    if not config.banWebhook then return end
    local idList = ''
    for k, v in pairs(ids) do
        idList = idList .. k .. ': `' .. v .. '`\n'
    end
    local embed = {
        {
            title = 'Player Banned',
            color = 16711680,
            fields = {
                {name = 'Ban ID', value = '#' .. banId, inline = true},
                {name = 'Player', value = name, inline = true},
                {name = 'Duration', value = durationText, inline = true},
                {name = 'Banned By', value = bannedBy, inline = true},
                {name = 'Reason', value = reason, inline = false},
                {name = 'Identifiers', value = idList ~= '' and idList or 'None', inline = false},
            },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        }
    }
    PerformHttpRequest(config.banWebhook, function() end, 'POST',
        json.encode({embeds = embed}),
        {['Content-Type'] = 'application/json'}
    )
end

local function showHelp(source)
    local cmds = {
        {'cc',                              'List all online players'},
        {'cc help',                         'Show this help message'},
        {'cc kick <id> [reason]',           'Kick a player'},
        {'cc ban <id> [reason] [dur]',     'Ban a player (dur: 24h/7d/1m/1y)'},
        {'cc unban <banid>',                'Unban a player by ban ID'},
        {'cc heal <id>',                    'Fully heal a player + full armor'},
        {'cc kill <id>',                    'Kill a player'},
        {'cc revive <id>',                  'Revive a player'},
        {'cc freeze <id>',                  'Freeze a player in place'},
        {'cc unfreeze <id>',                'Unfreeze a player'},
        {'cc goto <id>',                    'Teleport to a player (in-game only)'},
        {'cc bring <id>',                   'Bring a player to you (in-game only)'},
        {'cc vehicle <model> [id]',         'Spawn a vehicle for a player'},
        {'cc fix [id]',                     'Fix a player\'s vehicle'},
        {'cc dv [id]',                      'Delete a player\'s vehicle'},
        {'cc giveitem <id> <item> [n]',     'Give items to a player'},
        {'cc setjob <id> <job> [grade]',    'Set a player\'s job'},
        {'cc setgang <id> <gang> [grade]',  'Set a player\'s gang'},
        {'cc givecash <id> <amount>',       'Give cash to a player'},
        {'cc givebank <id> <amount>',       'Give bank money to a player'},
        {'cc armor <id> [amount]',          'Set player armor (0-100)'},
        {'cc setmodel <model> [id]',        'Change a player\'s ped model'},
        {'cc noclip [id]',                  'Toggle noclip for a player'},
    }
    print('^2[cuppa_admin] Available Commands:^0')
    for _, cmd in ipairs(cmds) do
        print(('  ^3%-32s^0 %s'):format(cmd[1], cmd[2]))
    end
    print('')
    print('^2[cuppa_admin] Notes:^0')
    print('  - When run from console, player ID is required')
    print('  - When run in-game, omitting ID targets yourself')
    print('  - goto/bring only work in-game (not from console)')
    print('  - Ban returns an ID (e.g. #42) — use cc unban <id> to reverse')
end

local function listPlayers(source)
    if not hasPermission(source, 'list') then return notify(source, 'No permission', 'error') end
    local players = exports.qbx_core:GetQBPlayers()
    print('^2[cuppa_admin] Online Players:^0')
    for id, player in pairs(players) do
        local name = player.PlayerData.charinfo.firstname .. ' ' .. player.PlayerData.charinfo.lastname
        local job = player.PlayerData.job.label
        print(('  ID: %s | Name: %s | Job: %s'):format(id, name, job))
    end
end

RegisterCommand(config.prefix, function(source, args)
    local cmd = args[1]
    if not cmd then return listPlayers(source) end
    if cmd == 'help' then return showHelp(source) end

    if cmd == 'kick' then
        if not hasPermission(source, 'kick') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local reason = table.concat(args, ' ', 3) or 'No reason provided'
        DropPlayer(target, reason)
        notify(source, 'Kicked player ' .. target .. ': ' .. reason, 'success')

    elseif cmd == 'ban' then
        if not hasPermission(source, 'ban') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local name = GetPlayerName(target) or 'Unknown'
        local ids = getAllIdentifiers(target)
        local durationStr = args[#args]
        local duration = parseBanDuration(durationStr)
        local reasonEnd = duration and (#args - 1) or #args
        local reason = table.concat(args, ' ', 3, reasonEnd) or 'No reason provided'
        local durationText = formatDuration(duration)
        local expire = duration and (os.time() + duration) or 2147483647
        local bannedBy = source == 0 and 'Console' or GetPlayerName(source)
        local banMsg = 'Banned: ' .. reason
        if duration then banMsg = banMsg .. ' (expires in ' .. durationText .. ')' end
        MySQL.Async.insert('INSERT INTO bans (name, license, discord, ip, reason, expire, bannedby) VALUES (?, ?, ?, ?, ?, ?, ?)', {
            name, ids.license or '', ids.discord or '', ids.ip or '', reason, expire, bannedBy
        }, function(banId)
            if banId then
                print('^1[cuppa_admin] Banned: ' .. name .. ' (' .. target .. ') | Ban ID: #' .. banId .. ' | Duration: ' .. durationText .. ' | By: ' .. bannedBy .. '^0')
                print('^1[cuppa_admin] Reason: ' .. reason .. '^0')
                for k, v in pairs(ids) do
                    print('^1[cuppa_admin]   ' .. k .. ': ' .. v .. '^0')
                end
                logBanToDiscord(banId, name, ids, reason, bannedBy, durationText)
                notify(source, ('Banned %s (#%d) | %s | Reason: %s'):format(name, banId, durationText, reason), 'success')
            else
                notify(source, 'Ban failed - database error', 'error')
            end
        end)
        DropPlayer(target, banMsg)

    elseif cmd == 'unban' then
        if not hasPermission(source, 'unban') then return notify(source, 'No permission', 'error') end
        local banId = tonumber(args[2])
        if not banId then return notify(source, 'Usage: cc unban <banid>', 'error') end
        MySQL.Async.fetch('SELECT id, name FROM bans WHERE id = ?', {banId}, function(result)
            if not result or not result[1] then
                return notify(source, 'No ban found with ID #' .. banId, 'error')
            end
            MySQL.Async.execute('DELETE FROM bans WHERE id = ?', {banId}, function(rowsAffected)
                if rowsAffected and rowsAffected > 0 then
                    print('^2[cuppa_admin] Unbanned: ' .. result[1].name .. ' (Ban ID: #' .. banId .. ')^0')
                    notify(source, ('Unbanned %s (Ban ID: #%d)'):format(result[1].name, banId), 'success')
                else
                    notify(source, 'Failed to remove ban', 'error')
                end
            end)
        end)

    elseif cmd == 'heal' then
        if not hasPermission(source, 'heal') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_medical:Heal(target)
        SetPedArmour(GetPlayerPed(target), 100)
        notify(source, 'Healed player ' .. target, 'success')

    elseif cmd == 'kill' then
        if not hasPermission(source, 'kill') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:kill', target)
        notify(source, 'Killed player ' .. target, 'success')

    elseif cmd == 'revive' then
        if not hasPermission(source, 'revive') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_medical:Revive(target)
        notify(source, 'Revived player ' .. target, 'success')

    elseif cmd == 'freeze' then
        if not hasPermission(source, 'freeze') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        FreezeEntityPosition(GetPlayerPed(target), true)
        isFrozen[target] = true
        notify(source, 'Froze player ' .. target, 'success')

    elseif cmd == 'unfreeze' then
        if not hasPermission(source, 'unfreeze') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        FreezeEntityPosition(GetPlayerPed(target), false)
        isFrozen[target] = nil
        notify(source, 'Unfroze player ' .. target, 'success')

    elseif cmd == 'goto' then
        if source == 0 then return notify(source, 'Cannot use goto from console', 'error') end
        if not hasPermission(source, 'goto_cmd') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc goto <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local coords = GetEntityCoords(GetPlayerPed(target))
        local targetBucket = GetPlayerRoutingBucket(target)
        if GetPlayerRoutingBucket(source) ~= targetBucket then
            SetPlayerRoutingBucket(source, targetBucket)
        end
        SetEntityCoords(GetPlayerPed(source), coords.x, coords.y, coords.z, false, false, false, false)
        notify(source, 'Teleported to player ' .. target, 'success')

    elseif cmd == 'bring' then
        if source == 0 then return notify(source, 'Cannot use bring from console', 'error') end
        if not hasPermission(source, 'bring') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc bring <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local coords = GetEntityCoords(GetPlayerPed(source))
        local sourceBucket = GetPlayerRoutingBucket(source)
        if GetPlayerRoutingBucket(target) ~= sourceBucket then
            SetPlayerRoutingBucket(target, sourceBucket)
        end
        SetEntityCoords(GetPlayerPed(target), coords.x, coords.y, coords.z, false, false, false, false)
        notify(source, 'Brought player ' .. target, 'success')

    elseif cmd == 'vehicle' then
        if not hasPermission(source, 'vehicle') then return notify(source, 'No permission', 'error') end
        local model = args[2]
        if not model then return notify(source, 'Usage: cc vehicle <model> [id]', 'error') end
        local target = getTarget(source, args[3]) or source
        if target == 0 then return notify(source, 'Console requires a player ID', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local ped = GetPlayerPed(target)
        local netId, vehicle = qbx.spawnVehicle({ model = model, spawnSource = ped, warp = true })
        if not netId then return notify(source, 'Failed to spawn vehicle', 'error') end
        exports.qbx_vehiclekeys:GiveKeys(target, vehicle)
        notify(source, 'Spawned ' .. model .. ' for player ' .. target, 'success')

    elseif cmd == 'fix' then
        if not hasPermission(source, 'fix') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2]) or source
        if target == 0 then return notify(source, 'Console requires a player ID', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:fixVehicle', target)
        notify(source, 'Fixed vehicle for player ' .. target, 'success')

    elseif cmd == 'dv' then
        if not hasPermission(source, 'dv') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2]) or source
        if target == 0 then return notify(source, 'Console requires a player ID', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:deleteVehicle', target)
        notify(source, 'Deleted vehicle for player ' .. target, 'success')

    elseif cmd == 'giveitem' then
        if not hasPermission(source, 'giveitem') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local item = args[3]
        local count = tonumber(args[4]) or 1
        if not item then return notify(source, 'Usage: cc giveitem <id> <item> [amount]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.ox_inventory:AddItem(target, item, count)
        notify(source, 'Gave ' .. count .. 'x ' .. item .. ' to player ' .. target, 'success')

    elseif cmd == 'setjob' then
        if not hasPermission(source, 'setjob') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local job = args[3]
        local grade = tonumber(args[4]) or 0
        if not job then return notify(source, 'Usage: cc setjob <id> <job> [grade]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_core:SetJob(target, job, grade)
        notify(source, 'Set player ' .. target .. ' job to ' .. job .. ' grade ' .. grade, 'success')

    elseif cmd == 'setgang' then
        if not hasPermission(source, 'setgang') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local gang = args[3]
        local grade = tonumber(args[4]) or 0
        if not gang then return notify(source, 'Usage: cc setgang <id> <gang> [grade]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_core:SetGang(target, gang, grade)
        notify(source, 'Set player ' .. target .. ' gang to ' .. gang .. ' grade ' .. grade, 'success')

    elseif cmd == 'givecash' then
        if not hasPermission(source, 'givecash') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local amount = tonumber(args[3])
        if not amount then return notify(source, 'Usage: cc givecash <id> <amount>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_core:AddMoney(target, 'cash', amount, 'cuppa_admin')
        notify(source, 'Gave $' .. amount .. ' cash to player ' .. target, 'success')

    elseif cmd == 'givebank' then
        if not hasPermission(source, 'givebank') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local amount = tonumber(args[3])
        if not amount then return notify(source, 'Usage: cc givebank <id> <amount>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.qbx_core:AddMoney(target, 'bank', amount, 'cuppa_admin')
        notify(source, 'Gave $' .. amount .. ' bank to player ' .. target, 'success')

    elseif cmd == 'armor' then
        if not hasPermission(source, 'armor') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        local amount = tonumber(args[3]) or 100
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        player.Functions.SetMetaData('armor', amount)
        SetPedArmour(GetPlayerPed(target), amount)
        notify(source, 'Set player ' .. target .. ' armor to ' .. amount, 'success')

    elseif cmd == 'setmodel' then
        if not hasPermission(source, 'setmodel') then return notify(source, 'No permission', 'error') end
        local model = args[2]
        if not model then return notify(source, 'Usage: cc setmodel <model> [id]', 'error') end
        local target = getTarget(source, args[3]) or (source == 0 and nil or source)
        if not target then return notify(source, 'Usage: cc setmodel <model> [id]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:setModel', target, model)
        notify(source, 'Set player ' .. target .. ' model to ' .. model, 'success')

    elseif cmd == 'noclip' then
        if not hasPermission(source, 'noclip') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2]) or (source == 0 and nil or source)
        if not target then return notify(source, 'Usage: cc noclip [id]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:noclip', target)
        notify(source, 'Toggled noclip for player ' .. target, 'success')

    else
        notify(source, 'Unknown command: cc ' .. cmd .. ' — run "cc help" for commands', 'error')
    end
end, false)
