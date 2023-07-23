-- SPDX-License-Identifier: MIT
--[[
MIT License

Copyright (c) 2023 gcask <53709079+gcask@users.noreply.github.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

--[[
    Creates groups from the Bronco paratroopers.
    When the weapons first reach the ground, stand-ins (static) are created as placeholder
    until all the paratroopers finish up.
    
    Then, all remaining paratroopers who reached the ground safely are gathered into one group.

    The systems handles multiple active drops from the same aircraft,
    as well as multiple active drops from multiple aircrafts.

    The script has no dependencies.

    Inspired from: https://github.com/icuham/bronco-para1/blob/main/para-spawner.lua

USAGE
=====
    * Add the script to your miz via a MISSION START trigger.
    * You're done!

CUSTOMIZING
===========
    * Look for customize: tags throughout the code for interesting points.

    * It only spawns 'Soldier M4'.
        If you need a more complex behavior, look at Airdrop:generateGroupData() and Airdrop:paratrooperLanded()
    * AirborneParatrooper:isLandingSiteValid() if you want to tune what makes up a valid location for landing.
        Right now it will spawn everywher it can but WATER.
    * Airdrops:onEvent if you want more complex behavior
    * Airdrop:generateUniqueGroupName if you want to tweak how 'unique' drops are.
        Right now it's as unique as can be,
        but if you want only one live group per airframe you could fix the generation field.

CHANGELOG
=========

2023.07.22
----------
    Initial release.
--]]

-- The usual vector maths.
local vec3 = {
    scale = function(vec, scale)
        return { x = vec.x * scale, y = vec.y * scale, z = vec.z * scale }
    end,

    length = function(vec)
        return (vec.x^2 + vec.y^2 + vec.z^2)^0.5
    end,

    add = function (left, right)
        return { x = left.x + right.x, y = left.y + right.y, z = left.z + right.z }
    end,

    tostring = function(vec)
        return string.format("{x = %.2f, y = %.2f, z = %.2f}", vec.x, vec.y, vec.z)
    end,

    toTerrain2D = function(vec)
        -- World positions have y and z flipped around compared to the terrain2D.
        return { x = vec.x, y = vec.z }
    end
}

function vec3.distance(from, to)
    return vec3.length({x = to.x - from.x, y = to.y - from.y, z = to.z - from.z})
end

function vec3.normalize(vec)
    local length = vec3.length(vec)
    return vec3.scale(vec, 1/length)
end

--[[
    Track the state of the airborne paratrooper during a drop.
    Owned by an Airdrop, will notify it with its potential impact point (if one is found).
--]]
local AirborneParatrooper = {
    new = function(self, paratrooper, airdrop)
        local instance = {
            paratrooper = paratrooper,
            airdrop = airdrop,
            position = paratrooper:getPoint(),
            velocity = paratrooper:getVelocity(),
            impactPoint = nil,
            lastUpdateTimeSeconds = 0
        }
        setmetatable(instance, self)
        self.__index = self

        timer.scheduleFunction(self.update, instance, timer.getTime() + 1)
        return instance
    end,

    update = function(self, currentTimeSeconds)
        local status, exists = pcall(Weapon.isExist, self.paratrooper)
        
        local eta = nil
        if status and exists then
            local nextCallDelaySeconds = 1

            -- For as long as we can track, update our current position, and velocity.
            self.position = self.paratrooper:getPoint()
            self.velocity = self.paratrooper:getVelocity()
            self.lastUpdateTimeSeconds = currentTimeSeconds

            -- Based on current heading and velocity, check if we're about to hit the ground
            -- at 2x our default sampling rate.
            local speed = math.max(vec3.length(self.velocity), 1)
            local lookaheadSeconds = 2 * nextCallDelaySeconds

            self.impactPoint = land.getIP(self.position, vec3.normalize(self.velocity), lookaheadSeconds * speed)
            if self.impactPoint then
                -- Impact point found! See if we get a chance for another update.
                 local distanceToImpact = vec3.distance(self.position, self.impactPoint)
                 eta = distanceToImpact / speed
                 nextCallDelaySeconds = eta / 2
            end

            -- If we're hitting the ground within the next second,
            -- don't reschedule and handle impact.
            if not eta or eta > 1 then
                return currentTimeSeconds + nextCallDelaySeconds
            end
        end
        
        -- Paratrooper no longer in air/just about to hit the ground.


        if not self.impactPoint then
            -- We might have missed the mark, do a little linear interpolation.
            local delta = currentTimeSeconds - self.lastUpdateTimeSeconds
            local distance = vec3.scale(self.velocity, delta)
            self.impactPoint = vec3.add(self.position, distance)
        end

        local impact2D = vec3.toTerrain2D(self.impactPoint)
        

         -- Did it land somewhere viable?
         if not self:isLandingSiteValid(impact2D) then
            impact2D = nil
        end
        
        if eta and impact2D then
            timer.scheduleFunction(function(params)
                params.airdrop:paratrooperLanded(params.impact)
            end, {airdrop = self.airdrop, impact = impact2D}, currentTimeSeconds + eta)
        else
            self.airdrop:paratrooperLanded(impact2D)
        end

        -- Done, don't reschedule.
    end,

    isLandingSiteValid = function(self, impact2D)
        -- customize: you can run different surface checks (could validate slope angle, check for other objects, etc).
        return land.getSurfaceType(impact2D) ~= land.SurfaceType.WATER
    end
}

--[[
    A group of paratroopers.
    Assumes paratroopers are shot in bursts.
    Will create a group once all registered paratroopers for the sequence have landed.
--]]
local Airdrop = {
    -- statics
    prefix = "Paratroopers",

    -- customize: different types/types per coalition/country etc.
    unitType = "Soldier M4",

    new = function(self, airdrops, initiatorID, countryId)
        local instance = {
            initiatorID = initiatorID,
            countryId = countryId,
            airdrops = airdrops,
            airborne = 0,
            troopers = {},
            placeholders = {},
        }
        setmetatable(instance, self)
        self.__index = self

        return instance
    end,

    addParatrooper = function(self, parachutist)
        self.airborne = self.airborne + 1
        AirborneParatrooper:new(parachutist, self)
    end,

    paratrooperLanded = function(self, landingPos)
        if landingPos then
            if #self.troopers == 0 then
                -- Lazily acquire a groupID.
                self:acquireUniqueGroupName()
            end

            -- customize: Could leverage MIST here, have more complex unit setup.
            self.troopers[#self.troopers + 1] = {
                name = table.concat({self:getGroupName(), #self.troopers + 1}, ":"),
                type = self.unitType,
                x = landingPos.x,
                y = landingPos.y
            }
        end

        self.airborne = self.airborne - 1

        if self.airborne == 0 then
            self:destroyPlaceholders()

            if #self.troopers > 0 then
                coalition.addGroup(self.countryId, Group.Category.GROUND, self:generateGroupData())
            else
                -- No troopers made it in, release the reserved group.
                local reservedGroup = Group.getByName(self:getGroupName())
                if reservedGroup then reservedGroup:destroy() end
            end

            -- We've handed off the group,
            -- you will need to call acquireUniqueGroupName() before being able to use it again.
            self.getGroupName = nil
            self.airdrops:completeAirdrop(self)
        elseif landingPos then
            -- Standins until the group is complete.
            self.placeholders[#self.troopers] = coalition.addStaticObject(self.countryId, self.troopers[#self.troopers])
        end
    end,

    destroyPlaceholders = function(self)
        for _, placeholder in ipairs(self.placeholders) do
            placeholder:destroy()
        end

        self.placeholders = {}
    end,

    generateGroupData = function(self)

        -- customize: Could leverage MIST here.
        -- Add group tasking, etc.
        local group = {
            task = "Ground Nothing",
            name = self:getGroupName(),
            units = self.troopers
        }
        self.troopers = {}

        return group
    end,

    acquireUniqueGroupName = function(self)
        -- Find our generation ID, in case the same aircraft did multiple drops.
        self.getGroupName = function(self)
            return table.concat({self.prefix, self.initiatorID, self.generation}, ":")
        end

        self.generation = 1
        
        -- customize: remove this loop will only allow one group per airframe life.
        while Group.getByName(self:getGroupName()) do
            self.generation = self.generation + 1
        end

        -- lock in the group.
        -- Create a placeholder group to ensure the name is reserved.
        coalition.addGroup(self.countryId, Group.Category.GROUND, {
            task = "Ground Nothing",
            name = self:getGroupName(),
            lateActivation = true,
            visible = false
        })

        
    end
}

--[[
    Keep track of active airdrops, manages world events.
--]]
local Airdrops = {
    new = function(self)
        local instance = {}
        setmetatable(instance, self)
        self.__index = self

        return instance
    end,

    completeAirdrop = function(self, airdrop)
        if self[airdrop.initiatorID] then
            self[airdrop.initiatorID] = nil
        end

        airdrop.airdrops = nil
    end,

    getAirdrop = function(self, initiatorID, countryID)
        if not self[initiatorID] then
            self[initiatorID] = Airdrop:new(self, initiatorID, countryID)
        end

        return self[initiatorID]
    end,

    onEvent = function(self, event)
        if event.id ~= world.event.S_EVENT_SHOT then
            return
        end

        if event.weapon == nil then
            return
        end

        if event.weapon:getDesc().category ~= Weapon.Category.BOMB then
            return
        end

        if event.weapon:getTypeName() ~= "Paratrooperx5" then
            return
        end

        -- customize: extra accept/reject logic (could limit to player airframes or other).

        local launcher = event.weapon:getLauncher()

        -- customize: objectID is unique to the airframe's life.
        -- Could use getID()/getCallsign() to have groups unique per slot.
        local initiatorID = launcher:getObjectID()
        
        self:getAirdrop(initiatorID, event.weapon:getCountry()):addParatrooper(event.weapon)
    end
}

world.addEventHandler(Airdrops:new())