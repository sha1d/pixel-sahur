--!strict

local Types = require(script.Parent.Parent.Types)
local Vector2 = require(script.Parent.Parent.Utils.Vector2)
local Rectangle = require(script.Parent.Parent.Utils.Rectangle)

type Vector2Type = Types.Vector2
type Rectangle = Types.Rectangle
type Hitbox = Types.Hitbox
type Entity = Types.Entity

local HitboxSystem = {}
HitboxSystem.__index = HitboxSystem

export type CollisionInfo = {
    entityA: string,
    entityB: string,
    penetration: Vector2Type,
    normal: Vector2Type,
    point: Vector2Type,
    isTrigger: boolean,
}

export type CollisionLayer = {
    name: string,
    bit: number,
}

-- Predefined collision layers
local CollisionLayers = {
    Default = {name = "Default", bit = 0},
    Player = {name = "Player", bit = 1},
    Enemy = {name = "Enemy", bit = 2},
    PlayerAttack = {name = "PlayerAttack", bit = 3},
    EnemyAttack = {name = "EnemyAttack", bit = 4},
    Trigger = {name = "Trigger", bit = 5},
    Wall = {name = "Wall", bit = 6},
    Platform = {name = "Platform", bit = 7},
    Item = {name = "Item", bit = 8},
}

function HitboxSystem.new()
    local self = setmetatable({}, HitboxSystem)

    -- Spatial partitioning grid
    self.cellSize = 100 -- Size of each grid cell in pixels
    self.grid = {} :: {[string]: {string}} -- Grid cells containing entity IDs

    -- Active hitboxes
    self.hitboxes = {} :: {[string]: {
        entityId: string,
        worldBounds: Rectangle,
        hitbox: Hitbox,
        transform: Types.Transform,
    }}

    -- Collision callbacks
    self.onCollisionEnter = {} :: {[string]: (CollisionInfo) -> ()}
    self.onCollisionStay = {} :: {[string]: (CollisionInfo) -> ()}
    self.onCollisionExit = {} :: {[string]: (CollisionInfo) -> ()}

    -- Previous frame collisions for enter/exit detection
    self.previousCollisions = {} :: {[string]: boolean}
    self.currentCollisions = {} :: {[string]: boolean}

    -- Debug visualization
    self.debugDraw = false
    self.debugFrames = {} :: {[string]: Frame}

    return self
end

function HitboxSystem:registerHitbox(entityId: string, hitbox: Hitbox, transform: Types.Transform)
    local worldBounds = self:calculateWorldBounds(hitbox, transform)

    self.hitboxes[entityId] = {
        entityId = entityId,
        worldBounds = worldBounds,
        hitbox = hitbox,
        transform = transform,
    }

    -- Add to spatial grid
    self:addToGrid(entityId, worldBounds)
end

function HitboxSystem:unregisterHitbox(entityId: string)
    local data = self.hitboxes[entityId]
    if data then
        self:removeFromGrid(entityId, data.worldBounds)
        self.hitboxes[entityId] = nil

        -- Clean up debug frame if exists
        if self.debugFrames[entityId] then
            self.debugFrames[entityId]:Destroy()
            self.debugFrames[entityId] = nil
        end
    end
end

function HitboxSystem:updateHitbox(entityId: string, transform: Types.Transform)
    local data = self.hitboxes[entityId]
    if not data then
        return
    end

    -- Remove from old grid cells
    self:removeFromGrid(entityId, data.worldBounds)

    -- Update transform and world bounds
    data.transform = transform
    data.worldBounds = self:calculateWorldBounds(data.hitbox, transform)

    -- Add to new grid cells
    self:addToGrid(entityId, data.worldBounds)
end

function HitboxSystem:calculateWorldBounds(hitbox: Hitbox, transform: Types.Transform): Rectangle
    local pos = transform.position
    local scale = transform.scale
    local offset = hitbox.offset

    -- Apply scale to size and offset
    local scaledSize = Vector2.new(
        hitbox.size.x * scale.x,
        hitbox.size.y * scale.y
    )
    local scaledOffset = Vector2.new(
        offset.x * scale.x,
        offset.y * scale.y
    )

    -- Calculate world position with offset
    local worldPos = Vector2.add(pos, scaledOffset)

    -- Create rectangle centered at world position
    return Rectangle.fromCenter(worldPos, scaledSize)
end

function HitboxSystem:addToGrid(entityId: string, bounds: Rectangle)
    local cells = self:getGridCells(bounds)

    for _, cellKey in ipairs(cells) do
        if not self.grid[cellKey] then
            self.grid[cellKey] = {}
        end
        table.insert(self.grid[cellKey], entityId)
    end
end

function HitboxSystem:removeFromGrid(entityId: string, bounds: Rectangle)
    local cells = self:getGridCells(bounds)

    for _, cellKey in ipairs(cells) do
        local cell = self.grid[cellKey]
        if cell then
            for i, id in ipairs(cell) do
                if id == entityId then
                    table.remove(cell, i)
                    break
                end
            end

            -- Remove empty cells
            if #cell == 0 then
                self.grid[cellKey] = nil
            end
        end
    end
end

function HitboxSystem:getGridCells(bounds: Rectangle): {string}
    local cells = {}

    local minX = math.floor(bounds.x / self.cellSize)
    local maxX = math.floor((bounds.x + bounds.width) / self.cellSize)
    local minY = math.floor(bounds.y / self.cellSize)
    local maxY = math.floor((bounds.y + bounds.height) / self.cellSize)

    for x = minX, maxX do
        for y = minY, maxY do
            table.insert(cells, x .. "," .. y)
        end
    end

    return cells
end

function HitboxSystem:getNearbyEntities(entityId: string): {string}
    local data = self.hitboxes[entityId]
    if not data then
        return {}
    end

    local nearbyEntities = {}
    local seen = {} :: {[string]: boolean}

    local cells = self:getGridCells(data.worldBounds)
    for _, cellKey in ipairs(cells) do
        local cell = self.grid[cellKey]
        if cell then
            for _, otherId in ipairs(cell) do
                if otherId ~= entityId and not seen[otherId] then
                    seen[otherId] = true
                    table.insert(nearbyEntities, otherId)
                end
            end
        end
    end

    return nearbyEntities
end

function HitboxSystem:checkCollision(entityIdA: string, entityIdB: string): CollisionInfo?
    local dataA = self.hitboxes[entityIdA]
    local dataB = self.hitboxes[entityIdB]

    if not dataA or not dataB then
        return nil
    end

    -- Check layer masking
    if not self:shouldCollide(dataA.hitbox, dataB.hitbox) then
        return nil
    end

    -- Check AABB intersection
    if not Rectangle.intersects(dataA.worldBounds, dataB.worldBounds) then
        return nil
    end

    -- Calculate collision details
    local penetration = self:calculatePenetration(dataA.worldBounds, dataB.worldBounds)
    local normal = Vector2.normalize(penetration)
    local point = self:getCollisionPoint(dataA.worldBounds, dataB.worldBounds)

    local isTrigger = dataA.hitbox.isTrigger or dataB.hitbox.isTrigger

    return {
        entityA = entityIdA,
        entityB = entityIdB,
        penetration = penetration,
        normal = normal,
        point = point,
        isTrigger = isTrigger,
    }
end

function HitboxSystem:shouldCollide(hitboxA: Hitbox, hitboxB: Hitbox): boolean
    -- Check if layers can interact
    local layerA = hitboxA.layer
    local layerB = hitboxB.layer
    local maskA = hitboxA.mask
    local maskB = hitboxB.mask

    -- A collides with B if B's layer is in A's mask
    local aCollidesWithB = bit32.band(maskA, bit32.lshift(1, layerB)) > 0
    -- B collides with A if A's layer is in B's mask
    local bCollidesWithA = bit32.band(maskB, bit32.lshift(1, layerA)) > 0

    return aCollidesWithB or bCollidesWithA
end

function HitboxSystem:calculatePenetration(boundsA: Rectangle, boundsB: Rectangle): Vector2Type
    local centerA = Rectangle.getCenter(boundsA)
    local centerB = Rectangle.getCenter(boundsB)

    local dx = centerB.x - centerA.x
    local dy = centerB.y - centerA.y

    local halfWidthA = boundsA.width / 2
    local halfHeightA = boundsA.height / 2
    local halfWidthB = boundsB.width / 2
    local halfHeightB = boundsB.height / 2

    local overlapX = halfWidthA + halfWidthB - math.abs(dx)
    local overlapY = halfHeightA + halfHeightB - math.abs(dy)

    if overlapX < overlapY then
        return Vector2.new(
            if dx > 0 then overlapX else -overlapX,
            0
        )
    else
        return Vector2.new(
            0,
            if dy > 0 then overlapY else -overlapY
        )
    end
end

function HitboxSystem:getCollisionPoint(boundsA: Rectangle, boundsB: Rectangle): Vector2Type
    local intersection = Rectangle.intersection(boundsA, boundsB)
    if intersection then
        return Rectangle.getCenter(intersection)
    end
    return Vector2.zero()
end

function HitboxSystem:update()
    -- Store previous collisions
    self.previousCollisions = self.currentCollisions
    self.currentCollisions = {}

    -- Check all potential collisions
    local checked = {} :: {[string]: boolean}

    for entityIdA, dataA in pairs(self.hitboxes) do
        local nearby = self:getNearbyEntities(entityIdA)

        for _, entityIdB in ipairs(nearby) do
            local pairKey = if entityIdA < entityIdB
                then entityIdA .. "_" .. entityIdB
                else entityIdB .. "_" .. entityIdA

            if not checked[pairKey] then
                checked[pairKey] = true

                local collision = self:checkCollision(entityIdA, entityIdB)
                if collision then
                    self.currentCollisions[pairKey] = true

                    -- Trigger callbacks
                    if self.previousCollisions[pairKey] then
                        -- Collision stay
                        self:triggerCallbacks(self.onCollisionStay, collision)
                    else
                        -- Collision enter
                        self:triggerCallbacks(self.onCollisionEnter, collision)
                    end
                end
            end
        end
    end

    -- Check for collision exits
    for pairKey, _ in pairs(self.previousCollisions) do
        if not self.currentCollisions[pairKey] then
            -- Parse entity IDs from pair key
            local entityIdA, entityIdB = pairKey:match("([^_]+)_([^_]+)")

            if entityIdA and entityIdB then
                local collision: CollisionInfo = {
                    entityA = entityIdA,
                    entityB = entityIdB,
                    penetration = Vector2.zero(),
                    normal = Vector2.zero(),
                    point = Vector2.zero(),
                    isTrigger = false,
                }
                self:triggerCallbacks(self.onCollisionExit, collision)
            end
        end
    end
end

function HitboxSystem:triggerCallbacks(callbacks: {[string]: (CollisionInfo) -> ()} | ((CollisionInfo) -> ()), collision: CollisionInfo)
    -- Check if callbacks is a function (global callback) or a table (entity-specific callbacks)
    if type(callbacks) == "function" then
        -- Global callback for all collisions
        callbacks(collision)
        return
    end

    -- Entity-specific callbacks
    -- Trigger for entity A
    local callbackA = callbacks[collision.entityA]
    if callbackA then
        callbackA(collision)
    end

    -- Trigger for entity B (with swapped entities)
    local callbackB = callbacks[collision.entityB]
    if callbackB then
        local swappedCollision = {
            entityA = collision.entityB,
            entityB = collision.entityA,
            penetration = Vector2.multiply(collision.penetration, -1),
            normal = Vector2.multiply(collision.normal, -1),
            point = collision.point,
            isTrigger = collision.isTrigger,
        }
        callbackB(swappedCollision)
    end
end

function HitboxSystem:setDebugDraw(enabled: boolean, screenGui: ScreenGui?)
    self.debugDraw = enabled

    if not enabled then
        -- Clean up all debug frames
        for _, frame in pairs(self.debugFrames) do
            frame:Destroy()
        end
        self.debugFrames = {}
    end
end

function HitboxSystem:drawDebugHitbox(entityId: string, screenGui: ScreenGui)
    local data = self.hitboxes[entityId]
    if not data then
        return
    end

    local frame = self.debugFrames[entityId]
    if not frame then
        frame = Instance.new("Frame")
        frame.Name = "Hitbox_" .. entityId
        frame.BackgroundColor3 = Color3.new(1, 0, 0)
        frame.BackgroundTransparency = 0.7
        frame.BorderSizePixel = 2
        frame.BorderColor3 = Color3.new(1, 1, 0)
        frame.Parent = screenGui
        self.debugFrames[entityId] = frame
    end

    -- Update frame position and size based on world bounds
    local bounds = data.worldBounds
    frame.Position = UDim2.fromOffset(bounds.x, bounds.y)
    frame.Size = UDim2.fromOffset(bounds.width, bounds.height)
end

-- Static utility functions
HitboxSystem.Layers = CollisionLayers

function HitboxSystem.createLayerMask(...: CollisionLayer): number
    local mask = 0
    for _, layer in ipairs({...}) do
        mask = bit32.bor(mask, bit32.lshift(1, layer.bit))
    end
    return mask
end

return HitboxSystem