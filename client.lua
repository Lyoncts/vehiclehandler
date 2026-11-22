if not lib then print('^1ox_lib must be started before this resource.^0') return end
lib.locale()

---@class Handler : OxClass
local Handler = require 'modules.handler'
local Settings <const> = lib.load('data.vehicle')
local Units <const> = Settings.units == 'mph' and 2.23694 or 3.6

-- Motorcycles and bicycles: GTA won't let anyone back onto one it marks undriveable
local twoWheels <const> = { [8] = true, [13] = true }

---Stops a vehicle driving. A bike only has its engine turned off, again on each check while it's broken, so its
---rider can still get back on and it starts as normal once repaired.
---@param vehicle number
---@param class number | false
local function disable(vehicle, class)
    if twoWheels[class] then
        if GetIsVehicleEngineRunning(vehicle) then SetVehicleEngineOn(vehicle, false, true, false) end
    elseif IsVehicleDriveable(vehicle, true) then
        SetVehicleUndriveable(vehicle, true)
    end
end

---@param vehicle number
local function startThread(vehicle)
    if not vehicle then return end
    if not Handler or Handler:isActive() then return end

    Handler:setActive(true)

    local oxfuel = Handler:isFuelOx()
    local electric = Handler:isElectric()
    local class = Handler:getClass()
    local model = Handler:getModel()

    CreateThread(function()
        while (cache.vehicle == vehicle) and (cache.seat == -1) do

            -- Retrieve latest vehicle data
            local engine, body = Handler:setData({
                ['engine'] = GetVehicleEngineHealth(vehicle),
                ['body'] = GetVehicleBodyHealth(vehicle),
                ['speed'] = GetEntitySpeed(vehicle) * Units,
                ['velocity'] = GetEntitySpeedVector(vehicle, true)
            })

            -- Prevent negative engine health & driveability handler (engine)
            if engine <= 0 then
                if engine < 0 then
                    SetVehicleEngineHealth(cache.vehicle, 0.0)
                end

                disable(vehicle, class)
            end

            -- Prevent negative body health
            if body < 0 then
                SetVehicleBodyHealth(cache.vehicle, 0.0)
            end

            -- Driveability handler (fuel); boats and bicycles don't run on it
            if not electric and class ~= 14 and class ~= 13 then
                local fuel = oxfuel and Entity(vehicle).state.fuel or GetVehicleFuelLevel(vehicle)

                if fuel <= 7 then disable(vehicle, class) end
            end

            -- Reduce torque after half-life
            if not Handler:isLimited() and engine < 500 then
                Handler:setLimited(true)

                CreateThread(function()
                    while cache.vehicle == vehicle and cache.seat == -1 do
                        local engineLevel = Handler:getData('engine')
                        if engineLevel >= 500 then break end

                        SetVehicleCheatPowerIncrease(vehicle, (engineLevel + 500) / 1100)
                        Wait(1)
                    end

                    Handler:setLimited(false)
                end)
            end

            -- Prevent rotation controls while flipped/airborne
            if Settings.regulated[class] and not Settings.exclusions[model] then
                local offWheels = not IsVehicleOnAllWheels(vehicle)
                local flipped = offWheels and math.abs(GetEntityRoll(vehicle)) > 75.0

                if flipped or IsEntityInAir(vehicle) then
                    if Handler:canControl() then
                        Handler:setControl(false)

                        CreateThread(function()
                            while not Handler:canControl() and cache.seat == -1 do
                                DisableControlAction(2, 59, true) -- Disable left/right
                                DisableControlAction(2, 60, true) -- Disable up/down
                                Wait(1)
                            end

                            if not Handler:canControl() then Handler:setControl(true) end
                        end)
                    end
                else
                    if not Handler:canControl() then Handler:setControl(true) end
                end
            end

            Wait(300)
        end

        Handler:setActive(false)

        -- Retrigger thread if admin spawns a new vehicle while in one
        if cache.vehicle and cache.seat == -1 then
            startThread(cache.vehicle)
        end
    end)
end

---@param victim number
---@param weapon number | string
AddEventHandler('entityDamaged', function(victim, _, weapon, _)
    if not Handler or not Handler:isActive() then return end
    if victim ~= cache.vehicle then return end
    if GetWeapontypeGroup(weapon) ~= 0 then return end
    if Handler:getClass() == 14 then return end

    local vehicle <const> = cache.vehicle
    local body <const> = GetVehicleBodyHealth(vehicle)
    local speed <const> = GetEntitySpeed(vehicle) * Units
    local velocity <const> = GetEntitySpeedVector(vehicle, true)

    local bodyDiff = Handler:getData('body') - body
    local speedDiff = Handler:getData('speed') - speed
    local side = Handler:impactSide(Handler:getData('velocity'), velocity)

    -- One crash fires several damage events before the next reading, so move the readings on:
    -- the next event of the same crash only counts what it adds
    Handler:updateData('body', body)
    Handler:updateData('speed', speed)
    Handler:updateData('velocity', velocity)

    -- Damage handler
    if bodyDiff > 0 then

        -- Calculate latest damage, capped so one hit can't finish a car
        local bodyDamage = math.min(bodyDiff * Settings.globalmultiplier * Settings.classmultiplier[Handler:getClass()], Settings.maxdamage or math.huge)
        local newEngine = GetVehicleEngineHealth(vehicle) - bodyDamage

        -- Update engine health
        if newEngine > 0 and newEngine ~= Handler:getData('engine') then
            SetVehicleEngineHealth(vehicle, newEngine)
        else
            SetVehicleEngineHealth(vehicle, 0.0)
        end

        Handler:updateData('engine', GetVehicleEngineHealth(vehicle))

        -- Lets other resources (like EG-Mechanic) wear their parts from the same hit
        TriggerEvent('vehiclehandler:impact', vehicle, {
            body = bodyDiff,
            speed = speedDiff,
            side = side,
            engineSide = Handler:isEngineSide(vehicle, side),
        })

        -- Knock off a door, the hood or trunk, or smash a window on the side that was hit
        local breakparts = Settings.breakparts

        if breakparts and breakparts.enabled and Handler:getClass() ~= 8
            and bodyDiff >= breakparts.health and speedDiff >= breakparts.speed
            and math.random() < breakparts.chance then
            Handler:breakPart(vehicle, side)
        end
    end

    -- Impact handler
    if speedDiff >= Settings.threshold.speed then

        -- Handle wheel loss (breakparts picks wheels on the side that was hit instead)
        if Settings.breaktire and not (Settings.breakparts and Settings.breakparts.enabled) then
            if bodyDiff >= Settings.threshold.health then
                Handler:breakTire(vehicle, math.random(0, 1))
            end
        end

        -- Handle heavy impact (disable vehicle)
        if speedDiff >= Settings.threshold.heavy then
            SetVehicleEngineHealth(vehicle, 0.0)
            SetVehicleEngineOn(vehicle, false, true, false)
            disable(vehicle, Handler:getClass())
            Handler:updateData('engine', 0.0)
        end
    end
end)

---@param fixtype string
---@return boolean | nil success
lib.callback.register('vehiclehandler:basicfix', function(fixtype)
    if not Handler then return end
    return Handler:basicfix(fixtype)
end)

---@return boolean | nil success
lib.callback.register('vehiclehandler:basicwash', function()
    if not Handler then return end
    return Handler:basicwash()
end)

---@return boolean | nil success
lib.callback.register('vehiclehandler:adminfix', function()
    if not Handler then return end -- any seat; adminfix checks for a vehicle and the command.fix ace
    return Handler:adminfix()
end)

---@return boolean | nil success
lib.callback.register('vehiclehandler:adminwash', function()
    if not Handler then return end -- any seat; adminwash checks for a vehicle and the command.wash ace
    return Handler:adminwash()
end)

---Sent by the server's /fix and /wash to whoever owns the vehicle, so the change syncs to everyone
---@param netId number
---@return number? vehicle
local function getOwnedVehicle(netId)
    if GetInvokingResource() then return end -- only the server may send these
    if not Handler or type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return end

    local vehicle <const> = NetToVeh(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return end

    return vehicle
end

RegisterNetEvent('vehiclehandler:client:applyFix', function(netId)
    local vehicle <const> = getOwnedVehicle(netId)
    if vehicle then Handler:applyFix(vehicle) end
end)

RegisterNetEvent('vehiclehandler:client:applyWash', function(netId)
    local vehicle <const> = getOwnedVehicle(netId)
    if vehicle then Handler:applyWash(vehicle) end
end)

RegisterNetEvent('vehiclehandler:client:applyFuel', function(netId, level)
    local vehicle <const> = getOwnedVehicle(netId)
    if vehicle and type(level) == 'number' then Handler:applyFuel(vehicle, lib.math.clamp(level, 0.0, 100.0) + 0.0) end
end)

---@param newlevel number
---@return boolean | nil success
lib.callback.register('vehiclehandler:adminfuel', function(newlevel)
    if not Handler or not Handler:isActive() then return end
    return Handler:adminfuel(newlevel)
end)

-- Keeps vehicles from catching fire or exploding, so a destroyed one can still be entered, towed and repaired.
-- Fire and explosion flags only count on the client that owns a vehicle, so every client sets them on the
-- vehicles around it; health is only clamped on the ones it owns.
-- Helicopters, planes and trains still wreck as usual
local wreckClasses <const> = { [15] = true, [16] = true, [21] = true }

if Settings.nowreck then
    CreateThread(function()
        while true do
            for _, vehicle in ipairs(GetGamePool('CVehicle')) do
                local class = GetVehicleClass(vehicle)

                if not wreckClasses[class] and not IsEntityDead(vehicle) then
                    SetDisableVehiclePetrolTankFires(vehicle, true)
                    SetDisableVehiclePetrolTankDamage(vehicle, true)
                    SetDisableVehicleEngineFires(vehicle, true)
                    SetVehicleExplodesOnHighExplosionDamage(vehicle, false)

                    if NetworkGetEntityOwner(vehicle) == cache.playerId then
                        if GetVehicleEngineHealth(vehicle) < 0 then SetVehicleEngineHealth(vehicle, 0.0) end
                        if GetVehiclePetrolTankHealth(vehicle) < 0 then SetVehiclePetrolTankHealth(vehicle, 0.0) end
                        if IsEntityOnFire(vehicle) then StopEntityFire(vehicle) end

                        -- A bike left undriveable (by an older version or another script) can't be got on; whoever
                        -- rides it next has its broken engine kept off instead
                        if twoWheels[class] and not IsVehicleDriveable(vehicle, false) then SetVehicleUndriveable(vehicle, false) end
                    end
                end
            end

            Wait(1000)
        end
    end)
end

---@param seat number
lib.onCache('seat', function(seat)
    if seat == -1 then
        startThread(cache.vehicle)
    end
end)

CreateThread(function()
    Handler = Handler:new()

    if cache.seat == -1 then
        startThread(cache.vehicle)
    end
end)