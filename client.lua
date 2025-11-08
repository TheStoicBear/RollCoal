local time         = 15
local particleDict = "core"
local particleName = "ent_amb_generator_smoke"
local boneName     = "exhaust"
local key          = 73

local allowedVehicles = {
    "sandking", "fhauler", "ambulance", "00f350d", "3500flatbed", "flatbedm2", "14suvbb", "riot",
    "bailbondsram", "f450towtruk", "18ram", "mcu", "poltowtruck", "aflatbed", "atow", "um20ram",
    "20ramambo", "16gmcbrush", "f750", "leg14ram", "fd1", "fd2", "fd3", "fd4", "fd5", "fd6", "fd7",
    "337flatbed", "f450plat", "loadstar76", "3500flatbed"
}

local intensity = 1.0

-- TUNING
local TICK_IDLE_MS       = 400   -- when not in valid vehicle
local TICK_ACTIVE_MS     = 120   -- when rolling coal
local MIN_RPM            = 0.12  -- ignore low RPM
local PUFFS_PER_RPM      = 3
local MAX_PUFFS_PER_TICK = 3
local PFX_LIFETIME_MS    = 800
local BASE_SCALE         = 1.3
local EXTRA_SCALE        = 2.4

-- INTERNAL STATE
local allowedHashes = {}
local ptfxLoaded    = false

-- cache natives to cut global lookups
local PlayerPedId                    = PlayerPedId
local IsPedInAnyVehicle              = IsPedInAnyVehicle
local GetVehiclePedIsIn              = GetVehiclePedIsIn
local GetPedInVehicleSeat            = GetPedInVehicleSeat
local GetEntityModel                 = GetEntityModel
local GetVehicleCurrentRpm           = GetVehicleCurrentRpm
local IsControlPressed               = IsControlPressed
local GetEntityBoneIndexByName       = GetEntityBoneIndexByName
local GetWorldPositionOfEntityBone   = GetWorldPositionOfEntityBone
local RequestNamedPtfxAsset          = RequestNamedPtfxAsset
local HasNamedPtfxAssetLoaded        = HasNamedPtfxAssetLoaded
local UseParticleFxAssetNextCall     = UseParticleFxAssetNextCall
local StartParticleFxLoopedOnEntityBone = StartParticleFxLoopedOnEntityBone
local StopParticleFxLooped           = StopParticleFxLooped
local NetworkGetEntityFromNetworkId  = NetworkGetEntityFromNetworkId
local DoesEntityExist                = DoesEntityExist
local GetHashKey                     = GetHashKey
local math_floor                     = math.floor
local SetTimeout                     = Citizen.SetTimeout

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function buildAllowedHashes()
    for i = 1, #allowedVehicles do
        allowedHashes[GetHashKey(allowedVehicles[i])] = true
    end
end

local function isVehicleAllowed(vehicle)
    return allowedHashes[GetEntityModel(vehicle)] == true
end

local function ensurePtfxLoaded()
    if ptfxLoaded then return end
    RequestNamedPtfxAsset(particleDict)
    while not HasNamedPtfxAssetLoaded(particleDict) do
        Citizen.Wait(0)
    end
    ptfxLoaded = true
end

local function calcScaleFromRPM(rpm)
    return BASE_SCALE + (rpm * EXTRA_SCALE)
end

-- one short-lived looped puff on the exhaust bone
local function spawnSmokePuff(vehicle, boneIndex, rpm)
    if not DoesEntityExist(vehicle) then return end
    if not rpm or rpm <= MIN_RPM then return end

    ensurePtfxLoaded()

    local scale = calcScaleFromRPM(rpm)

    UseParticleFxAssetNextCall(particleDict)
    local handle = StartParticleFxLoopedOnEntityBone(
        particleName,
        vehicle,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        boneIndex,
        scale,
        false, false, false
    )

    -- evolution still tied to RPM for “thickness”
    SetParticleFxLoopedEvolution(handle, particleName, rpm, 0.0)

    SetTimeout(PFX_LIFETIME_MS, function()
        StopParticleFxLooped(handle, false)
    end)
end

---------------------------------------------------------------------
-- MAIN LOOP (LOCAL PLAYER)
---------------------------------------------------------------------

Citizen.CreateThread(function()
    buildAllowedHashes()
    ensurePtfxLoaded()

    local lastVehicle   = 0
    local cachedBoneIdx = -1

    while true do
        local waitMs = TICK_IDLE_MS
        local ped = PlayerPedId()

        if IsPedInAnyVehicle(ped, false) then
            local vehicle = GetVehiclePedIsIn(ped, false)

            if GetPedInVehicleSeat(vehicle, -1) == ped and isVehicleAllowed(vehicle) then
                waitMs = TICK_ACTIVE_MS

                -- cache exhaust bone index per vehicle
                if vehicle ~= lastVehicle then
                    lastVehicle   = vehicle
                    cachedBoneIdx = GetEntityBoneIndexByName(vehicle, boneName)
                end

                local boneIndex = cachedBoneIdx
                if boneIndex ~= -1 then
                    local rpm = GetVehicleCurrentRpm(vehicle) * intensity

                    -- less smoke off-throttle (same behavior)
                    if not IsControlPressed(0, 71) then -- 71 = accelerate
                        rpm = rpm / intensity
                    end

                    if rpm > MIN_RPM then
                        local puffCount = math_floor(rpm * PUFFS_PER_RPM)
                        if puffCount < 1 then puffCount = 1 end
                        if puffCount > MAX_PUFFS_PER_TICK then
                            puffCount = MAX_PUFFS_PER_TICK
                        end

                        for _ = 1, puffCount do
                            spawnSmokePuff(vehicle, boneIndex, rpm)
                        end
                    end
                end
            else
                lastVehicle   = 0
                cachedBoneIdx = -1
            end
        else
            lastVehicle   = 0
            cachedBoneIdx = -1
        end

        Citizen.Wait(waitMs)
    end
end)

---------------------------------------------------------------------
-- NETWORK SYNC (OTHER PLAYERS SEE YOUR COAL)
---------------------------------------------------------------------

RegisterNetEvent("syncSmoke")
AddEventHandler("syncSmoke", function(netId, boneIndex, coords, rpm)
    if not rpm or rpm <= MIN_RPM then return end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(vehicle) then return end

    if not boneIndex or boneIndex == -1 then
        boneIndex = GetEntityBoneIndexByName(vehicle, boneName)
    end
    if boneIndex == -1 then return end

    local puffCount = math_floor(rpm * PUFFS_PER_RPM)
    if puffCount < 1 then puffCount = 1 end
    if puffCount > MAX_PUFFS_PER_TICK then
        puffCount = MAX_PUFFS_PER_TICK
    end

    for _ = 1, puffCount do
        spawnSmokePuff(vehicle, boneIndex, rpm)
    end
end)

RegisterNetEvent("startSmoke")
AddEventHandler("startSmoke", function()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if GetPedInVehicleSeat(vehicle, -1) ~= ped or not isVehicleAllowed(vehicle) then return end

    local boneIndex = GetEntityBoneIndexByName(vehicle, boneName)
    if boneIndex == -1 then return end

    local rpm = GetVehicleCurrentRpm(vehicle) * intensity
    if not IsControlPressed(0, 71) then
        rpm = rpm / intensity
    end
    if rpm <= MIN_RPM then return end

    local coords = GetWorldPositionOfEntityBone(vehicle, boneName)

    TriggerServerEvent(
        "syncSmoke",
        NetworkGetNetworkIdFromEntity(vehicle),
        boneIndex,
        coords,
        rpm
    )
end)
