--!strict
-- Main game server that manages the game state and replication

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Import modules
local EntityManager = require(ReplicatedStorage.Shared.ECS.EntityManager)
local NetworkServer = require(script.Parent.Network.NetworkServer)
local HitboxSystem = require(ReplicatedStorage.Shared.Physics.HitboxSystem)
local CharacterController = require(ReplicatedStorage.Shared.Character.CharacterController)
local Vector2 = require(ReplicatedStorage.Shared.Utils.Vector2)
local Types = require(ReplicatedStorage.Shared.Types)
local Packets = require(ReplicatedStorage.Shared.Network.SimplePackets)

type Entity = Types.Entity
type Vector2Type = Types.Vector2
type InputState = Types.InputState
type CharacterControllerType = CharacterController.CharacterController
type CollisionInfo = HitboxSystem.CollisionInfo
type System = EntityManager.System
type Transform = Types.Transform
type Hitbox = Types.Hitbox

local GameServer = {}
GameServer.__index = GameServer

function GameServer.new()
    local self = setmetatable({}, GameServer)

    -- Core systems
    self.entityManager = EntityManager.new()
    self.networkServer = NetworkServer.new()
    self.hitboxSystem = HitboxSystem.new()

    -- Player management
    self.playerCharacters = {} :: {[Player]: CharacterControllerType}
    self.playerEntities = {} :: {[Player]: string}
    self.playerLastInput = {} :: {[Player]: InputState}

    -- Static entities (obstacles, walls, etc.) to send to joining players
    self.staticEntities = {} :: {{entityId: string, position: Vector2Type, entityType: string, size: Vector2Type}}

    -- Game state
    self.running = false
    self.tickRate = 30 -- 30Hz server tick
    self.lastTick = 0

    -- Connections
    self.gameLoop = nil :: RBXScriptConnection?
    self.physicsLoop = nil :: RBXScriptConnection?

    -- World configuration
    self.worldBounds = {
        x = -2000,
        y = -2000,
        width = 4000,
        height = 4000,
    }

    -- Spawn configuration
    -- Safe spawn points that don't overlap with obstacles
    self.spawnPoints = {
        Vector2.new(0, 0),       -- Center spawn (safe - no obstacle)
        Vector2.new(-200, 0),    -- Clear area west
        Vector2.new(200, 0),     -- Clear area east
        Vector2.new(0, -250),    -- Clear area north
        Vector2.new(0, 250),     -- Clear area south
        Vector2.new(-200, -200), -- Northwest
        Vector2.new(200, 200),   -- Southeast
    }
    self.nextSpawnIndex = 1

    return self
end

function GameServer:initialize()
    print("Initializing Game Server...")

    -- Register ECS systems
    self:registerSystems()

    -- Set up network callbacks
    self:setupNetworkCallbacks()

    -- Set up hitbox callbacks
    self:setupHitboxCallbacks()

    -- Initialize world
    self:initializeWorld()

    print("Game Server initialized successfully!")
end

function GameServer:setupNetworkCallbacks()
    -- Player joined
    self.networkServer.onPlayerJoined = function(player: Player)
        print("Player joined:", player.Name)
        self:spawnPlayer(player)
    end

    -- Player left
    self.networkServer.onPlayerLeft = function(player: Player)
        print("Player left:", player.Name)
        self:despawnPlayer(player)
    end

    -- Player input
    self.networkServer.onPlayerInput = function(player: Player, input: InputState, deltaTime: number)
        -- Store the last input for this player
        self.playerLastInput[player] = input

        local hasInput = input.moveLeft or input.moveRight or input.moveUp or input.moveDown
        if hasInput and tick() % 2 < 0.033 then -- Print occasionally
            print("[SERVER] Received input from", player.Name)
        end

        -- Mark the player's entity as dirty so it gets updated
        local entityId = self.playerEntities[player]
        if entityId then
            self.networkServer.dirtyEntities[entityId] = true
        end
    end

    -- Player action
    self.networkServer.onPlayerAction = function(player: Player, action: string, data: any?)
        print("Player action:", player.Name, action)

        local character = self.playerCharacters[player]
        if character then
            if action == "attack" then
                self:handlePlayerAttack(player, data)
            elseif action == "interact" then
                self:handlePlayerInteract(player, data)
            end
        end
    end
end

function GameServer:setupHitboxCallbacks()
    -- Collision detection
    self.hitboxSystem.onCollisionEnter = function(collision)
        -- Handle different collision types
        local entityA = self.entityManager:getEntity(collision.entityA)
        local entityB = self.entityManager:getEntity(collision.entityB)

        if not entityA or not entityB then
            return
        end

        -- Resolve solid (non-trigger) collisions
        if not collision.isTrigger then
            self:resolveCollision(entityA, entityB, collision)
        end

        -- Player vs Enemy collision
        if self:isPlayer(entityA) and self:isEnemy(entityB) then
            self:handlePlayerEnemyCollision(entityA, entityB, collision)
        elseif self:isEnemy(entityA) and self:isPlayer(entityB) then
            self:handlePlayerEnemyCollision(entityB, entityA, collision)
        end

        -- Attack hitbox vs target
        if self:isAttackHitbox(entityA) then
            self:handleAttackHit(entityA, entityB, collision)
        elseif self:isAttackHitbox(entityB) then
            self:handleAttackHit(entityB, entityA, collision)
        end
    end
end

function GameServer:resolveCollision(entityA: Entity, entityB: Entity, collision: CollisionInfo)
    -- Determine which entity should be pushed (dynamic vs static)
    local transformA = entityA.components.Transform
    local transformB = entityB.components.Transform
    local physicsA = entityA.components.Physics
    local physicsB = entityB.components.Physics

    if not transformA or not transformB then
        return
    end

    -- Check if entities are static
    local isStaticA = physicsA and physicsA.isStatic or false
    local isStaticB = physicsB and physicsB.isStatic or false

    -- If both are static or both are dynamic, don't resolve (or resolve 50/50)
    -- For now, we'll only resolve if one is static
    if isStaticA and isStaticB then
        return
    end

    -- Determine who gets pushed
    local dynamicEntity = nil
    local dynamicTransform = nil
    local pushDirection = collision.normal

    if not isStaticA and isStaticB then
        -- A is dynamic, B is static - push A
        dynamicEntity = entityA
        dynamicTransform = transformA
        pushDirection = collision.normal  -- Normal points from A to B
    elseif isStaticA and not isStaticB then
        -- B is dynamic, A is static - push B
        dynamicEntity = entityB
        dynamicTransform = transformB
        pushDirection = Vector2.multiply(collision.normal, -1)  -- Reverse normal
    elseif not isStaticA and not isStaticB then
        -- Both dynamic - push both (for now, just push A)
        dynamicEntity = entityA
        dynamicTransform = transformA
        pushDirection = collision.normal
    end

    if dynamicEntity and dynamicTransform then
        -- penetration is already a Vector2, use it directly for correction
        -- If we need to reverse it for entity B, multiply by -1
        local correction = collision.penetration
        if dynamicEntity == entityB then
            correction = Vector2.multiply(collision.penetration, -1)
        end

        -- Only apply correction if penetration is significant (> 0.1 pixels)
        local penetrationMagnitude = math.sqrt(correction.x * correction.x + correction.y * correction.y)
        if penetrationMagnitude < 0.1 then
            return -- Ignore micro-collisions
        end

        dynamicTransform.position = Vector2.add(dynamicTransform.position, correction)

        -- Also update character controller if this is a player
        local correctedPlayer = nil
        local correctedCharController = nil
        for player, charController in pairs(self.playerCharacters) do
            if self.playerEntities[player] == dynamicEntity.id then
                charController.position = dynamicTransform.position
                correctedPlayer = player
                correctedCharController = charController
                -- Stop velocity in the direction of collision
                local velocityDot = charController.velocity.x * collision.normal.x + charController.velocity.y * collision.normal.y
                if velocityDot < 0 then
                    -- Moving into the wall, stop that component
                    charController.velocity = Vector2.subtract(
                        charController.velocity,
                        Vector2.multiply(collision.normal, velocityDot)
                    )
                end
                break
            end
        end

        -- Send position correction to the client only if significant (> 1 pixel movement)
        if correctedPlayer and correctedCharController and penetrationMagnitude > 1 then
            Packets.EntityUpdate.sendTo(correctedPlayer, {
                entityId = dynamicEntity.id,
                position = dynamicTransform.position,
                velocity = correctedCharController.velocity,
                timestamp = tick(),
            })
        end
    end
end

function GameServer:registerSystems()
    -- CharacterController system - processes player movement
    local CharacterControllerSystem: System = {
        name = "CharacterController",
        priority = 1,
        requiredComponents = {"Transform", "Character"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                -- Find the player that owns this entity
                local ownerPlayer = nil
                for player, entityId in pairs(self.playerEntities) do
                    if entityId == entity.id then
                        ownerPlayer = player
                        break
                    end
                end

                if ownerPlayer then
                    local character = self.playerCharacters[ownerPlayer]
                    local inputState = self.playerLastInput[ownerPlayer]

                    if character and inputState then
                        -- Update character controller with input
                        character:update(deltaTime, inputState)

                        -- Update entity transform with character position
                        local transform = entity.components.Transform :: Transform
                        if transform then
                            transform.position = character.position

                            -- Update network server's internal position tracking
                            local playerData = self.networkServer.players[ownerPlayer]
                            if playerData then
                                -- Convert Vector2 to network format (table with x,y)
                                playerData.position = {
                                    x = character.position.x,
                                    y = character.position.y
                                }
                                playerData.velocity = {
                                    x = character.velocity.x,
                                    y = character.velocity.y
                                }

                                -- Mark entity as dirty for network updates
                                self.networkServer.dirtyEntities[entity.id] = true
                            end
                        end

                        -- Update character component state
                        local charComponent = entity.components.Character :: Types.Character
                        if charComponent then
                            charComponent.state = character.state
                            charComponent.health = character.health
                            charComponent.facingDirection = character.facingDirection
                        end
                    end
                end
            end
        end,
    }

    -- Physics system
    local PhysicsSystem: System = {
        name = "Physics",
        priority = 2,
        requiredComponents = {"Transform", "Physics"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                local transform = entity.components.Transform :: Transform
                local physics = entity.components.Physics :: Types.Physics

                -- Apply gravity
                if physics and transform and not physics.isStatic then
                    physics.velocity = Vector2.new(
                        physics.velocity.x,
                        physics.velocity.y + 980 * deltaTime -- Gravity
                    )

                    -- Apply velocity
                    transform.position = Vector2.add(
                        transform.position,
                        Vector2.multiply(physics.velocity, deltaTime)
                    )

                    -- Apply friction
                    physics.velocity = Vector2.multiply(physics.velocity, 1 - physics.friction * deltaTime)
                end

                -- Update hitbox position if entity has one
                local hitbox = entity.components.Hitbox
                if hitbox and transform then
                    self.hitboxSystem:updateHitbox(entity.id, transform)
                end
            end
        end,
    }

    -- AI System (for NPCs/Enemies)
    local AISystem: System = {
        name = "AI",
        priority = 3,
        requiredComponents = {"Transform", "AI"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                local ai = entity.components.AI :: Types.AI
                -- Basic AI logic would go here
                -- For example: pathfinding, state machines, etc.
            end
        end,
    }

    self.entityManager:registerSystem(CharacterControllerSystem)
    self.entityManager:registerSystem(PhysicsSystem)
    self.entityManager:registerSystem(AISystem)
end

function GameServer:initializeWorld()
    -- Create world boundaries (invisible walls)
    self:createWorldBoundary("left", Vector2.new(self.worldBounds.x, 0), Vector2.new(10, self.worldBounds.height))
    self:createWorldBoundary("right", Vector2.new(self.worldBounds.x + self.worldBounds.width, 0), Vector2.new(10, self.worldBounds.height))
    self:createWorldBoundary("top", Vector2.new(0, self.worldBounds.y), Vector2.new(self.worldBounds.width, 10))
    self:createWorldBoundary("bottom", Vector2.new(0, self.worldBounds.y + self.worldBounds.height), Vector2.new(self.worldBounds.width, 10))

    -- Spawn some test entities
    self:spawnTestEntities()
end

function GameServer:createWorldBoundary(name: string, position: Vector2Type, size: Vector2Type)
    local entityId = "boundary_" .. name
    local entity = self.entityManager:createEntity(entityId)

    -- Add transform
    self.entityManager:addComponent(entityId, "Transform", {
        position = position,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 0,
    })

    -- Add physics component (static)
    self.entityManager:addComponent(entityId, "Physics", {
        velocity = Vector2.zero(),
        acceleration = Vector2.zero(),
        mass = 0,
        friction = 0,
        restitution = 0,
        isStatic = true,  -- This object doesn't move
    })

    -- Add hitbox
    self.entityManager:addComponent(entityId, "Hitbox", {
        size = size,
        offset = Vector2.zero(),
        isTrigger = false,
        layer = 6, -- Wall layer
        mask = 0xFFFF, -- Collides with everything
        debugDraw = false,
    })

    -- Register hitbox
    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    local hitbox = self.entityManager:getComponent(entityId, "Hitbox") :: Hitbox?
    if transform and hitbox then
        self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
    end
end

function GameServer:spawnTestEntities()
    -- Spawn test collision objects around the map
    self:spawnTestObjects()

    -- Spawn some test enemies or items
    for i = 1, 5 do
        local position = Vector2.new(
            math.random(-500, 500),
            math.random(-500, 500)
        )
        self:spawnEnemy("test", position)
    end
end

function GameServer:spawnTestObjects()
    -- Create various test objects for collision and movement testing

    -- Center obstacles (REMOVED - spawn area kept clear)
    -- self:createStaticBox("box_center", Vector2.new(0, 0), Vector2.new(100, 100))

    -- Scattered boxes around the map
    self:createStaticBox("box_ne", Vector2.new(300, -300), Vector2.new(80, 80))
    self:createStaticBox("box_nw", Vector2.new(-300, -300), Vector2.new(80, 80))
    self:createStaticBox("box_se", Vector2.new(300, 300), Vector2.new(80, 80))
    self:createStaticBox("box_sw", Vector2.new(-300, 300), Vector2.new(80, 80))

    -- Long walls to test wall sliding
    self:createStaticWall("wall_horizontal_top", Vector2.new(0, -400), Vector2.new(400, 20))
    self:createStaticWall("wall_horizontal_bottom", Vector2.new(0, 400), Vector2.new(400, 20))
    self:createStaticWall("wall_vertical_left", Vector2.new(-400, 0), Vector2.new(20, 400))
    self:createStaticWall("wall_vertical_right", Vector2.new(400, 0), Vector2.new(20, 400))

    -- Narrow corridor test
    self:createStaticWall("corridor_wall_1", Vector2.new(150, 0), Vector2.new(10, 200))
    self:createStaticWall("corridor_wall_2", Vector2.new(250, 0), Vector2.new(10, 200))

    -- Pillars
    self:createStaticBox("pillar_1", Vector2.new(-150, -150), Vector2.new(40, 40))
    self:createStaticBox("pillar_2", Vector2.new(150, -150), Vector2.new(40, 40))
    self:createStaticBox("pillar_3", Vector2.new(-150, 150), Vector2.new(40, 40))
    self:createStaticBox("pillar_4", Vector2.new(150, 150), Vector2.new(40, 40))

    -- L-shaped obstacle
    self:createStaticWall("L_shape_1", Vector2.new(-100, -100), Vector2.new(150, 20))
    self:createStaticWall("L_shape_2", Vector2.new(-100, -50), Vector2.new(20, 150))

    -- Maze section
    self:createStaticWall("maze_1", Vector2.new(50, 150), Vector2.new(100, 15))
    self:createStaticWall("maze_2", Vector2.new(50, 200), Vector2.new(15, 100))
    self:createStaticWall("maze_3", Vector2.new(100, 200), Vector2.new(100, 15))

    print("Spawned test collision objects")
end

function GameServer:createStaticBox(name: string, position: Vector2Type, size: Vector2Type)
    local entityId = "obstacle_" .. name
    local entity = self.entityManager:createEntity(entityId)

    print("Creating static box:", entityId, "at", position.x, position.y, "size", size.x, size.y)

    -- Add transform
    self.entityManager:addComponent(entityId, "Transform", {
        position = position,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 5,
    })

    -- Add physics component (static)
    self.entityManager:addComponent(entityId, "Physics", {
        velocity = Vector2.zero(),
        acceleration = Vector2.zero(),
        mass = 0,
        friction = 0,
        restitution = 0,
        isStatic = true,  -- This object doesn't move
    })

    -- Add hitbox
    self.entityManager:addComponent(entityId, "Hitbox", {
        size = size,
        offset = Vector2.zero(),
        isTrigger = false,
        layer = 6, -- Wall layer
        mask = 0xFFFF, -- Collides with everything
        debugDraw = true,
    })

    -- Add visual component (for rendering)
    self.entityManager:addComponent(entityId, "Sprite", {
        imageId = "", -- Empty for now, will be colored rectangle
        size = size,
        offset = Vector2.zero(),
        color = Color3.new(0.5, 0.5, 0.5), -- Gray
        transparency = 0,
    })

    -- Register hitbox
    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    local hitbox = self.entityManager:getComponent(entityId, "Hitbox") :: Hitbox?
    if transform and hitbox then
        self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
    end

    -- Store in static entities list for joining players
    table.insert(self.staticEntities, {
        entityId = entityId,
        position = position,
        entityType = "obstacle",
        size = size,
    })

    -- Send to clients (if any are connected)
    Packets.EntitySpawn.sendToAll({
        entityId = entityId,
        position = position,
        entityType = "obstacle",
        size = size,
        velocity = Vector2.zero(),
        playerId = nil,
        data = nil,
    })
end

function GameServer:createStaticWall(name: string, position: Vector2Type, size: Vector2Type)
    local entityId = "wall_" .. name
    local entity = self.entityManager:createEntity(entityId)

    -- Add transform
    self.entityManager:addComponent(entityId, "Transform", {
        position = position,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 5,
    })

    -- Add physics component (static)
    self.entityManager:addComponent(entityId, "Physics", {
        velocity = Vector2.zero(),
        acceleration = Vector2.zero(),
        mass = 0,
        friction = 0,
        restitution = 0,
        isStatic = true,  -- This object doesn't move
    })

    -- Add hitbox
    self.entityManager:addComponent(entityId, "Hitbox", {
        size = size,
        offset = Vector2.zero(),
        isTrigger = false,
        layer = 6, -- Wall layer
        mask = 0xFFFF, -- Collides with everything
        debugDraw = true,
    })

    -- Add visual component (for rendering)
    self.entityManager:addComponent(entityId, "Sprite", {
        imageId = "", -- Empty for now, will be colored rectangle
        size = size,
        offset = Vector2.zero(),
        color = Color3.new(0.3, 0.3, 0.4), -- Dark gray/blue
        transparency = 0,
    })

    -- Register hitbox
    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    local hitbox = self.entityManager:getComponent(entityId, "Hitbox") :: Hitbox?
    if transform and hitbox then
        self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
    end

    -- Store in static entities list for joining players
    table.insert(self.staticEntities, {
        entityId = entityId,
        position = position,
        entityType = "wall",
        size = size,
    })

    -- Send to clients (if any are connected)
    Packets.EntitySpawn.sendToAll({
        entityId = entityId,
        position = position,
        entityType = "wall",
        size = size,
        velocity = Vector2.zero(),
        playerId = nil,
        data = nil,
    })
end

function GameServer:spawnPlayer(player: Player)
    -- Get spawn position
    local spawnPos = self.spawnPoints[self.nextSpawnIndex]
    self.nextSpawnIndex = (self.nextSpawnIndex % #self.spawnPoints) + 1

    -- Create player entity
    local playerId = tostring(player.UserId)
    local entityId = "player_" .. playerId
    local entity = self.entityManager:createEntity(entityId)

    -- Add components
    self.entityManager:addComponent(entityId, "Transform", {
        position = spawnPos,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 10,
    })

    self.entityManager:addComponent(entityId, "Character", {
        playerId = playerId,
        state = "idle",
        health = 100,
        maxHealth = 100,
        moveSpeed = 120,  -- Reduced from 200
        jumpPower = 400,
        facingDirection = "right",
        isGrounded = true,
        canMove = true,
        canJump = true,
    })

    self.entityManager:addComponent(entityId, "Physics", {
        velocity = Vector2.zero(),
        acceleration = Vector2.zero(),
        mass = 1,
        friction = 0.1,
        restitution = 0,
        isStatic = false,
    })

    self.entityManager:addComponent(entityId, "Hitbox", {
        size = Vector2.new(48, 60),
        offset = Vector2.zero(),
        isTrigger = false,
        layer = 1, -- Player layer
        mask = bit32.bor(bit32.lshift(1, 2), bit32.lshift(1, 6)), -- Collides with enemies and walls
        debugDraw = false,
    })

    -- Register hitbox
    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    local hitbox = self.entityManager:getComponent(entityId, "Hitbox") :: Hitbox?
    if transform and hitbox then
        self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
    end

    -- Create character controller with top-down config (gravity = 0)
    local topDownConfig = {
        moveSpeed = 120,  -- Reduced from 200 for more controlled movement
        runSpeed = 200,   -- Reduced from 350
        jumpPower = 0,
        airControl = 1.0,
        gravity = 0,  -- No gravity in top-down mode
        maxFallSpeed = 0,
        groundFriction = 10,
        airFriction = 0.5,
        dashSpeed = 400,  -- Reduced from 500
        dashDuration = 0.2,
        dashCooldown = 1,
        attackDuration = 0.3,
        attackCooldown = 0.5,
        health = 100,
        maxHealth = 100,
    }
    local character = CharacterController.new(entityId, topDownConfig)
    character.position = spawnPos
    self.playerCharacters[player] = character
    self.playerEntities[player] = entityId

    -- Initialize input state for new player
    self.playerLastInput[player] = {
        moveLeft = false,
        moveRight = false,
        moveUp = false,
        moveDown = false,
        jump = false,
        attack = false,
        interact = false,
        dash = false,
    }

    -- Notify network server to spawn player
    self.networkServer:spawnPlayerEntity(player, "default", spawnPos)

    -- Send all static entities to the new player
    self:sendStaticEntitiesToPlayer(player)

    print("Spawned player entity:", entityId, "at", spawnPos.x, spawnPos.y)
end

function GameServer:sendStaticEntitiesToPlayer(player: Player)
    print("Sending", #self.staticEntities, "static entities to player", player.Name)

    for _, staticEntity in ipairs(self.staticEntities) do
        Packets.EntitySpawn.sendTo(player, {
            entityId = staticEntity.entityId,
            position = staticEntity.position,
            entityType = staticEntity.entityType,
            size = staticEntity.size,
            velocity = Vector2.zero(),
            playerId = nil,
            data = nil,
        })
    end
end

function GameServer:despawnPlayer(player: Player)
    local entityId = self.playerEntities[player]
    if not entityId then
        return
    end

    -- Unregister hitbox
    self.hitboxSystem:unregisterHitbox(entityId)

    -- Destroy entity
    self.entityManager:destroyEntity(entityId)

    -- Clean up references
    self.playerCharacters[player] = nil
    self.playerEntities[player] = nil
    self.playerLastInput[player] = nil

    print("Despawned player entity:", entityId)
end

function GameServer:spawnEnemy(enemyType: string, position: Vector2Type): string
    local entityId = self.networkServer:spawnEntity("enemy", position, {type = enemyType})
    local entity = self.entityManager:createEntity(entityId)

    -- Add components
    self.entityManager:addComponent(entityId, "Transform", {
        position = position,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 5,
    })

    self.entityManager:addComponent(entityId, "Enemy", {
        type = enemyType,
        health = 50,
        maxHealth = 50,
        damage = 10,
        moveSpeed = 100,
        aggroRange = 200,
    })

    self.entityManager:addComponent(entityId, "Physics", {
        velocity = Vector2.zero(),
        acceleration = Vector2.zero(),
        mass = 1,
        friction = 0.1,
        restitution = 0,
        isStatic = false,
    })

    self.entityManager:addComponent(entityId, "Hitbox", {
        size = Vector2.new(40, 40),
        offset = Vector2.zero(),
        isTrigger = false,
        layer = 2, -- Enemy layer
        mask = bit32.bor(bit32.lshift(1, 1), bit32.lshift(1, 6)), -- Collides with players and walls
        debugDraw = false,
    })

    self.entityManager:addComponent(entityId, "AI", {
        behavior = "patrol",
        target = nil,
        patrolPoints = {position},
    })

    -- Register hitbox
    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    local hitbox = self.entityManager:getComponent(entityId, "Hitbox") :: Hitbox?
    if transform and hitbox then
        self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
    end

    return entityId
end

function GameServer:handlePlayerAttack(player: Player, data: any?)
    local character = self.playerCharacters[player]
    local entityId = self.playerEntities[player]
    if not character or not entityId then
        return
    end

    -- Create attack hitbox
    local attackId = entityId .. "_attack_" .. tick()
    local attackEntity = self.entityManager:createEntity(attackId)

    local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
    if not transform then
        return
    end

    -- Position attack hitbox in front of player
    local attackOffset = (if character.facingDirection == "right"
        then Vector2.new(30, 0)
        else Vector2.new(-30, 0))
    local attackPos = Vector2.add(transform.position, attackOffset)

    self.entityManager:addComponent(attackId, "Transform", {
        position = attackPos,
        rotation = 0,
        scale = Vector2.one(),
        zIndex = 15,
    })

    self.entityManager:addComponent(attackId, "AttackHitbox", {
        owner = entityId,
        damage = 25,
        knockback = Vector2.new((if character.facingDirection == "right" then 200 else -200), -100),
        lifetime = 0.1,
    })

    self.entityManager:addComponent(attackId, "Hitbox", {
        size = Vector2.new(60, 40),
        offset = Vector2.zero(),
        isTrigger = true,
        layer = 3, -- Player attack layer
        mask = bit32.lshift(1, 2), -- Only hits enemies
        debugDraw = false,
    })

    -- Register hitbox
    local attackTransform = self.entityManager:getComponent(attackId, "Transform") :: Transform?
    local attackHitbox = self.entityManager:getComponent(attackId, "Hitbox") :: Hitbox?
    if attackTransform and attackHitbox then
        self.hitboxSystem:registerHitbox(attackId, attackHitbox, attackTransform)
    end

    -- Schedule hitbox removal
    task.wait(0.1)
    self.hitboxSystem:unregisterHitbox(attackId)
    self.entityManager:destroyEntity(attackId)
end

function GameServer:handlePlayerInteract(player: Player, data: any?)
    -- Handle interaction with world objects
    print("Player interact:", player.Name)
end

function GameServer:handlePlayerEnemyCollision(player: Entity, enemy: Entity, collision: CollisionInfo)
    -- Damage player on contact with enemy
    local playerChar = player.components.Character
    local enemyData = enemy.components.Enemy

    if playerChar and enemyData then
        -- Apply damage to player
        playerChar.health = math.max(0, playerChar.health - enemyData.damage)

        -- Apply knockback
        local physics = player.components.Physics
        if physics then
            local knockback = Vector2.multiply(collision.normal, 300)
            physics.velocity = Vector2.add(physics.velocity, knockback)
        end

        -- Broadcast damage
        local knockback = Vector2.multiply(collision.normal, 300)
        self.networkServer:broadcastDamage(player.id, enemyData.damage, enemy.id, "contact", knockback)
    end
end

function GameServer:handleAttackHit(attackEntity: Entity, targetEntity: Entity, collision: CollisionInfo)
    local attack = attackEntity.components.AttackHitbox
    if not attack then
        return
    end

    -- Check if target is valid (not the owner)
    if targetEntity.id == attack.owner then
        return
    end

    -- Apply damage
    local targetChar = targetEntity.components.Character
    local targetEnemy = targetEntity.components.Enemy

    if targetChar then
        targetChar.health = math.max(0, targetChar.health - attack.damage)
        self.networkServer:broadcastDamage(targetEntity.id, attack.damage, attack.owner, "melee", attack.knockback)
    elseif targetEnemy then
        targetEnemy.health = math.max(0, targetEnemy.health - attack.damage)

        if targetEnemy.health <= 0 then
            -- Enemy defeated
            self:handleEnemyDeath(targetEntity.id)
        else
            self.networkServer:broadcastDamage(targetEntity.id, attack.damage, attack.owner, "melee", attack.knockback)
        end
    end

    -- Apply knockback
    local physics = targetEntity.components.Physics
    if physics and attack.knockback then
        physics.velocity = Vector2.add(physics.velocity, attack.knockback)
    end
end

function GameServer:handleEnemyDeath(entityId: string)
    print("Enemy defeated:", entityId)

    -- Spawn loot, give exp, etc.

    -- Despawn enemy
    self.hitboxSystem:unregisterHitbox(entityId)
    self.networkServer:despawnEntity(entityId, "defeated")
    self.entityManager:destroyEntity(entityId)
end

function GameServer:isPlayer(entity: Entity): boolean
    return entity.components.Character ~= nil
end

function GameServer:isEnemy(entity: Entity): boolean
    return entity.components.Enemy ~= nil
end

function GameServer:isAttackHitbox(entity: Entity): boolean
    return entity.components.AttackHitbox ~= nil
end

function GameServer:start()
    if self.running then
        return
    end

    print("Starting Game Server...")
    self.running = true

    -- Initialize lastTick to current time to prevent huge first deltaTime
    self.lastTick = tick()

    -- Start network server
    self.networkServer:start()

    -- Start game loop
    self.gameLoop = RunService.Heartbeat:Connect(function(deltaTime)
        -- Cap deltaTime to prevent huge jumps when window is minimized/unfocused
        local cappedDeltaTime = math.min(deltaTime, 0.1) -- Max 100ms (10 FPS)
        self:update(cappedDeltaTime)
    end)

    -- Start physics loop
    self.physicsLoop = RunService.Stepped:Connect(function(time, deltaTime)
        -- Cap deltaTime for physics as well
        local cappedDeltaTime = math.min(deltaTime, 0.1)
        self:fixedUpdate(cappedDeltaTime)
    end)
end

function GameServer:stop()
    if not self.running then
        return
    end

    print("Stopping Game Server...")
    self.running = false

    -- Stop network server
    self.networkServer:stop()

    if self.gameLoop then
        self.gameLoop:Disconnect()
        self.gameLoop = nil
    end

    if self.physicsLoop then
        self.physicsLoop:Disconnect()
        self.physicsLoop = nil
    end
end

function GameServer:update(_deltaTime: number)
    -- Server tick rate limiting
    local currentTime = tick()
    local tickInterval = 1 / self.tickRate
    if currentTime - self.lastTick < tickInterval then
        return
    end

    -- Calculate actual deltaTime since last tick (not frame deltaTime)
    -- We don't use the passed deltaTime because it's per-frame, not per-tick
    local actualDeltaTime = currentTime - self.lastTick
    self.lastTick = currentTime

    -- Cap actualDeltaTime to prevent huge movements if server hiccups
    actualDeltaTime = math.min(actualDeltaTime, 0.1) -- Max 100ms

    -- FULLY CLIENT-AUTHORITATIVE MODEL
    -- Client controls movement and collision at 60fps
    -- Server just trusts and relays positions to other players
    for player, character in pairs(self.playerCharacters) do
        local entityId = self.playerEntities[player]
        if entityId then
            -- Get the authoritative position from NetworkServer (sent by client)
            local playerData = self.networkServer.players[player]
            if playerData and playerData.position then
                -- Trust client's position (client already did collision detection at 60fps)
                character.position = Vector2.new(playerData.position.x, playerData.position.y)

                if playerData.velocity then
                    character.velocity = Vector2.new(playerData.velocity.x, playerData.velocity.y)
                end

                -- Sync to transform
                local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
                if transform then
                    transform.position = character.position

                    -- Update hitbox for server-side purposes (AI, etc.)
                    self.hitboxSystem:updateHitbox(entityId, transform)

                    -- Mark entity as dirty for replication to OTHER players
                    self.networkServer:updateEntity(entityId, {
                        entityId = entityId,
                        position = character.position,
                        velocity = character.velocity,
                        state = character.state,
                    })
                end
            end
        end
    end

    -- OLD SERVER-AUTHORITATIVE MODEL (disabled - kept for reference)
    --[[
    for player, character in pairs(self.playerCharacters) do
        local lastInput = self.playerLastInput[player] or {}
        character:update(actualDeltaTime, lastInput)

        local entityId = self.playerEntities[player]
        if entityId then
            local transform = self.entityManager:getComponent(entityId, "Transform") :: Transform?
            if transform then
                transform.position = character.position
                self.networkServer:updateEntity(entityId, {
                    entityId = entityId,
                    position = character.position,
                    velocity = character.velocity,
                    state = character.state,
                })
            end
        end
    end
    ]]

    -- Update ECS with actual deltaTime
    self.entityManager:update(actualDeltaTime)
end

function GameServer:fixedUpdate(deltaTime: number)
    -- Update physics and collision detection
    self.hitboxSystem:update()

    -- Position syncing is now handled in update() to avoid duplication
end

function GameServer:destroy()
    self:stop()

    -- Clean up all systems
    self.entityManager:destroy()
    self.networkServer = nil
    self.hitboxSystem = nil
    self.playerCharacters = {}
    self.playerEntities = {}
end

export type GameServer = typeof(GameServer.new())

return GameServer