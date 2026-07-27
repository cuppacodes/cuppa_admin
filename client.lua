local noclipEnabled = false
local noclipCam = nil
local noclipSpeed = 1.0
local noclipMaxSpeed = 32.0
local noclipEnt = nil
local noclipInVehicle = false
local godmode = false
local hiddenFrom = {}
local hiddenPeds = {} -- entity handles we've set invisible (for restore)
local concealedPlayers = {}
local myHideException = nil
local terminalOpen = false

local noclipDisableControls = { 32, 33, 34, 35, 36, 12, 13, 14, 15, 16, 17 }

local function registerCCSuggestion()
    TriggerEvent('chat:addSuggestion', '/cc', 'Admin commands — type /cc for full list', {
        { name = 'subcommand', help = 'stats, kick, ban, baninfo, undo, announce, heal, kill, revive, freeze, unfreeze, goto, bring, car, tp, godmode, noclip, ...' },
    })
    TriggerEvent('chat:addSuggestion', '/refund', 'Claim a refund using your code', {
        { name = 'code', help = 'The refund code (e.g. A3X9K2)' },
    })
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    registerCCSuggestion()
end)

RegisterNetEvent('qbx_core:client:onPlayerLoaded', function()
    registerCCSuggestion()
end)

RegisterNetEvent('cuppa_admin:client:announce', function(msg)
    if GetInvokingResource() then return end
    lib.notify({ title = 'Server Announcement', description = msg, type = 'inform', duration = 10000 })
end)

RegisterNetEvent('cuppa_admin:client:kill', function()
    if GetInvokingResource() then return end
    SetEntityHealth(cache.ped, 0)
end)

RegisterNetEvent('cuppa_admin:client:fixVehicle', function()
    if GetInvokingResource() then return end
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle == 0 then return end
    SetVehicleFixed(vehicle)
    SetVehicleDirtLevel(vehicle, 0.0)
end)

RegisterNetEvent('cuppa_admin:client:deleteVehicle', function()
    if GetInvokingResource() then return end
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle == 0 then return end
    DeleteEntity(vehicle)
end)

RegisterNetEvent('cuppa_admin:client:setModel', function(model)
    if GetInvokingResource() then return end
    lib.requestModel(model)
    SetPlayerModel(cache.playerId, model)
    SetModelAsNoLongerNeeded(model)
end)

RegisterNetEvent('cuppa_admin:client:godmode', function()
    if GetInvokingResource() then return end
    godmode = not godmode
    SetEntityInvincible(cache.ped, godmode)
    if godmode then
        CreateThread(function()
            while godmode do
                Wait(0)
                SetEntityInvincible(cache.ped, true)
                SetPlayerInvisibleLocally(cache.playerId, false)
            end
        end)
    end
end)

RegisterNetEvent('cuppa_admin:client:visibleGlobal', function(requestor)
    if GetInvokingResource() then return end
    if cache.playerId == requestor then return end
    hiddenFrom[requestor] = not hiddenFrom[requestor] or nil
end)

RegisterNetEvent('cuppa_admin:client:visible', function(target)
    if GetInvokingResource() then return end
    hiddenFrom[target] = not hiddenFrom[target] or nil
end)

RegisterNetEvent('cuppa_admin:client:concealPlayer', function(serverId)
    if GetInvokingResource() then return end
    concealedPlayers[serverId] = true
end)

RegisterNetEvent('cuppa_admin:client:showPlayer', function(serverId)
    if GetInvokingResource() then return end
    concealedPlayers[serverId] = nil
end)

RegisterNetEvent('cuppa_admin:client:hideSelf', function(exceptionId)
    if GetInvokingResource() then return end
    myHideException = exceptionId
end)

RegisterNetEvent('cuppa_admin:client:showSelf', function()
    if GetInvokingResource() then return end
    myHideException = nil
end)

CreateThread(function()
    while true do
        local sleep = 1000
        local myId = cache.playerId
        local myPed = cache.ped
        local players = GetActivePlayers()
        local currentHidden = {}

        for _, playerIdx in ipairs(players) do
            local serverId = GetPlayerServerId(playerIdx)
            if serverId ~= myId then
                local targetPed = GetPlayerPed(playerIdx)

                if hiddenFrom[serverId] then
                    sleep = 250
                    if targetPed and targetPed ~= 0 then
                        SetEntityVisible(targetPed, false, false)
                        currentHidden[targetPed] = true
                    end
                end

                if concealedPlayers[serverId] then
                    sleep = 250
                    if targetPed and targetPed ~= 0 then
                        NetworkConcealPlayer(playerIdx, true, false)
                        SetEntityNoCollisionEntity(myPed, targetPed, false)
                        MumbleSetVolumeOverrideByServerId(serverId, 0.0)
                    end
                end

                if myHideException and serverId ~= myHideException then
                    sleep = 250
                    if targetPed and targetPed ~= 0 then
                        NetworkConcealPlayer(playerIdx, true, false)
                        SetEntityNoCollisionEntity(myPed, targetPed, false)
                        MumbleSetVolumeOverrideByServerId(serverId, 0.0)
                    end
                end
            end
        end

        for ped in pairs(hiddenPeds) do
            if not currentHidden[ped] and DoesEntityExist(ped) then
                SetEntityVisible(ped, true, false)
            end
        end
        hiddenPeds = currentHidden

        Wait(sleep)
    end
end)

local function startNoclip()
    noclipEnabled = true

    CreateThread(function()
        if cache.vehicle then
            noclipInVehicle = true
            noclipEnt = cache.vehicle
        else
            noclipInVehicle = false
            noclipEnt = cache.ped
        end

        local pos = GetEntityCoords(noclipEnt)
        local rot = GetEntityRotation(noclipEnt)
        noclipCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', pos.x, pos.y, pos.z, 0.0, 0.0, rot.z, 75.0, true, 2)
        AttachCamToEntity(noclipCam, noclipEnt, 0.0, 0.0, 0.0, true)
        RenderScriptCams(true, false, 3000, true, false)
        FreezeEntityPosition(noclipEnt, true)
        SetEntityCollision(noclipEnt, false, false)
        SetEntityAlpha(noclipEnt, 0, false)
        SetPedCanRagdoll(cache.ped, false)
        SetEntityVisible(noclipEnt, false, false)

        if not noclipInVehicle then
            ClearPedTasksImmediately(cache.ped)
        end

        if noclipInVehicle then
            FreezeEntityPosition(cache.ped, true)
            SetEntityCollision(cache.ped, false, false)
            SetEntityAlpha(cache.ped, 0, false)
            SetEntityVisible(cache.ped, false, false)
        end

        while noclipEnabled do
            Wait(0)
            local _, fv = GetCamMatrix(noclipCam)

            if IsDisabledControlPressed(2, 17) then
                noclipSpeed = math.min(noclipSpeed + 0.1, noclipMaxSpeed)
            elseif IsDisabledControlPressed(2, 16) then
                noclipSpeed = math.max(0.1, noclipSpeed - 0.1)
            end

            local multiplier = 1.0
            if IsDisabledControlPressed(2, 209) then
                multiplier = 2.0
            elseif IsDisabledControlPressed(2, 19) then
                multiplier = 4.0
            elseif IsDisabledControlPressed(2, 36) then
                multiplier = 0.25
            end

            if IsDisabledControlPressed(2, 32) then
                local setPos = GetEntityCoords(noclipEnt) + fv * (noclipSpeed * multiplier)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            elseif IsDisabledControlPressed(2, 33) then
                local setPos = GetEntityCoords(noclipEnt) - fv * (noclipSpeed * multiplier)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            end

            if IsDisabledControlPressed(2, 34) then
                local setPos = GetOffsetFromEntityInWorldCoords(noclipEnt, -noclipSpeed * multiplier, 0.0, 0.0)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            elseif IsDisabledControlPressed(2, 35) then
                local setPos = GetOffsetFromEntityInWorldCoords(noclipEnt, noclipSpeed * multiplier, 0.0, 0.0)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            end

            if IsDisabledControlPressed(2, 51) then
                local setPos = GetOffsetFromEntityInWorldCoords(noclipEnt, 0.0, 0.0, multiplier * noclipSpeed / 2)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            elseif IsDisabledControlPressed(2, 52) then
                local setPos = GetOffsetFromEntityInWorldCoords(noclipEnt, 0.0, 0.0, multiplier * -noclipSpeed / 2)
                SetEntityCoordsNoOffset(noclipEnt, setPos.x, setPos.y, setPos.z, false, false, false)
                if not noclipInVehicle then
                    SetEntityCoordsNoOffset(cache.ped, setPos.x, setPos.y, setPos.z, false, false, false)
                end
            end

            local camRot = GetCamRot(noclipCam, 2)
            SetEntityHeading(noclipEnt, (360 + camRot.z) % 360)
            SetEntityVisible(noclipEnt, false, false)

            if noclipInVehicle then
                SetEntityVisible(cache.ped, false, false)
            end

            for i = 1, #noclipDisableControls do
                DisableControlAction(2, noclipDisableControls[i], true)
            end
            DisablePlayerFiring(cache.playerId, true)
        end

        DestroyCam(noclipCam, false)
        noclipCam = nil
        RenderScriptCams(false, false, 3000, true, false)
        FreezeEntityPosition(noclipEnt, false)
        SetEntityCollision(noclipEnt, true, true)
        ResetEntityAlpha(noclipEnt)
        SetPedCanRagdoll(cache.ped, true)
        SetEntityVisible(noclipEnt, true, false)
        ClearPedTasksImmediately(cache.ped)

        if noclipInVehicle then
            FreezeEntityPosition(cache.ped, false)
            SetEntityCollision(cache.ped, true, true)
            ResetEntityAlpha(cache.ped)
            SetEntityVisible(cache.ped, true, false)
            SetPedIntoVehicle(cache.ped, noclipEnt, -1)
        end

        noclipEnt = nil
        noclipInVehicle = false
    end)
end

local function startNoclipCameraRotation()
    CreateThread(function()
        while noclipEnabled do
            while not noclipCam or IsPauseMenuActive() do Wait(0) end
            local axisX = GetDisabledControlNormal(0, 1)
            local axisY = GetDisabledControlNormal(0, 2)
            local sensitivity = GetProfileSetting(14) * 2

            if GetProfileSetting(15) == 0 then
                sensitivity = -sensitivity
            end

            if math.abs(axisX) > 0 or math.abs(axisY) > 0 then
                local rotation = GetCamRot(noclipCam, 2)
                local rotz = rotation.z + (axisX * sensitivity)
                local yValue = axisY * sensitivity
                local rotx = rotation.x
                if rotx + yValue > -150 and rotx + yValue < 160 then
                    rotx = rotation.x + yValue
                end
                SetCamRot(noclipCam, rotx, rotation.y, rotz, 2)
            end
            Wait(0)
        end
    end)
end

RegisterNetEvent('cuppa_admin:client:noclip', function()
    if GetInvokingResource() then return end
    noclipEnabled = not noclipEnabled
    if noclipEnabled then
        startNoclip()
        startNoclipCameraRotation()
    end
end)

RegisterNetEvent('cuppa_admin:client:warpIntoVehicle', function(vehicleNet, seat)
    if GetInvokingResource() then return end
    local vehicle = NetworkGetEntityFromNetworkId(vehicleNet)
    if vehicle and vehicle ~= 0 then
        TaskWarpPedIntoVehicle(cache.ped, vehicle, seat)
    end
end)

RegisterNetEvent('cuppa_admin:client:bring', function(coords)
    if GetInvokingResource() then return end
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle and vehicle ~= 0 then
        SetEntityCoords(vehicle, coords.x, coords.y, coords.z, false, false, false, false)
        SetEntityHeading(vehicle, coords.w or 0.0)
    end
    SetEntityCoords(cache.ped, coords.x, coords.y, coords.z + 2.0, false, false, false, false)
end)

RegisterNetEvent('cuppa_admin:client:freeze', function(state)
    if GetInvokingResource() then return end
    FreezeEntityPosition(cache.ped, state)
end)

RegisterNetEvent('cuppa_admin:client:goto', function(targetId)
    if GetInvokingResource() then return end
    local targetPed = GetPlayerPed(GetPlayerFromServerId(targetId))
    if not targetPed or targetPed == 0 then return end
    local vehicle = GetVehiclePedIsIn(targetPed, false)
    if vehicle and vehicle ~= 0 then
        local netId = NetworkGetNetworkIdFromEntity(vehicle)
        if netId and netId ~= 0 then
            local seat = 1
            local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)
            for i = -1, maxPassengers - 1 do
                if IsVehicleSeatFree(vehicle, i) then
                    seat = i
                    break
                end
            end
            TaskWarpPedIntoVehicle(cache.ped, vehicle, seat)
            return
        end
    end
    local coords = GetEntityCoords(targetPed)
    SetEntityCoords(cache.ped, coords.x, coords.y, coords.z, false, false, false, false)
end)

RegisterNetEvent('cuppa_admin:client:tpToCoords', function(coords)
    if GetInvokingResource() then return end
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle and vehicle ~= 0 then
        SetEntityCoords(vehicle, coords.x, coords.y, coords.z, false, false, false, false)
    end
    SetEntityCoords(cache.ped, coords.x, coords.y, coords.z, false, false, false, false)
end)

-- ── Terminal GUI ──

local function openTerminalNow()
    terminalOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open' })
    TriggerServerEvent('cuppa_admin:server:requestPlayerList')
end

local function toggleTerminal()
    if not terminalOpen then
        TriggerServerEvent('cuppa_admin:server:requestTerminal')
    else
        terminalOpen = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })
    end
end

RegisterNetEvent('cuppa_admin:client:terminalOpen', function()
    if GetInvokingResource() then return end
    openTerminalNow()
end)

RegisterNetEvent('cuppa_admin:client:terminalToggle', function()
    if GetInvokingResource() then return end
    openTerminalNow()
end)

RegisterNetEvent('cuppa_admin:client:terminalOutput', function(text)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'output', text = text })
end)

RegisterNetEvent('cuppa_admin:client:playerList', function(list)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'playerList', players = list })
end)

RegisterNUICallback('executeCommand', function(data, cb)
    if data.command then
        TriggerServerEvent('cuppa_admin:server:terminalCmd', data.command)
    end
    cb('ok')
end)

RegisterNUICallback('closeTerminal', function(_, cb)
    if terminalOpen then
        terminalOpen = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })
    end
    cb('ok')
end)

RegisterNUICallback('refreshPlayers', function(_, cb)
    TriggerServerEvent('cuppa_admin:server:requestPlayerList')
    cb('ok')
end)

RegisterNUICallback('requestInventory', function(data, cb)
    if data.playerId then
        TriggerServerEvent('cuppa_admin:server:requestInventory', data.playerId)
    end
    cb('ok')
end)

RegisterNUICallback('removeItem', function(data, cb)
    if data.playerId and data.slot and data.name then
        TriggerServerEvent('cuppa_admin:server:removeItem', { playerId = data.playerId, slot = data.slot, name = data.name })
    end
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:inventoryResult', function(items, error)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'inventoryResult', items = items, error = error })
end)

-- ── Item/Job/Gang list fetchers ──

RegisterNUICallback('getItems', function(_, cb)
    TriggerServerEvent('cuppa_admin:server:getItems')
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:itemList', function(items)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'itemList', items = items })
end)

RegisterNUICallback('getJobs', function(_, cb)
    TriggerServerEvent('cuppa_admin:server:getJobs')
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:jobList', function(jobs)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'jobList', jobs = jobs })
end)

RegisterNUICallback('getGangs', function(_, cb)
    TriggerServerEvent('cuppa_admin:server:getGangs')
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:gangList', function(gangs)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'gangList', gangs = gangs })
end)

RegisterKeyMapping('cc_terminal', 'Toggle Admin Terminal', 'keyboard', 'F3')
RegisterCommand('cc_terminal', function()
    toggleTerminal()
end, false)

-- ── Coordinate copy (vec2/vec3/vec4/heading) ──

RegisterNetEvent('cuppa_admin:client:copyCoords', function(dataType)
    if GetInvokingResource() then return end
    local coords = GetEntityCoords(cache.ped)
    local x = math.round(coords.x, 2)
    local y = math.round(coords.y, 2)
    local z = math.round(coords.z - 1.0, 2)
    local h = math.round(GetEntityHeading(cache.ped), 2)

    local data
    if dataType == 'vec2' then
        data = ('vec2(%s, %s)'):format(x, y)
    elseif dataType == 'vec3' then
        data = ('vec3(%s, %s, %s)'):format(x, y, z)
    elseif dataType == 'vec4' then
        data = ('vec4(%s, %s, %s, %s)'):format(x, y, z, h)
    elseif dataType == 'heading' then
        data = tostring(h)
    end

    if data then
        SendNUIMessage({ action = 'output', text = dataType .. ' copied: ' .. data, type = 'success' })
        lib.setClipboard(data)
        lib.notify({ title = 'cuppa_admin', description = dataType .. ' copied to clipboard', type = 'success' })
    end
end)

-- ── Names toggle ──

local showNames = false
local nameTags = {}

RegisterNetEvent('cuppa_admin:client:names', function()
    if GetInvokingResource() then return end
    showNames = not showNames
    if showNames then
        lib.notify({ title = 'cuppa_admin', description = 'Player names enabled', type = 'success' })
    else
        lib.notify({ title = 'cuppa_admin', description = 'Player names disabled', type = 'error' })
        for _, tag in pairs(nameTags) do
            RemoveMpGamerTag(tag)
        end
        nameTags = {}
    end
end)

-- ── Blips toggle ──

local showBlips = false
local playerBlips = {}

RegisterNetEvent('cuppa_admin:client:blips', function()
    if GetInvokingResource() then return end
    showBlips = not showBlips
    if showBlips then
        lib.notify({ title = 'cuppa_admin', description = 'Player blips enabled', type = 'success' })
    else
        lib.notify({ title = 'cuppa_admin', description = 'Player blips disabled', type = 'error' })
        for _, blip in pairs(playerBlips) do
            RemoveBlip(blip)
        end
        playerBlips = {}
    end
end)

-- ── Names + Blips render loop ──

CreateThread(function()
    while true do
        local sleep = 1000
        if showNames or showBlips then
            sleep = 0
            local myId = cache.playerId
            local myCoords = GetEntityCoords(cache.ped)

            local players = GetActivePlayers()
            for _, playerIdx in ipairs(players) do
                local serverId = GetPlayerServerId(playerIdx)
                if serverId ~= myId then
                    local ped = GetPlayerPed(playerIdx)

                    -- Names
                    if showNames then
                        local name = ('ID: %d | %s'):format(serverId, GetPlayerName(playerIdx) or '???')
                        local tag = nameTags[serverId]
                        if not tag or not DoesEntityExist(ped) then
                            tag = CreateFakeMpGamerTag(ped, name, false, false, '', 0)
                            SetMpGamerTagAlpha(tag, 0, 255)
                            SetMpGamerTagAlpha(tag, 2, 255)
                            SetMpGamerTagAlpha(tag, 4, 255)
                            SetMpGamerTagAlpha(tag, 6, 255)
                            SetMpGamerTagHealthBarColour(tag, 25)
                            nameTags[serverId] = tag
                        end

                        SetMpGamerTagVisibility(tag, 0, true)
                        SetMpGamerTagVisibility(tag, 2, true)

                        if NetworkIsPlayerTalking(playerIdx) then
                            SetMpGamerTagVisibility(tag, 4, true)
                        else
                            SetMpGamerTagVisibility(tag, 4, false)
                        end

                        if GetPlayerInvincible(playerIdx) then
                            SetMpGamerTagVisibility(tag, 6, true)
                        else
                            SetMpGamerTagVisibility(tag, 6, false)
                        end
                    end

                    -- Blips
                    if showBlips then
                        if ped and ped ~= 0 and ped ~= myPed then
                            local blip = playerBlips[serverId]
                            if not blip or not DoesBlipExist(blip) then
                                blip = AddBlipForEntity(ped)
                                SetBlipSprite(blip, 1)
                                ShowHeadingIndicatorOnBlip(blip, true)
                                SetBlipScale(blip, 0.85)
                                SetBlipNameToPlayerName(blip, playerIdx)
                                playerBlips[serverId] = blip
                            end

                            local myCoords2d = vector2(myCoords.x, myCoords.y)
                            local pedCoords2d = vector2(GetEntityCoords(ped).x, GetEntityCoords(ped).y)
                            local distance = #(myCoords2d - pedCoords2d)
                            local alpha = math.floor(math.max(0, math.min(255, 900 - distance)))
                            SetBlipAlpha(blip, alpha)

                            if IsPedInAnyVehicle(ped, false) then
                                local veh = GetVehiclePedIsIn(ped, false)
                                local classVeh = GetVehicleClass(veh)
                                if classVeh == 15 or classVeh == 16 then
                                    SetBlipSprite(blip, 422)
                                elseif classVeh == 14 then
                                    SetBlipSprite(blip, 427)
                                elseif classVeh == 18 then
                                    SetBlipSprite(blip, 56)
                                else
                                    SetBlipSprite(blip, 225)
                                end
                                ShowHeadingIndicatorOnBlip(blip, false)
                            else
                                SetBlipSprite(blip, 1)
                                ShowHeadingIndicatorOnBlip(blip, true)
                            end

                            SetBlipRotation(blip, math.ceil(GetEntityHeading(ped)))
                        else
                            -- Ped not streamed yet or is self, remove stale blip
                            if playerBlips[serverId] then
                                RemoveBlip(playerBlips[serverId])
                                playerBlips[serverId] = nil
                            end
                        end
                    end
                end
            end

            -- Clean up removed players
            if not showNames then
                for id, tag in pairs(nameTags) do
                    RemoveMpGamerTag(tag)
                    nameTags[id] = nil
                end
            end
            if not showBlips then
                for id, blip in pairs(playerBlips) do
                    RemoveBlip(blip)
                    playerBlips[id] = nil
                end
            end
        end
        Wait(sleep)
    end
end)

-- ── Refund System ──

RegisterCommand('refund', function(_, args)
    if #args < 1 then
        lib.notify({ title = 'Refund', description = 'Usage: /refund <code>', type = 'error' })
        return
    end
    TriggerServerEvent('cuppa_admin:server:claimRefund', args[1])
end, false)

RegisterNetEvent('cuppa_admin:client:refundClaimed', function(success, msg)
    if GetInvokingResource() then return end
    lib.notify({ title = 'Refund', description = msg, type = success and 'success' or 'error', duration = 7000 })
end)

RegisterNetEvent('cuppa_admin:client:refundClaimItems', function(code, refundId, items)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'refundClaimItems', code = code, refundId = refundId, items = items })
    SetNuiFocus(true, true)
end)

RegisterNUICallback('createRefund', function(data, cb)
    TriggerServerEvent('cuppa_admin:server:createRefund', { items = data.items })
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:refundCreated', function(code, error)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'refundCreated', code = code, error = error })
end)

RegisterNUICallback('getRefunds', function(_, cb)
    TriggerServerEvent('cuppa_admin:server:getRefunds')
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:refundsList', function(list)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'refundsList', list = list })
end)

RegisterNUICallback('revokeRefund', function(data, cb)
    TriggerServerEvent('cuppa_admin:server:revokeRefund', { code = data.code })
    cb('ok')
end)

RegisterNUICallback('confirmClaimRefund', function(data, cb)
    TriggerServerEvent('cuppa_admin:server:confirmClaimRefund', { code = data.code, refundId = data.refundId, items = data.items })
    cb('ok')
end)

RegisterNetEvent('cuppa_admin:client:refundRevoked', function(error)
    if GetInvokingResource() then return end
    SendNUIMessage({ action = 'refundRevoked', error = error })
end)

-- Clean up on player drop
AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for _, tag in pairs(nameTags) do
        RemoveMpGamerTag(tag)
    end
    for _, blip in pairs(playerBlips) do
        RemoveBlip(blip)
    end
end)
