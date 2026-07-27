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

local function isValidModel(model)
    local hash = joaat(model)
    return hash ~= 0
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

local REFUND_CODE_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
local REFUND_EXPIRY = 86400 -- 24 hours

local function generateRefundCode()
    math.randomseed(os.time() + math.random(1000, 9999))
    local code = ''
    for i = 1, 6 do
        local idx = math.random(1, #REFUND_CODE_CHARS)
        code = code .. REFUND_CODE_CHARS:sub(idx, idx)
    end
    return code
end

-- Create refunds table + clean expired on startup
MySQL.ready(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS refunds (
            id INT AUTO_INCREMENT PRIMARY KEY,
            code VARCHAR(8) NOT NULL UNIQUE,
            admin_name VARCHAR(100) DEFAULT 'Console',
            items LONGTEXT NOT NULL,
            created_at INT NOT NULL,
            expires_at INT NOT NULL,
            claimed_by VARCHAR(200) DEFAULT NULL,
            claimed_at INT DEFAULT NULL,
            active TINYINT(1) DEFAULT 1
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await('UPDATE refunds SET active = 0 WHERE expires_at < ? AND active = 1', { os.time() })
    print('^2[cuppa_admin] Refunds table ready^0')
end)

-- Periodic expiry cleanup (every 10 minutes)
SetTimeout(600000, function()
    MySQL.query('UPDATE refunds SET active = 0 WHERE expires_at < ? AND active = 1', { os.time() })
end)

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
        {'cc terminal',                       'Toggle admin terminal GUI (in-game only)'},
        {'cc inventory <id>',                 'View a player\'s inventory'},
        {'cc vec2',                           'Copy vector2 coords to clipboard (in-game)'},
        {'cc vec3',                           'Copy vector3 coords to clipboard (in-game)'},
        {'cc vec4',                           'Copy vector4 coords + heading to clipboard (in-game)'},
        {'cc heading',                        'Copy heading to clipboard (in-game)'},
        {'cc names',                          'Toggle player names above heads'},
        {'cc blips',                          'Toggle player blips on map'},
        {'cc refundlist',                     'List all active refunds'},
        {'cc refundrevoke <code>',            'Revoke a refund by code'},
        {'/refund <code>',                    'Claim a refund using your code'},
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
    local lines = { '--- Online Players ---' }
    for id, player in pairs(players) do
        local name = player.PlayerData.charinfo.firstname .. ' ' .. player.PlayerData.charinfo.lastname
        local job = player.PlayerData.job.label
        lines[#lines + 1] = ('  ID: %s | Name: %s | Job: %s'):format(id, name, job)
    end
    lines[#lines + 1] = ('Total: %d player(s)'):format(#lines - 1)
    for _, line in ipairs(lines) do
        notify(source, line, 'inform')
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
                TriggerClientEvent('cuppa_admin:client:freeze', target, false)
                isFrozen[target] = nil
                notify(source, 'Unfroze player ' .. target, 'success')
            else
                TriggerClientEvent('cuppa_admin:client:freeze', target, true)
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
        local targetBucket = GetPlayerRoutingBucket(target)
        if GetPlayerRoutingBucket(source) ~= targetBucket then
            SetPlayerRoutingBucket(source, targetBucket)
        end
        TriggerClientEvent('cuppa_admin:client:goto', source, target)
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
        TriggerClientEvent('cuppa_admin:client:bring', target, { x = sourceCoords.x, y = sourceCoords.y, z = sourceCoords.z, w = GetEntityHeading(GetPlayerPed(source)) })
        notify(source, 'Brought player ' .. target, 'success')

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
        local arg2 = tonumber(args[2])
        local arg3 = tonumber(args[3])
        -- If only one arg: check if it's a player ID (no vehicle near = radius would be meaningless)
        -- If two args: first is radius, second is player ID
        local radius, target
        if arg2 and arg3 then
            radius = math.min(arg2, MAX_DV_RADIUS)
            target = arg3
        elseif arg2 then
            -- Single arg: try as player ID first, fallback to radius with self as target
            if exports.qbx_core:GetPlayer(arg2) then
                target = arg2
            else
                radius = math.min(arg2, MAX_DV_RADIUS)
                target = source
            end
        else
            target = source
        end
        if target == 0 then return notify(source, 'Console requires a player ID', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        if radius then
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
            TriggerClientEvent('cuppa_admin:client:tpToCoords', targetA, coords)
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
                TriggerClientEvent('cuppa_admin:client:goto', source, targetA)
                notify(source, 'Teleported to player ' .. targetA, 'success')
            elseif targetA and targetB then
                if not exports.qbx_core:GetPlayer(targetA) then return notify(source, 'Player ' .. targetA .. ' not found', 'error') end
                if not exports.qbx_core:GetPlayer(targetB) then return notify(source, 'Player ' .. targetB .. ' not found', 'error') end
                local coords = GetEntityCoords(GetPlayerPed(targetB))
                local targetBucket = GetPlayerRoutingBucket(targetB)
                if GetPlayerRoutingBucket(targetA) ~= targetBucket then
                    SetPlayerRoutingBucket(targetA, targetBucket)
                end
                TriggerClientEvent('cuppa_admin:client:tpToCoords', targetA, coords)
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

    elseif cmd == 'terminal' then
        if source == 0 then return notify(source, 'Cannot use terminal from console', 'error') end
        if not hasPermission(source, 'terminal') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:terminalToggle', source)

    elseif cmd == 'inventory' then
        if not hasPermission(source, 'inventory') then return notify(source, 'No permission', 'error') end
        local target = tonumber(args[2])
        if not target then return notify(source, 'Usage: cc inventory <id>', 'error') end
        if not exports.qbx_core:GetPlayer(target) then return notify(source, 'Player not found', 'error') end
        local items = exports.ox_inventory:GetInventoryItems(target)
        if not items or not next(items) then
            notify(source, 'Player ' .. target .. ' has no items', 'inform')
        else
            print('^2[cuppa_admin] Inventory for player ' .. target .. ':^0')
            local totalSlots = 0
            for _, item in pairs(items) do
                if item.slot then totalSlots = math.max(totalSlots, item.slot) end
                local label = item.label or item.name
                print(('  Slot %s | %s (%s) x%d'):format(item.slot or '?', label, item.name, item.count or 0))
            end
            notify(source, 'Inventory printed to console (' .. #items .. ' items)', 'inform')
        end

    elseif cmd == 'vec2' then
        if source == 0 then return notify(source, 'Cannot use vec2 from console', 'error') end
        if not hasPermission(source, 'dev') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:copyCoords', source, 'vec2')
        notify(source, 'Copying vector2 to clipboard...', 'inform')

    elseif cmd == 'vec3' then
        if source == 0 then return notify(source, 'Cannot use vec3 from console', 'error') end
        if not hasPermission(source, 'dev') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:copyCoords', source, 'vec3')
        notify(source, 'Copying vector3 to clipboard...', 'inform')

    elseif cmd == 'vec4' then
        if source == 0 then return notify(source, 'Cannot use vec4 from console', 'error') end
        if not hasPermission(source, 'dev') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:copyCoords', source, 'vec4')
        notify(source, 'Copying vector4 to clipboard...', 'inform')

    elseif cmd == 'heading' then
        if source == 0 then return notify(source, 'Cannot use heading from console', 'error') end
        if not hasPermission(source, 'dev') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:copyCoords', source, 'heading')
        notify(source, 'Copying heading to clipboard...', 'inform')

    elseif cmd == 'names' then
        if source == 0 then return notify(source, 'Cannot use names from console', 'error') end
        if not hasPermission(source, 'names') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:names', source)

    elseif cmd == 'blips' then
        if source == 0 then return notify(source, 'Cannot use blips from console', 'error') end
        if not hasPermission(source, 'blips') then return notify(source, 'No permission', 'error') end
        TriggerClientEvent('cuppa_admin:client:blips', source)

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

    elseif cmd == 'refundlist' then
        if not hasPermission(source, 'refundlist') then return notify(source, 'No permission', 'error') end
        MySQL.query('SELECT code, admin_name, items, created_at, expires_at, claimed_by FROM refunds WHERE active = 1 AND claimed_by IS NULL AND expires_at > ? ORDER BY created_at DESC', { os.time() }, function(rows)
            if not rows or #rows == 0 then
                notify(source, 'No active refunds', 'inform')
                return
            end
            print('^2[cuppa_admin] Active Refunds:^0')
            for _, r in ipairs(rows) do
                local items = json.decode(r.items)
                local count = 0
                for _, it in ipairs(items) do count = count + (it.count or 1) end
                local remaining = r.expires_at - os.time()
                local hours = math.floor(remaining / 3600)
                local mins = math.floor((remaining % 3600) / 60)
                print(('  ^3%s^0 | %d item(s) | by %s | expires in %dh %dm'):format(r.code, count, r.admin_name, hours, mins))
            end
            print('')
        end)

    elseif cmd == 'refundrevoke' then
        if not hasPermission(source, 'refundlist') then return notify(source, 'No permission', 'error') end
        local code = args[2] and args[2]:upper() or nil
        if not code then return notify(source, 'Usage: cc refundrevoke <code>', 'error') end
        MySQL.update('UPDATE refunds SET active = 0 WHERE code = ? AND active = 1 AND claimed_by IS NULL', { code }, function(affected)
            if affected and affected > 0 then
                logAdminAction('Refund Revoked', 'Code: ' .. code, source == 0 and 'Console' or GetPlayerName(source))
                notify(source, 'Revoked refund: ' .. code, 'success')
            else
                notify(source, 'Refund not found or already used/expired', 'error')
            end
        end)

    else
        notify(source, 'Unknown command: cc ' .. cmd .. ' — run "cc" for commands', 'error')
    end
end

RegisterCommand(config.prefix, function(source, args)
    handleCommand(source, args)
end, false)

--- Execute a command string as if typed in console. Returns captured output.
---@param cmdStr string Full command string (e.g. "kick 5" or "giveitem bread 3 5")
---@param execSource number|nil Player source to execute as (nil = console)
---@return string output
function executeCommand(cmdStr, execSource)
    local args = {}
    for word in cmdStr:gmatch('%S+') do
        args[#args + 1] = word
    end
    commandOutput = ''
    handleCommand(execSource or 0, args)
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

-- ── Terminal GUI events ──

RegisterNetEvent('cuppa_admin:server:requestTerminal', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then
        TriggerClientEvent('cuppa_admin:client:terminalOutput', source, 'No permission')
        return
    end
    TriggerClientEvent('cuppa_admin:client:terminalOpen', source)
end)

RegisterNetEvent('cuppa_admin:server:terminalCmd', function(cmdStr)
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local output = executeCommand(cmdStr, source)
    if output and output ~= '' then
        TriggerClientEvent('cuppa_admin:client:terminalOutput', source, output)
    end
end)

RegisterNetEvent('cuppa_admin:server:requestPlayerList', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local players = exports.qbx_core:GetQBPlayers()
    local list = {}
    for id, player in pairs(players) do
        local idNum = tonumber(id)
        local ped = GetPlayerPed(idNum)
        list[#list + 1] = {
            id = idNum,
            name = player.PlayerData.charinfo.firstname .. ' ' .. player.PlayerData.charinfo.lastname,
            job = player.PlayerData.job.label,
            jobGrade = player.PlayerData.job.grade.name or ('Grade ' .. player.PlayerData.job.grade.level),
            gang = player.PlayerData.gang.name ~= 'none' and player.PlayerData.gang.label or nil,
            cash = player.PlayerData.money.cash,
            bank = player.PlayerData.money.bank,
            health = ped and GetEntityHealth(ped) or 200,
            armor = player.PlayerData.metadata.armor or 0,
        }
    end
    TriggerClientEvent('cuppa_admin:client:playerList', source, list)
end)

RegisterNetEvent('cuppa_admin:server:requestInventory', function(targetId)
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    if not exports.qbx_core:GetPlayer(targetId) then
        TriggerClientEvent('cuppa_admin:client:inventoryResult', source, nil, 'Player not found')
        return
    end
    local items = exports.ox_inventory:GetInventoryItems(targetId)
    local list = {}
    if items then
        for _, item in pairs(items) do
            list[#list + 1] = {
                slot = item.slot,
                name = item.name,
                label = item.label or item.name,
                count = item.count or 0,
                weight = item.weight or 0,
                metadata = item.metadata,
            }
        end
    end
    TriggerClientEvent('cuppa_admin:client:inventoryResult', source, list, nil)
end)

RegisterNetEvent('cuppa_admin:server:removeItem', function(data)
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local targetId = data.playerId
    local slot = data.slot
    local itemName = data.name
    if not targetId or not slot or not itemName then return end
    if not exports.qbx_core:GetPlayer(targetId) then
        TriggerClientEvent('cuppa_admin:client:inventoryResult', source, nil, 'Player not found')
        return
    end
    local ok = exports.ox_inventory:RemoveItem(targetId, itemName, 1, nil, slot)
    if ok then
        local items = exports.ox_inventory:GetInventoryItems(targetId)
        local list = {}
        if items then
            for _, item in pairs(items) do
                list[#list + 1] = {
                    slot = item.slot,
                    name = item.name,
                    label = item.label or item.name,
                    count = item.count or 0,
                    weight = item.weight or 0,
                    metadata = item.metadata,
                }
            end
        end
        TriggerClientEvent('cuppa_admin:client:inventoryResult', source, list, nil)
    else
        TriggerClientEvent('cuppa_admin:client:terminalOutput', source, 'Failed to remove item')
    end
end)

-- ── Item/Job/Gang list for modal pickers ──

RegisterNetEvent('cuppa_admin:server:getItems', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local allItems = exports.ox_inventory:Items()
    local list = {}
    if allItems then
        for name, item in pairs(allItems) do
            list[#list + 1] = {
                name = name,
                label = item.label or name,
            }
        end
        table.sort(list, function(a, b) return a.label < b.label end)
    end
    TriggerClientEvent('cuppa_admin:client:itemList', source, list)
end)

RegisterNetEvent('cuppa_admin:server:getJobs', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local jobs = exports.qbx_core:GetJobs()
    local list = {}
    for name, job in pairs(jobs) do
        list[#list + 1] = { name = name, label = job.label or name }
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    TriggerClientEvent('cuppa_admin:client:jobList', source, list)
end)

RegisterNetEvent('cuppa_admin:server:getGangs', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'terminal') then return end
    local gangs = exports.qbx_core:GetGangs()
    local list = {}
    for name, gang in pairs(gangs) do
        list[#list + 1] = { name = name, label = gang.label or name }
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    TriggerClientEvent('cuppa_admin:client:gangList', source, list)
end)

-- ── Refund System ──

RegisterNetEvent('cuppa_admin:server:createRefund', function(data)
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'refund') then
        TriggerClientEvent('cuppa_admin:client:refundCreated', source, nil, 'No permission')
        return
    end
    local items = data.items
    if not items or type(items) ~= 'table' or #items == 0 then
        TriggerClientEvent('cuppa_admin:client:refundCreated', source, nil, 'No items provided')
        return
    end
    for i, item in ipairs(items) do
        if type(item) ~= 'table' or not item.name or not tostring(item.name):match('^[%w_]+$') then
            TriggerClientEvent('cuppa_admin:client:refundCreated', source, nil, 'Invalid item at position ' .. i)
            return
        end
        if not item.count or item.count < 1 then items[i].count = 1 end
        if items[i].count > MAX_GIVEITEM then items[i].count = MAX_GIVEITEM end
    end
    -- try up to 5 times for unique code
    local code = nil
    for attempt = 1, 5 do
        local candidate = generateRefundCode()
        local exists = MySQL.scalar.await('SELECT COUNT(*) FROM refunds WHERE code = ?', { candidate })
        if exists == 0 then
            code = candidate
            break
        end
    end
    if not code then
        TriggerClientEvent('cuppa_admin:client:refundCreated', source, nil, 'Failed to generate unique code')
        return
    end
    local adminName = GetPlayerName(source) or 'Console'
    local now = os.time()
    MySQL.insert('INSERT INTO refunds (code, admin_name, items, created_at, expires_at, active) VALUES (?, ?, ?, ?, ?, 1)', {
        code, adminName, json.encode(items), now, now + REFUND_EXPIRY
    }, function(id)
        if id then
            logAdminAction('Refund Created', ('Code: %s | %d item(s)'):format(code, #items), adminName)
            TriggerClientEvent('cuppa_admin:client:refundCreated', source, code, nil)
        else
            TriggerClientEvent('cuppa_admin:client:refundCreated', source, nil, 'Database error')
        end
    end)
end)

RegisterNetEvent('cuppa_admin:server:getRefunds', function()
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'refundlist') then
        TriggerClientEvent('cuppa_admin:client:refundsList', source, {})
        return
    end
    local now = os.time()
    MySQL.query('SELECT code, admin_name, items, created_at, expires_at FROM refunds WHERE active = 1 AND claimed_by IS NULL AND expires_at > ? ORDER BY created_at DESC', { now }, function(rows)
        local list = {}
        if rows then
            for _, r in ipairs(rows) do
                local items = json.decode(r.items)
                local totalItems = 0
                for _, it in ipairs(items) do totalItems = totalItems + (it.count or 1) end
                list[#list + 1] = {
                    code = r.code,
                    adminName = r.admin_name,
                    items = items,
                    totalItems = totalItems,
                    createdAt = r.created_at,
                    expiresAt = r.expires_at,
                    remaining = r.expires_at - now,
                }
            end
        end
        TriggerClientEvent('cuppa_admin:client:refundsList', source, list)
    end)
end)

RegisterNetEvent('cuppa_admin:server:revokeRefund', function(data)
    local source = source
    if not source or source == 0 then return end
    if not hasPermission(source, 'refundlist') then
        TriggerClientEvent('cuppa_admin:client:refundRevoked', source, 'No permission')
        return
    end
    local code = data.code and data.code:upper() or nil
    if not code then
        TriggerClientEvent('cuppa_admin:client:refundRevoked', source, 'No code provided')
        return
    end
    MySQL.update('UPDATE refunds SET active = 0 WHERE code = ? AND active = 1 AND claimed_by IS NULL', { code }, function(affected)
        if affected and affected > 0 then
            logAdminAction('Refund Revoked', 'Code: ' .. code, GetPlayerName(source) or 'Console')
            TriggerClientEvent('cuppa_admin:client:refundRevoked', source, nil)
        else
            TriggerClientEvent('cuppa_admin:client:refundRevoked', source, 'Refund not found or already used/expired')
        end
    end)
end)

RegisterNetEvent('cuppa_admin:server:claimRefund', function(code)
    local source = source
    if not source or source == 0 then return end
    if not code or code == '' then
        TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'Usage: /refund <code>')
        return
    end
    code = code:upper()
    MySQL.single('SELECT id, items, expires_at, active, claimed_by FROM refunds WHERE code = ?', { code }, function(row)
        if not row then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'Invalid refund code')
            return
        end
        if not row.active or row.active == 0 then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has been revoked')
            return
        end
        if row.claimed_by then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has already been claimed')
            return
        end
        if row.expires_at < os.time() then
            MySQL.query.await('UPDATE refunds SET active = 0 WHERE id = ?', { row.id })
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has expired')
            return
        end
        local items = json.decode(row.items)
        TriggerClientEvent('cuppa_admin:client:refundClaimItems', source, code, row.id, items)
    end)
end)

RegisterNetEvent('cuppa_admin:server:confirmClaimRefund', function(data)
    local source = source
    if not source or source == 0 then return end
    local code = data.code
    local refundId = data.refundId
    local selectedItems = data.items
    if not code or not refundId or not selectedItems or #selectedItems == 0 then
        TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'No items selected')
        return
    end
    MySQL.single('SELECT id, items, expires_at, active, claimed_by FROM refunds WHERE code = ? AND id = ?', { code, refundId }, function(row)
        if not row then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'Refund not found')
            return
        end
        if not row.active or row.active == 0 then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has been revoked')
            return
        end
        if row.claimed_by then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has already been claimed')
            return
        end
        if row.expires_at < os.time() then
            MySQL.query.await('UPDATE refunds SET active = 0 WHERE id = ?', { row.id })
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'This refund has expired')
            return
        end
        local allItems = json.decode(row.items)
        local allowed = {}
        for _, item in ipairs(allItems) do
            allowed[item.name] = item
        end
        local playerName = GetPlayerName(source) or 'Unknown'
        local given = {}
        local failed = {}
        for _, sel in ipairs(selectedItems) do
            local template = allowed[sel.name]
            if template then
                local count = math.max(1, math.min(MAX_GIVEITEM, sel.count or template.count or 1))
                local meta = sel.metadata or template.metadata or {}
                local ok = exports.ox_inventory:AddItem(source, sel.name, count, meta)
                if ok then
                    given[#given + 1] = count .. 'x ' .. (template.label or sel.name)
                else
                    failed[#failed + 1] = count .. 'x ' .. (template.label or sel.name)
                end
            end
        end
        if #given == 0 then
            TriggerClientEvent('cuppa_admin:client:refundClaimed', source, false, 'No items could be given (inventory full?)')
            return
        end
        MySQL.query.await('UPDATE refunds SET active = 0, claimed_by = ?, claimed_at = ? WHERE id = ?', {
            playerName .. ' (' .. (GetPlayerIdentifierByType(source, 'license') or 'unknown') .. ')',
            os.time(),
            row.id,
        })
        local msg = 'Claimed: ' .. table.concat(given, ', ')
        if #failed > 0 then
            msg = msg .. ' | Failed (inventory full?): ' .. table.concat(failed, ', ')
        end
        logAdminAction('Refund Claimed', ('Code: %s | By: %s'):format(code, playerName), 'System')
        TriggerClientEvent('cuppa_admin:client:refundClaimed', source, true, msg)
    end)
end)
