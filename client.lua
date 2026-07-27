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

local noclipDisableControls = { 32, 33, 34, 35, 36, 12, 13, 14, 15, 16, 17 }

local function registerCCSuggestion()
    TriggerEvent('chat:addSuggestion', '/cc', 'Admin commands — type /cc for full list', {
        { name = 'subcommand', help = 'stats, kick, ban, baninfo, undo, announce, heal, kill, revive, freeze, unfreeze, goto, bring, car, tp, godmode, noclip, ...' },
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

RegisterNetEvent('cuppa_admin:client:bringVehicle', function(coords)
    if GetInvokingResource() then return end
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle and vehicle ~= 0 then
        SetEntityCoords(vehicle, coords.x, coords.y, coords.z, false, false, false, false)
        SetEntityHeading(vehicle, coords.w or 0.0)
    end
    SetEntityCoords(cache.ped, coords.x, coords.y, coords.z + 2.0, false, false, false, false)
end)
