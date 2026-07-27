local config = require 'config'
local isFrozen = {}
local hiddenState = {} -- [source] = exceptionServerId
local bucketState = {} -- [source] = bucketId
local bucketMembers = {} -- [bucketId] = {[source] = true, ...}
local bucketAdmin = {} -- [bucketId] = adminSource
local bucketLicenses = {} -- [license] = bucketId (persists across disconnects)
local undoState = {} -- [targetId] = { action, previous }

local MAX_REASON_LENGTH = 256
local MAX_MONEY = 10000000
local MAX_DV_RADIUS = 500
local MAX_GIVEITEM = 9999
local commandOutput = nil -- set by executeCommand to capture notify() output

local validModels = {}
local function isValidModel(model)
    if validModels[model] ~= nil then return validModels[model] end
    local hash = joaat(model)
    local success = pcall(function() RequestModel(hash) end)
    validModels[model] = success and IsModelValid(hash) or false
    if validModels[model] then SetModelAsNoLongerNeeded(hash) end
    return validModels[model]
end

local function getLicense(source)
    return GetPlayerIdentifierByType(source, 'license')
end

local medicalResource = nil
if GetResourceState('wasabi_ambulance_v2') == 'started' then
    medicalResource = 'wasabi'
elseif GetResourceState('qbx_medical') == 'started' then
    medicalResource = 'qbx'
end

local function revivePlayer(target)
    if medicalResource == 'wasabi' then
        exports.wasabi_ambulance_v2:RevivePlayer(target)
    elseif medicalResource == 'qbx' then
        exports.qbx_medical:Revive(target)
    else
        print('^1[cuppa_admin] No medical resource found (wasabi_ambulance_v2 or qbx_medical)^0')
    end
end

local function healPlayer(target)
    if medicalResource == 'wasabi' then
        exports.wasabi_ambulance_v2:ApplyHeal(target, {
            health = 200,
            injuries = { { type = 'all', limb = 'all' } },
            limbHealth = 100,
            resetNeeds = true
        })
    elseif medicalResource == 'qbx' then
        exports.qbx_medical:Heal(target)
    else
        print('^1[cuppa_admin] No medical resource found (wasabi_ambulance_v2 or qbx_medical)^0')
    end
end

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
    if commandOutput ~= nil then
        commandOutput = commandOutput .. msg .. '\n'
    end
end

--- Undo system: save state before a reversible action
---@param target number
---@param action string
---@param previous table
local function saveUndo(target, action, previous)
    undoState[target] = { action = action, previous = previous }
end

--- Parse ban duration string (e.g. "24h", "7d", "1m", "1y")
--- Returns seconds, or nil if invalid. Caps at config.MAX_BAN_DURATION.
local function parseBanDuration(str)
    if not str then return nil end
    local num, unit = str:match('^(%d+)([hdmy])$')
    if not num then return nil end
    num = tonumber(num)
    local seconds
    if unit == 'h' then seconds = num * 3600
    elseif unit == 'd' then seconds = num * 86400
    elseif unit == 'm' then seconds = num * 2592000
    elseif unit == 'y' then seconds = num * 31536000
    else return nil end
    if seconds > config.MAX_BAN_DURATION then
        seconds = config.MAX_BAN_DURATION
    end
    return seconds
end

local function formatDuration(seconds)
    if not seconds then return 'permanent' end
    if seconds >= 31536000 then return math.floor(seconds / 31536000) .. 'y' end
    if seconds >= 2592000 then return math.floor(seconds / 2592000) .. 'm' end
    if seconds >= 86400 then return math.floor(seconds / 86400) .. 'd' end
    if seconds >= 3600 then return math.floor(seconds / 3600) .. 'h' end
    return seconds .. 's'
end

local function formatTimestamp(unix)
    if not unix or unix >= 2147483647 then return 'never' end
    return os.date('%Y-%m-%d %H:%M', unix)
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

--- Generic Discord action logging
---@param title string
---@param color number
---@param fields table
---@param admin string
local function logActionToDiscord(title, color, fields, admin)
    local webhook = config.adminWebhook
    if not webhook then return end
    local embed = {
        {
            title = title,
            color = color,
            fields = fields,
            footer = { text = 'cuppa_admin' },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        }
    }
    PerformHttpRequest(webhook, function() end, 'POST',
        json.encode({embeds = embed}),
        {['Content-Type'] = 'application/json'}
    )
end

local function logBanToDiscord(banId, name, ids, reason, bannedBy, durationText)
    local idList = ''
    for k, v in pairs(ids) do
        idList = idList .. k .. ': `' .. v .. '`\n'
    end
    logActionToDiscord('Player Banned', 16711680, {
        {name = 'Ban ID', value = '#' .. banId, inline = true},
        {name = 'Player', value = name, inline = true},
        {name = 'Duration', value = durationText, inline = true},
        {name = 'Banned By', value = bannedBy, inline = true},
        {name = 'Reason', value = reason, inline = false},
        {name = 'Identifiers', value = idList ~= '' and idList or 'None', inline = false},
    }, bannedBy)
end

local function logAdminAction(action, details, admin)
    if not config.logAllActions then return end
    print(('[cuppa_admin] %s by %s: %s'):format(action, admin or 'Console', details))
end

local function showHelp(source)
    local cmds = {
        {'cc',                                'Show this help message'},
        {'cc stats',                          'List all online players'},
        {'cc announce <msg>',                 'Send server-wide announcement'},
        {'cc kick [reason] <id>',             'Kick a player'},
        {'cc ban [reason] [dur] <id>',       'Ban a player (dur: 24h/7d/1m/1y)'},
        {'cc unban <banid>',                  'Unban a player by ban ID'},
        {'cc baninfo <banid>',                'Look up ban details'},
        {'cc undo <id>',                      'Reverse last admin action on a player'},
        {'cc heal <id>',                      'Fully heal a player + full armor'},
        {'cc kill [id]',                      'Kill a player (or self)'},
        {'cc revive <id>',                    'Revive a player'},
        {'cc freeze <id|all>',                'Toggle freeze on a player (or all players)'},
        {'cc goto <id>',                      'Teleport to a player (in-game only)'},
        {'cc bring <id>',                     'Bring a player to you (in-game only)'},
        {'cc car <model> [id]',               'Spawn a vehicle for a player'},
        {'cc fix [id]',                       'Fix a player\'s vehicle'},
        {'cc dv [radius] [id]',               'Delete vehicle(s) near a player (meters)'},
        {'cc giveitem <item> [n] <id>',       'Give items to a player'},
        {'cc setjob <job> [grade] <id>',      'Set a player\'s job'},
        {'cc setgang <gang> [grade] <id>',    'Set a player\'s gang'},
        {'cc givecash <amount> <id>',         'Give cash to a player'},
        {'cc givebank <amount> <id>',         'Give bank money to a player'},
        {'cc armor [amount] <id>',            'Set player armor (0-100)'},
        {'cc setmodel <model> [id]',          'Change a player\'s ped model'},
        {'cc noclip [id]',                    'Toggle noclip for a player'},
        {'cc tp <id> <id>',                   'Teleport player A to player B'},
        {'cc godmode [id]',                   'Toggle godmode for a player'},
        {'cc visible [id]',                   'Toggle player visible/invisible (on your screen)'},
        {'cc hide <id>',                      'Hide yourself from everyone except <id>'},
        {'cc show',                           'Restore normal visibility (undo cc hide)'},
        {'cc bucket',                         'Show bucket status (or create one)'},
        {'cc bucket <id>',                    'Add player to your bucket'},
        {'cc bucket -<id>',                   'Remove player from your bucket'},
        {'cc bucket destroy [id]',            'Dissolve your bucket (or by ID)'},
        {'cc bucket wipe',                    'Destroy ALL buckets'},
    }
    print('^2[cuppa_admin] Available Commands:^0')
    for _, cmd in ipairs(cmds) do
        print(('  ^3%-38s^0 %s'):format(cmd[1], cmd[2]))
    end
    print('')
    print('^2[cuppa_admin] Notes:^0')
    print('  - Player ID is always the last argument')
    print('  - When run from console, player ID is required')
    print('  - When run in-game, omitting ID targets yourself')
    print('  - goto/bring only work in-game (not from console)')
    print('  - Ban returns an ID (e.g. #42) — use cc unban <id> to reverse')
    print('  - Use cc undo <id> to reverse setjob/setgang/givecash/givebank/armor/setmodel')
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

local function handleCommand(source, args)
    local cmd = args[1]
    if not cmd then return showHelp(source) end
    if cmd == 'stats' then return listPlayers(source) end

    if cmd == 'announce' then
        if not hasPermission(source, 'announce') then return notify(source, 'No permission', 'error') end
        if #args < 2 then return notify(source, 'Usage: cc announce <message>', 'error') end
        local msg = table.concat(args, ' ', 2)
        local players = GetPlayers()
        for i = 1, #players do
            TriggerClientEvent('cuppa_admin:client:announce', tonumber(players[i]), msg)
        end
        logAdminAction('Announce', msg, source == 0 and 'Console' or GetPlayerName(source))
        notify(source, 'Announced: ' .. msg, 'success')

    elseif cmd == 'kick' then
        if not hasPermission(source, 'kick') then return notify(source, 'No permission', 'error') end
        if #args < 2 then return notify(source, 'Usage: cc kick [reason] <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc kick [reason] <id>', 'error') end
        if source ~= 0 and target == source then return notify(source, 'Cannot kick yourself', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local reason = #args > 2 and table.concat(args, ' ', 2, #args - 1) or 'No reason provided'
        if #reason > MAX_REASON_LENGTH then reason = reason:sub(1, MAX_REASON_LENGTH) end
        local adminName = source == 0 and 'Console' or GetPlayerName(source)
        logAdminAction('Kick', ('%s kicked %s: %s'):format(adminName, GetPlayerName(target), reason), adminName)
        DropPlayer(target, reason)
        notify(source, 'Kicked player ' .. target .. ': ' .. reason, 'success')

    elseif cmd == 'ban' then
        if not hasPermission(source, 'ban') then return notify(source, 'No permission', 'error') end
        if #args < 2 then return notify(source, 'Usage: cc ban [reason] [dur] <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc ban [reason] [dur] <id>', 'error') end
        if source ~= 0 and target == source then return notify(source, 'Cannot ban yourself', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local name = GetPlayerName(target) or 'Unknown'
        local ids = getAllIdentifiers(target)
        local durationStr = #args >= 3 and args[#args - 1] or nil
        local duration = parseBanDuration(durationStr)
        local reasonStart = duration and 2 or 2
        local reasonEnd = duration and (#args - 2) or (#args - 1)
        local reason = reasonEnd >= reasonStart and table.concat(args, ' ', reasonStart, reasonEnd) or 'No reason provided'
        if #reason > MAX_REASON_LENGTH then reason = reason:sub(1, MAX_REASON_LENGTH) end
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
                    logAdminAction('Unban', ('Unbanned %s (#%d)'):format(result[1].name, banId), source == 0 and 'Console' or GetPlayerName(source))
                    notify(source, ('Unbanned %s (Ban ID: #%d)'):format(result[1].name, banId), 'success')
                else
                    notify(source, 'Failed to remove ban', 'error')
                end
            end)
        end)

    elseif cmd == 'baninfo' then
        if not hasPermission(source, 'baninfo') then return notify(source, 'No permission', 'error') end
        local banId = tonumber(args[2])
        if not banId then return notify(source, 'Usage: cc baninfo <banid>', 'error') end
        MySQL.Async.fetch('SELECT * FROM bans WHERE id = ?', {banId}, function(result)
            if not result or not result[1] then
                return notify(source, 'No ban found with ID #' .. banId, 'error')
            end
            local b = result[1]
            local isExpired = b.expire and b.expire < os.time()
            local status = isExpired and 'Expired' or 'Active'
            print('^2[cuppa_admin] Ban #' .. banId .. ' — ' .. status .. '^0')
            print('  Player: ' .. (b.name or 'Unknown'))
            print('  Banned by: ' .. (b.bannedby or 'Unknown'))
            print('  Reason: ' .. (b.reason or 'None'))
            if b.expire and b.expire < 2147483647 then
                print('  Expires: ' .. formatTimestamp(b.expire) .. ' (' .. formatDuration(b.expire - os.time()) .. ')')
            else
                print('  Expires: never (permanent)')
            end
            if b.license and b.license ~= '' then print('  License: ' .. b.license) end
            if b.discord and b.discord ~= '' then print('  Discord: ' .. b.discord) end
            if b.ip and b.ip ~= '' then print('  IP: ' .. b.ip) end
            notify(source, 'Ban info printed to console', 'inform')
        end)

    elseif cmd == 'undo' then
        if not hasPermission(source, 'undo') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc undo <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local state = undoState[target]
        if not state then return notify(source, 'Nothing to undo for player ' .. target, 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        if state.action == 'setjob' then
            exports.qbx_core:SetJob(target, state.previous.job, state.previous.grade)
            notify(source, 'Reverted player ' .. target .. ' job to ' .. state.previous.job .. ' grade ' .. state.previous.grade, 'success')
        elseif state.action == 'setgang' then
            exports.qbx_core:SetGang(target, state.previous.gang, state.previous.grade)
            notify(source, 'Reverted player ' .. target .. ' gang to ' .. state.previous.gang .. ' grade ' .. state.previous.grade, 'success')
        elseif state.action == 'givecash' then
            local currentCash = player.PlayerData.money.cash
            local diff = currentCash - state.previous.amount
            if diff > 0 then
                exports.qbx_core:RemoveMoney(target, 'cash', diff, 'cuppa_admin_undo')
            elseif diff < 0 then
                exports.qbx_core:AddMoney(target, 'cash', -diff, 'cuppa_admin_undo')
            end
            notify(source, 'Reverted player ' .. target .. ' cash to $' .. state.previous.amount, 'success')
        elseif state.action == 'givebank' then
            local currentBank = player.PlayerData.money.bank
            local diff = currentBank - state.previous.amount
            if diff > 0 then
                exports.qbx_core:RemoveMoney(target, 'bank', diff, 'cuppa_admin_undo')
            elseif diff < 0 then
                exports.qbx_core:AddMoney(target, 'bank', -diff, 'cuppa_admin_undo')
            end
            notify(source, 'Reverted player ' .. target .. ' bank to $' .. state.previous.amount, 'success')
        elseif state.action == 'armor' then
            player.Functions.SetMetaData('armor', state.previous.amount)
            SetPedArmour(GetPlayerPed(target), state.previous.amount)
            notify(source, 'Reverted player ' .. target .. ' armor to ' .. state.previous.amount, 'success')
        elseif state.action == 'setmodel' then
            TriggerClientEvent('cuppa_admin:client:setModel', target, state.previous.model)
            notify(source, 'Reverted player ' .. target .. ' model', 'success')
        else
            notify(source, 'Unknown action type: ' .. tostring(state.action), 'error')
            undoState[target] = nil
            return
        end
        undoState[target] = nil
        logAdminAction('Undo', ('Reverted %s on player %d'):format(state.action, target), source == 0 and 'Console' or GetPlayerName(source))

    elseif cmd == 'heal' then
        if not hasPermission(source, 'heal') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        healPlayer(target)
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
        revivePlayer(target)
        notify(source, 'Revived player ' .. target, 'success')

    elseif cmd == 'freeze' then
        if not hasPermission(source, 'freeze') then return notify(source, 'No permission', 'error') end
        local targetArg = args[2]
        if targetArg == 'all' then
            local players = exports.qbx_core:GetQBPlayers()
            local frozen = 0
            local unfrozen = 0
            for id, _ in pairs(players) do
                local idNum = tonumber(id)
                if isFrozen[idNum] then
                    FreezeEntityPosition(GetPlayerPed(idNum), false)
                    isFrozen[idNum] = nil
                    unfrozen = unfrozen + 1
                else
                    FreezeEntityPosition(GetPlayerPed(idNum), true)
                    isFrozen[idNum] = true
                    frozen = frozen + 1
                end
            end
            logAdminAction('Freeze All', ('Froze %d, unfroze %d'):format(frozen, unfrozen), source == 0 and 'Console' or GetPlayerName(source))
            notify(source, 'Froze ' .. frozen .. ', unfroze ' .. unfrozen .. ' players', 'success')
        else
            local target = getTarget(source, targetArg)
            if not target then return end
            if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
            if isFrozen[target] then
                FreezeEntityPosition(GetPlayerPed(target), false)
                isFrozen[target] = nil
                notify(source, 'Unfroze player ' .. target, 'success')
            else
                FreezeEntityPosition(GetPlayerPed(target), true)
                isFrozen[target] = true
                notify(source, 'Froze player ' .. target, 'success')
            end
        end

    elseif cmd == 'goto' then
        if source == 0 then return notify(source, 'Cannot use goto from console', 'error') end
        if not hasPermission(source, 'goto_cmd') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc goto <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local targetPed = GetPlayerPed(target)
        local targetVehicle = GetVehiclePedIsIn(targetPed, false)
        local targetBucket = GetPlayerRoutingBucket(target)
        if GetPlayerRoutingBucket(source) ~= targetBucket then
            SetPlayerRoutingBucket(source, targetBucket)
        end
        if targetVehicle and targetVehicle ~= 0 then
            local netId = NetworkGetNetworkIdFromEntity(targetVehicle)
            if netId and netId ~= 0 then
                local seat = 1
                for i = -1, GetVehicleMaxNumberOfPassengers(targetVehicle) - 1 do
                    if IsVehicleSeatFree(targetVehicle, i) then
                        seat = i
                        break
                    end
                end
                TriggerClientEvent('cuppa_admin:client:warpIntoVehicle', source, netId, seat)
            else
                local coords = GetEntityCoords(targetPed)
                SetEntityCoords(GetPlayerPed(source), coords.x, coords.y, coords.z, false, false, false, false)
            end
        else
            local coords = GetEntityCoords(targetPed)
            SetEntityCoords(GetPlayerPed(source), coords.x, coords.y, coords.z, false, false, false, false)
        end
        notify(source, 'Teleported to player ' .. target, 'success')

    elseif cmd == 'bring' then
        if source == 0 then return notify(source, 'Cannot use bring from console', 'error') end
        if not hasPermission(source, 'bring') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc bring <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local sourceCoords = GetEntityCoords(GetPlayerPed(source))
        local sourceBucket = GetPlayerRoutingBucket(source)
        if GetPlayerRoutingBucket(target) ~= sourceBucket then
            SetPlayerRoutingBucket(target, sourceBucket)
        end
        local targetPed = GetPlayerPed(target)
        local targetVehicle = GetVehiclePedIsIn(targetPed, false)
        if targetVehicle and targetVehicle ~= 0 then
            TriggerClientEvent('cuppa_admin:client:bringVehicle', target, { x = sourceCoords.x, y = sourceCoords.y, z = sourceCoords.z, w = GetEntityHeading(GetPlayerPed(source)) })
        else
            SetEntityCoords(targetPed, sourceCoords.x, sourceCoords.y, sourceCoords.z, false, false, false, false)
        end
        notify(source, 'Brought player ' .. target .. (targetVehicle and targetVehicle ~= 0 and ' (with vehicle)' or ''), 'success')

    elseif cmd == 'car' then
        if not hasPermission(source, 'car') then return notify(source, 'No permission', 'error') end
        local model = args[2]
        if not model then return notify(source, 'Usage: cc car <model> [id]', 'error') end
        if not isValidModel(model) then return notify(source, 'Invalid vehicle model: ' .. model, 'error') end
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
        local radius = tonumber(args[2])
        local target = getTarget(source, args[3]) or source
        if target == 0 then return notify(source, 'Console requires a player ID', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        if radius then
            radius = math.min(radius, MAX_DV_RADIUS)
            local coords = GetEntityCoords(GetPlayerPed(target))
            local vehicles = GetGamePool('CVehicle')
            local count = 0
            for _, vehicle in ipairs(vehicles) do
                local vCoords = GetEntityCoords(vehicle)
                if #(coords - vCoords) <= radius then
                    DeleteEntity(vehicle)
                    count = count + 1
                end
            end
            notify(source, 'Deleted ' .. count .. ' vehicles within ' .. radius .. 'm of player ' .. target, 'success')
        else
            TriggerClientEvent('cuppa_admin:client:deleteVehicle', target)
            notify(source, 'Deleted vehicle for player ' .. target, 'success')
        end

    elseif cmd == 'giveitem' then
        if not hasPermission(source, 'giveitem') then return notify(source, 'No permission', 'error') end
        if #args < 3 then return notify(source, 'Usage: cc giveitem <item> [amount] <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc giveitem <item> [amount] <id>', 'error') end
        local item = args[2]
        local count = #args > 3 and math.max(1, math.min(MAX_GIVEITEM, tonumber(args[3]) or 1)) or 1
        if not item:match('^[%w_]+$') then return notify(source, 'Invalid item name', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        exports.ox_inventory:AddItem(target, item, count)
        notify(source, 'Gave ' .. count .. 'x ' .. item .. ' to player ' .. target, 'success')

    elseif cmd == 'setjob' then
        if not hasPermission(source, 'setjob') then return notify(source, 'No permission', 'error') end
        if #args < 3 then return notify(source, 'Usage: cc setjob <job> [grade] <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc setjob <job> [grade] <id>', 'error') end
        local job = args[2]
        local grade = #args > 3 and tonumber(args[3]) or 0
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local jobs = exports.qbx_core:GetJobs()
        if not jobs[job] then return notify(source, 'Invalid job: ' .. job, 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        saveUndo(target, 'setjob', { job = player.PlayerData.job.name, grade = player.PlayerData.job.grade.level })
        exports.qbx_core:SetJob(target, job, grade)
        notify(source, 'Set player ' .. target .. ' job to ' .. job .. ' grade ' .. grade, 'success')

    elseif cmd == 'setgang' then
        if not hasPermission(source, 'setgang') then return notify(source, 'No permission', 'error') end
        if #args < 3 then return notify(source, 'Usage: cc setgang <gang> [grade] <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc setgang <gang> [grade] <id>', 'error') end
        local gang = args[2]
        local grade = #args > 3 and tonumber(args[3]) or 0
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local gangs = exports.qbx_core:GetGangs()
        if not gangs[gang] then return notify(source, 'Invalid gang: ' .. gang, 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        saveUndo(target, 'setgang', { gang = player.PlayerData.gang.name, grade = player.PlayerData.gang.grade.level })
        exports.qbx_core:SetGang(target, gang, grade)
        notify(source, 'Set player ' .. target .. ' gang to ' .. gang .. ' grade ' .. grade, 'success')

    elseif cmd == 'givecash' then
        if not hasPermission(source, 'givecash') then return notify(source, 'No permission', 'error') end
        if #args < 3 then return notify(source, 'Usage: cc givecash <amount> <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc givecash <amount> <id>', 'error') end
        local amount = tonumber(args[2])
        if not amount or amount <= 0 or amount > MAX_MONEY then return notify(source, 'Amount must be 1-' .. MAX_MONEY, 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        saveUndo(target, 'givecash', { amount = player.PlayerData.money.cash })
        exports.qbx_core:AddMoney(target, 'cash', amount, 'cuppa_admin')
        notify(source, 'Gave $' .. amount .. ' cash to player ' .. target, 'success')

    elseif cmd == 'givebank' then
        if not hasPermission(source, 'givebank') then return notify(source, 'No permission', 'error') end
        if #args < 3 then return notify(source, 'Usage: cc givebank <amount> <id>', 'error') end
        local target = tonumber(args[#args])
        if not target then return notify(source, 'Usage: cc givebank <amount> <id>', 'error') end
        local amount = tonumber(args[2])
        if not amount or amount <= 0 or amount > MAX_MONEY then return notify(source, 'Amount must be 1-' .. MAX_MONEY, 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local player = exports.qbx_core:GetPlayer(target)
        saveUndo(target, 'givebank', { amount = player.PlayerData.money.bank })
        exports.qbx_core:AddMoney(target, 'bank', amount, 'cuppa_admin')
        notify(source, 'Gave $' .. amount .. ' bank to player ' .. target, 'success')

    elseif cmd == 'armor' then
        if not hasPermission(source, 'armor') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, #args >= 3 and args[3] or args[2])
        if not target then return end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local amount
        if #args >= 3 then
            amount = math.max(0, math.min(100, tonumber(args[2]) or 100))
        else
            amount = 100
        end
        local player = exports.qbx_core:GetPlayer(target)
        saveUndo(target, 'armor', { amount = player.PlayerData.metadata.armor or 0 })
        player.Functions.SetMetaData('armor', amount)
        SetPedArmour(GetPlayerPed(target), amount)
        notify(source, 'Set player ' .. target .. ' armor to ' .. amount, 'success')

    elseif cmd == 'setmodel' then
        if not hasPermission(source, 'setmodel') then return notify(source, 'No permission', 'error') end
        local model = args[2]
        if not model then return notify(source, 'Usage: cc setmodel <model> [id]', 'error') end
        if not isValidModel(model) then return notify(source, 'Invalid ped model: ' .. model, 'error') end
        local target = getTarget(source, args[3]) or (source == 0 and nil or source)
        if not target then return notify(source, 'Usage: cc setmodel <model> [id]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local currentModel = GetEntityModel(GetPlayerPed(target))
        saveUndo(target, 'setmodel', { model = currentModel })
        TriggerClientEvent('cuppa_admin:client:setModel', target, model)
        notify(source, 'Set player ' .. target .. ' model to ' .. model, 'success')

    elseif cmd == 'noclip' then
        if not hasPermission(source, 'noclip') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2]) or (source == 0 and nil or source)
        if not target then return notify(source, 'Usage: cc noclip [id]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:noclip', target)
        notify(source, 'Toggled noclip for player ' .. target, 'success')

    elseif cmd == 'tp' then
        if source == 0 then
            if not hasPermission(source, 'tp') then return notify(source, 'No permission', 'error') end
            local targetA = tonumber(args[2])
            local targetB = tonumber(args[3])
            if not targetA or not targetB then return notify(source, 'Usage: cc tp <id> <id>', 'error') end
            if not exports.qbx_core:GetPlayer(targetA) then return notify(source, 'Player ' .. targetA .. ' not found', 'error') end
            if not exports.qbx_core:GetPlayer(targetB) then return notify(source, 'Player ' .. targetB .. ' not found', 'error') end
            local coords = GetEntityCoords(GetPlayerPed(targetB))
            local targetBucket = GetPlayerRoutingBucket(targetB)
            if GetPlayerRoutingBucket(targetA) ~= targetBucket then
                SetPlayerRoutingBucket(targetA, targetBucket)
            end
            SetEntityCoords(GetPlayerPed(targetA), coords.x, coords.y, coords.z, false, false, false, false)
            notify(source, 'Teleported player ' .. targetA .. ' to player ' .. targetB, 'success')
        else
            if not hasPermission(source, 'tp') then return notify(source, 'No permission', 'error') end
            local targetA = tonumber(args[2])
            local targetB = tonumber(args[3])
            if targetA and not targetB then
                if not exports.qbx_core:GetPlayer(targetA) then return notify(source, 'Player not found', 'error') end
                local coords = GetEntityCoords(GetPlayerPed(targetA))
                local targetBucket = GetPlayerRoutingBucket(targetA)
                if GetPlayerRoutingBucket(source) ~= targetBucket then
                    SetPlayerRoutingBucket(source, targetBucket)
                end
                SetEntityCoords(GetPlayerPed(source), coords.x, coords.y, coords.z, false, false, false, false)
                notify(source, 'Teleported to player ' .. targetA, 'success')
            elseif targetA and targetB then
                if not exports.qbx_core:GetPlayer(targetA) then return notify(source, 'Player ' .. targetA .. ' not found', 'error') end
                if not exports.qbx_core:GetPlayer(targetB) then return notify(source, 'Player ' .. targetB .. ' not found', 'error') end
                local coords = GetEntityCoords(GetPlayerPed(targetB))
                local targetBucket = GetPlayerRoutingBucket(targetB)
                if GetPlayerRoutingBucket(targetA) ~= targetBucket then
                    SetPlayerRoutingBucket(targetA, targetBucket)
                end
                SetEntityCoords(GetPlayerPed(targetA), coords.x, coords.y, coords.z, false, false, false, false)
                notify(source, 'Teleported player ' .. targetA .. ' to player ' .. targetB, 'success')
            else
                return notify(source, 'Usage: cc tp <id> [id]', 'error')
            end
        end

    elseif cmd == 'godmode' then
        if not hasPermission(source, 'godmode') then return notify(source, 'No permission', 'error') end
        local target = getTarget(source, args[2]) or (source == 0 and nil or source)
        if not target then return notify(source, 'Usage: cc godmode [id]', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        TriggerClientEvent('cuppa_admin:client:godmode', target)
        notify(source, 'Toggled godmode for player ' .. target, 'success')

    elseif cmd == 'visible' then
        if not hasPermission(source, 'visible') then return notify(source, 'No permission', 'error') end
        if source == 0 then return notify(source, 'Cannot use visible from console', 'error') end
        local target = tonumber(args[2])
        if not target then
            TriggerClientEvent('cuppa_admin:client:visibleGlobal', -1, source)
        else
            if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
            TriggerClientEvent('cuppa_admin:client:visible', source, target)
        end

    elseif cmd == 'hide' then
        if not hasPermission(source, 'hide') then return notify(source, 'No permission', 'error') end
        if source == 0 then return notify(source, 'Cannot use hide from console', 'error') end
        local exceptionId = tonumber(args[2])
        if not exceptionId then return notify(source, 'Usage: cc hide <id>', 'error') end
        if not exports.qbx_core:GetPlayer(exceptionId) then return notify(source, 'Player not found', 'error') end
        if exceptionId == source then return notify(source, 'Cannot hide from yourself', 'error') end

        hiddenState[source] = exceptionId

        local players = exports.qbx_core:GetQBPlayers()
        for id, _ in pairs(players) do
            local idNum = tonumber(id)
            if idNum ~= source and idNum ~= exceptionId then
                TriggerClientEvent('cuppa_admin:client:concealPlayer', idNum, source)
            elseif idNum == exceptionId then
                TriggerClientEvent('cuppa_admin:client:showPlayer', idNum, source)
            end
        end

        TriggerClientEvent('cuppa_admin:client:hideSelf', source, exceptionId)
        notify(source, 'Hidden from everyone except player ' .. exceptionId, 'success')

    elseif cmd == 'show' then
        if not hasPermission(source, 'hide') then return notify(source, 'No permission', 'error') end
        if source == 0 then return notify(source, 'Cannot use show from console', 'error') end
        if not hiddenState[source] then return notify(source, 'You are not hidden', 'error') end

        hiddenState[source] = nil

        local players = exports.qbx_core:GetQBPlayers()
        for id, _ in pairs(players) do
            local idNum = tonumber(id)
            if idNum ~= source then
                TriggerClientEvent('cuppa_admin:client:showPlayer', idNum, source)
            end
        end

        TriggerClientEvent('cuppa_admin:client:showSelf', source)
        notify(source, 'Visibility restored', 'success')

    elseif cmd == 'bucket' then
        if not hasPermission(source, 'bucket') then return notify(source, 'No permission', 'error') end
        if source == 0 then return notify(source, 'Cannot use bucket from console', 'error') end
        local sub = args[2]

        if not sub then
            local bucketId = bucketState[source]
            if not bucketId then
                bucketId = source
                bucketState[source] = bucketId
                bucketMembers[bucketId] = {}
                bucketAdmin[bucketId] = source
                SetPlayerRoutingBucket(source, bucketId)
                bucketMembers[bucketId][source] = true
                local adminLicense = getLicense(source)
                if adminLicense then bucketLicenses[adminLicense] = bucketId end
                notify(source, ('Created and joined bucket #%d'):format(bucketId), 'success')
            else
                local lines = {}
                local adminId = bucketAdmin[bucketId]
                local adminName = adminId and GetPlayerName(adminId) or 'Unknown'
                table.insert(lines, ('Bucket #%d (Admin: %s)'):format(bucketId, adminName))
                for memberId in pairs(bucketMembers[bucketId]) do
                    local name = GetPlayerName(memberId) or 'Unknown'
                    table.insert(lines, ('  - [%d] %s'):format(memberId, name))
                end
                for _, line in ipairs(lines) do
                    print('[cuppa_admin] ' .. line)
                end
                notify(source, 'Bucket status printed to console', 'inform')
            end

        elseif sub:sub(1, 1) == '-' then
            local target = tonumber(sub:sub(2))
            if not target then return notify(source, 'Usage: cc bucket -<id>', 'error') end
            local bucketId = bucketState[source]
            if not bucketId then return notify(source, 'You are not in a bucket', 'error') end
            if not bucketMembers[bucketId] or not bucketMembers[bucketId][target] then
                return notify(source, 'Player ' .. target .. ' is not in your bucket', 'error')
            end
            SetPlayerRoutingBucket(target, 0)
            bucketMembers[bucketId][target] = nil
            bucketState[target] = nil
            local targetLicense = getLicense(target)
            if targetLicense then bucketLicenses[targetLicense] = nil end
            notify(source, 'Removed player ' .. target .. ' from bucket #' .. bucketId, 'success')

        elseif sub == 'destroy' then
            local targetBucket = tonumber(args[3]) or bucketState[source]
            if not targetBucket then return notify(source, 'You are not in a bucket', 'error') end
            if not bucketMembers[targetBucket] then return notify(source, 'Bucket #' .. targetBucket .. ' does not exist', 'error') end
            if bucketAdmin[targetBucket] ~= source then return notify(source, 'You can only destroy your own bucket', 'error') end
            local count = 0
            for memberId in pairs(bucketMembers[targetBucket]) do
                SetPlayerRoutingBucket(memberId, 0)
                bucketState[memberId] = nil
                local memberLicense = getLicense(memberId)
                if memberLicense then bucketLicenses[memberLicense] = nil end
                count = count + 1
            end
            bucketMembers[targetBucket] = nil
            bucketAdmin[targetBucket] = nil
            notify(source, 'Bucket #' .. targetBucket .. ' dissolved — ' .. count .. ' player(s) returned to main world', 'success')

        elseif sub == 'wipe' then
            local totalPlayers = 0
            local totalBuckets = 0
            for bId, members in pairs(bucketMembers) do
                totalBuckets = totalBuckets + 1
                for memberId in pairs(members) do
                    SetPlayerRoutingBucket(memberId, 0)
                    bucketState[memberId] = nil
                    local memberLicense = getLicense(memberId)
                    if memberLicense then bucketLicenses[memberLicense] = nil end
                    totalPlayers = totalPlayers + 1
                end
            end
            bucketMembers = {}
            bucketAdmin = {}
            bucketLicenses = {}
            if totalBuckets == 0 then
                notify(source, 'No active buckets to wipe', 'inform')
            else
                notify(source, ('All buckets dissolved — %d player(s) returned to main world'):format(totalPlayers), 'success')
            end

        else
            local target = tonumber(sub)
            if not target then return notify(source, 'Usage: cc bucket <id> | cc bucket -<id> | cc bucket destroy | cc bucket wipe', 'error') end
            local bucketId = bucketState[source]
            if not bucketId then
                bucketId = source
                bucketState[source] = bucketId
                bucketMembers[bucketId] = {}
                bucketAdmin[bucketId] = source
                SetPlayerRoutingBucket(source, bucketId)
                bucketMembers[bucketId][source] = true
                local adminLicense = getLicense(source)
                if adminLicense then bucketLicenses[adminLicense] = bucketId end
            end
            if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
            if bucketMembers[bucketId][target] then
                return notify(source, 'Player ' .. target .. ' is already in bucket #' .. bucketId, 'error')
            end
            SetPlayerRoutingBucket(target, bucketId)
            bucketMembers[bucketId][target] = true
            bucketState[target] = bucketId
            local targetLicense = getLicense(target)
            if targetLicense then bucketLicenses[targetLicense] = bucketId end
            local memberCount = 0
            for _ in pairs(bucketMembers[bucketId]) do memberCount = memberCount + 1 end
            notify(source, ('Added player %d to bucket #%d — %d player(s) total'):format(target, bucketId, memberCount), 'success')
        end

    else
        notify(source, 'Unknown command: cc ' .. cmd .. ' — run "cc" for commands', 'error')
    end
end

RegisterCommand(config.prefix, function(source, args)
    handleCommand(source, args)
end, false)

--- Execute a command string as if typed in console. Returns captured output.
---@param cmdStr string Full command string (e.g. "kick 5" or "giveitem bread 3 5")
---@return string output
function executeCommand(cmdStr)
    local args = {}
    for word in cmdStr:gmatch('%S+') do
        args[#args + 1] = word
    end
    commandOutput = ''
    handleCommand(0, args)
    local output = commandOutput
    commandOutput = nil
    return output
end

AddEventHandler('playerDropped', function()
    local source = source
    if hiddenState[source] then
        hiddenState[source] = nil
        local players = exports.qbx_core:GetQBPlayers()
        for id, _ in pairs(players) do
            local idNum = tonumber(id)
            if idNum ~= source then
                TriggerClientEvent('cuppa_admin:client:showPlayer', idNum, source)
            end
        end
    end
    if bucketState[source] then
        local bucketId = bucketState[source]
        bucketState[source] = nil
        if bucketMembers[bucketId] then
            bucketMembers[bucketId][source] = nil
        end
    end
end)

AddEventHandler('playerJoining', function()
    local source = source
    local license = getLicense(source)
    if license and bucketLicenses[license] then
        local bucketId = bucketLicenses[license]
        SetPlayerRoutingBucket(source, bucketId)
        bucketState[source] = bucketId
        bucketMembers[bucketId] = bucketMembers[bucketId] or {}
        bucketMembers[bucketId][source] = true
    end
end)
