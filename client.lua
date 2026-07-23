local noclip = false
local godmode = false
local hiddenFrom = {}
local iAmHidden = false
local concealedPlayers = {} -- players concealed on my screen (serverId -> true)
local myHideException = nil -- if I'm hiding, who can still see me

RegisterNetEvent('cuppa_admin:client:kill', function()
    SetEntityHealth(cache.ped, 0)
end)

RegisterNetEvent('cuppa_admin:client:fixVehicle', function()
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle == 0 then return end
    SetVehicleFixed(vehicle)
    SetVehicleDirtLevel(vehicle, 0.0)
end)

RegisterNetEvent('cuppa_admin:client:deleteVehicle', function()
    local vehicle = GetVehiclePedIsIn(cache.ped, false)
    if vehicle == 0 then return end
    DeleteEntity(vehicle)
end)

RegisterNetEvent('cuppa_admin:client:setModel', function(model)
    lib.requestModel(model)
    SetPlayerModel(cache.playerId, model)
    SetModelAsNoLongerNeeded(model)
end)

RegisterNetEvent('cuppa_admin:client:godmode', function()
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
    if cache.playerId == requestor then return end
    iAmHidden = not iAmHidden or nil
end)

RegisterNetEvent('cuppa_admin:client:visible', function(target)
    hiddenFrom[target] = not hiddenFrom[target] or nil
end)

RegisterNetEvent('cuppa_admin:client:concealPlayer', function(serverId)
    concealedPlayers[serverId] = true
end)

RegisterNetEvent('cuppa_admin:client:showPlayer', function(serverId)
    concealedPlayers[serverId] = nil
end)

RegisterNetEvent('cuppa_admin:client:hideSelf', function(exceptionId)
    myHideException = exceptionId
end)

RegisterNetEvent('cuppa_admin:client:showSelf', function()
    myHideException = nil
end)

CreateThread(function()
    while true do
        local sleep = 1000
        local myId = cache.playerId
        local myPed = cache.ped
        local players = GetActivePlayers()

        for _, playerIdx in ipairs(players) do
            local serverId = GetPlayerServerId(playerIdx)
            if serverId ~= myId then
                local targetPed = GetPlayerPed(playerIdx)

                -- Conceal players hidden from me (old visible system)
                if iAmHidden or hiddenFrom[serverId] then
                    if targetPed and targetPed ~= 0 then
                        SetEntityVisible(targetPed, false, false)
                    end
                end

                -- Conceal players on the server-sent list (cc hide system)
                if concealedPlayers[serverId] then
                    sleep = 250
                    if targetPed and targetPed ~= 0 then
                        NetworkConcealPlayer(playerIdx, true, false)
                        SetEntityNoCollisionEntity(myPed, targetPed, false)
                        MumbleSetVolumeOverrideByServerId(serverId, 0.0)
                    end
                end

                -- When I'm hiding, conceal everyone except my exception
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
        Wait(sleep)
    end
end)

RegisterNetEvent('cuppa_admin:client:noclip', function()
    noclip = not noclip
    if noclip then
        SetEntityCollision(cache.ped, false, false)
        FreezeEntityPosition(cache.ped, false)
        SetEntityVisible(cache.ped, false, false)
        CreateThread(function()
            while noclip do
                Wait(0)
                local ped = cache.ped
                local coords = GetEntityCoords(ped)
                local heading = GetEntityHeading(ped)
                local fwd = 0.0
                local right = 0.0
                local up = 0.0

                if IsControlPressed(0, 32) then fwd = 1.0 end
                if IsControlPressed(0, 33) then fwd = -1.0 end
                if IsControlPressed(0, 34) then right = -1.0 end
                if IsControlPressed(0, 35) then right = 1.0 end
                if IsControlPressed(0, 44) then up = 1.0 end
                if IsControlPressed(0, 20) then up = -1.0 end

                local speed = 1.0
                if IsControlPressed(0, 21) then speed = 3.0 end

                local radZ = math.rad(heading)
                local cosH = math.cos(radZ)
                local sinH = math.sin(radZ)

                local moveX = (fwd * sinH * -1.0) + (right * cosH)
                local moveY = (fwd * cosH) + (right * sinH)
                local moveZ = up

                local newX = coords.x + (moveX * speed * 0.1)
                local newY = coords.y + (moveY * speed * 0.1)
                local newZ = coords.z + (moveZ * speed * 0.1)

                SetEntityCoordsNoOffset(ped, newX, newY, newZ, true, true, true)
            end

            SetEntityCollision(cache.ped, true, true)
            SetEntityVisible(cache.ped, true, false)
        end)
    else
        SetEntityCollision(cache.ped, true, true)
        SetEntityVisible(cache.ped, true, false)
    end
end)
