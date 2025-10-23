--!strict
-- Main game client that orchestrates all systems

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Import all modules
local EntityManager = require(ReplicatedStorage.Shared.ECS.EntityManager)
local NetworkClient = require(script.Parent.Network.NetworkClient)
local InputManager = require(script.Parent.Input.InputManager)
local WorldRenderer = require(script.Parent.Rendering.WorldRenderer)
local Camera2D = require(script.Parent.Rendering.Camera2D)
local HitboxSystem = require(ReplicatedStorage.Shared.Physics.HitboxSystem)
local CharacterController = require(ReplicatedStorage.Shared.Character.CharacterController)
local AnimationController = require(ReplicatedStorage.Shared.Animation.AnimationController)
local Vector2 = require(ReplicatedStorage.Shared.Utils.Vector2)
local Types = require(ReplicatedStorage.Shared.Types)

type Entity = Types.Entity
type Vector2Type = Types.Vector2

local GameClient = {}
GameClient.__index = GameClient

function GameClient.new()
    local self = setmetatable({}, GameClient)

    -- Core systems
    self.entityManager = EntityManager.new()
    self.networkClient = NetworkClient.new()
    self.inputManager = InputManager.new()
    self.hitboxSystem = HitboxSystem.new()

    -- Rendering
    self.screenGui = nil :: ScreenGui?
    self.worldRenderer = nil :: any?
    self.camera = nil :: any?

    -- Player
    self.localPlayer = Players.LocalPlayer
    self.localCharacter = nil :: any?
    self.localEntityId = nil :: string?
    self.characterControllers = {} :: {[string]: any} -- CharacterController instances

    -- Game state
    self.running = false
    self.deltaTime = 0
    self.gameTime = 0
    self.lastInputSendTime = 0
    self.inputSendRate = 1/60 -- Send input 60 times per second

    -- Debug
    self.debugMode = false -- Will be enabled in initialize()

    -- MEMORY LEAK FIX: Store connections for cleanup
    self.debugInputConnection = nil :: RBXScriptConnection?

    return self
end

function GameClient:initialize()
    print("Initializing Game Client...")

    -- Create Screen GUI
    self.screenGui = Instance.new("ScreenGui")
    self.screenGui.Name = "GameUI"
    self.screenGui.ResetOnSpawn = false
    self.screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    self.screenGui.Parent = self.localPlayer:WaitForChild("PlayerGui")
    self.screenGui.IgnoreGuiInset = true

    -- Initialize rendering systems
    self.worldRenderer = WorldRenderer.new(self.screenGui, {
        pixelScale = 4,
        targetResolution = Vector2.new(1920, 1080),
        maintainAspectRatio = true,
        pixelPerfect = true,
        backgroundColor = Color3.new(0.1, 0.1, 0.2),
        adaptiveZoom = true,  -- Enable adaptive zoom for smaller screens (fixed now)
    })

    self.camera = Camera2D.new(Vector2.new(1920, 1080), {
        zoom = 1,
        minZoom = 0.5,
        maxZoom = 3,
        smoothing = 5,
    })

    -- Set up network callbacks
    self:setupNetworkCallbacks()

    -- Set up input callbacks
    self:setupInputCallbacks()

    -- Register ECS systems
    self:registerSystems()

    -- Connect to server
    self.networkClient:connect()

    print("Game Client initialized successfully!")
end

function GameClient:setupNetworkCallbacks()
    -- Entity spawned
    self.networkClient.onEntitySpawn = function(entityId: string, data: any)
        print("Entity spawned:", entityId, "Type:", data.entityType or "player")

        -- Check if entity already exists - if so, skip spawning
        if self.entityManager:getEntity(entityId) then
            warn("Entity already exists:", entityId, "- skipping spawn")
            return
        end

        -- Create entity in ECS
        local entity = self.entityManager:createEntity(entityId)

        -- Determine entity type
        local entityType = data.entityType or "player"
        local isObstacle = entityType == "obstacle" or entityType == "wall"

        -- Add transform component (convert network position to Vector2)
        local position = Vector2.new(data.position.x, data.position.y)
        self.entityManager:addComponent(entityId, "Transform", {
            position = position,
            rotation = 0,
            scale = Vector2.one(),
            zIndex = (if isObstacle then 5 else 10),
        })

        -- Determine visual properties based on entity type
        local imageId = "rbxassetid://128490447315329"
        local size = Vector2.new(64, 64)
        local color = Color3.new(1, 1, 1)

        if entityType == "obstacle" then
            imageId = "" -- No sprite, solid color
            size = data.size or Vector2.new(100, 100)
            color = Color3.new(0.5, 0.5, 0.5) -- Gray
        elseif entityType == "wall" then
            imageId = "" -- No sprite, solid color
            size = data.size or Vector2.new(100, 20)
            color = Color3.new(0.3, 0.3, 0.4) -- Dark gray/blue
        end

        -- Add sprite component
        self.entityManager:addComponent(entityId, "Sprite", {
            imageId = imageId,
            size = size,
            offset = Vector2.zero(),
            color = color,
            transparency = 0,
            flipX = false,
            flipY = false,
        })

        -- Create renderer for entity
        if isObstacle then
            -- Create colored rectangle for obstacles
            local renderer = self.worldRenderer:createEntityRenderer(entityId, "", size)
            if renderer then
                renderer.BackgroundColor3 = color
                renderer.BackgroundTransparency = 0
                print("Created obstacle renderer:", entityId, "at", position.x, position.y, "size", size.x, size.y, "color", color)
            end
        else
            -- Create sprite renderer for players/entities
            self.worldRenderer:createEntityRenderer(entityId, imageId, size)
        end

        -- Add hitbox for obstacles and walls
        if isObstacle then
            self.entityManager:addComponent(entityId, "Hitbox", {
                size = size,
                offset = Vector2.zero(),
                isTrigger = false,
                layer = 6, -- Wall layer
                mask = bit32.lshift(1, 1), -- Collides with Player layer
                debugDraw = self.debugMode,
            })

            -- Register hitbox with HitboxSystem
            local transform = self.entityManager:getComponent(entityId, "Transform")
            local hitbox = self.entityManager:getComponent(entityId, "Hitbox")
            if transform and hitbox then
                self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
            end

            -- Immediately set position for obstacles (they don't move)
            if self.worldRenderer then
                self.worldRenderer:updateEntityPosition(entityId, transform.position)
            end
        end

        -- Setup sprite sheet animation for player entities
        if data.playerId then
            self.worldRenderer:setupEntityAnimation(entityId, {
                spriteSheet = "rbxassetid://128490447315329",
                frameWidth = 64,
                frameHeight = 64,
                animations = {
                    idle = { startFrame = 0, endFrame = 4, frameRate = 8, loop = true },
                    right = { startFrame = 5, endFrame = 8, frameRate = 12, loop = true },
                    up = { startFrame = 13, endFrame = 16, frameRate = 12, loop = true },
                    down = { startFrame = 9, endFrame = 12, frameRate = 12, loop = true },
                    -- Attack animations
                    attack_right = { startFrame = 17, endFrame = 24, frameRate = 12, loop = false },
                    attack_up = { startFrame = 33, endFrame = 40, frameRate = 12, loop = false },
                    attack_down = { startFrame = 25, endFrame = 32, frameRate = 12, loop = false },
                    -- Skill animation (using new sprite sheet with 128x128 frames, 8 columns layout)
                    skill = { startFrame = 0, endFrame = 12, frameRate = 15, loop = false, spriteSheet = "rbxassetid://111630265859486", frameWidth = 128, frameHeight = 128, columns = 7 },
                    skill_effect = { startFrame = 13, endFrame = 20, frameRate = 15, loop = false, spriteSheet = "rbxassetid://111630265859486", frameWidth = 128, frameHeight = 128, columns = 7 },
                }
            })
            
            -- Start with idle animation
            local animController = self.worldRenderer:getEntityAnimation(entityId)
            if animController then
                animController:play("idle")
            end
        end

        -- Skill animations configured with sprite sheet rbxassetid://111630265859486

        -- If this is a player entity
        if data.playerId then
            -- Add character component
            self.entityManager:addComponent(entityId, "Character", {
                playerId = data.playerId,
                state = "idle",
                health = 100,
                maxHealth = 100,
                moveSpeed = 120,  -- Reduced from 200
                jumpPower = 400,
                facingDirection = "right",
                isGrounded = false,
                canMove = true,
                canJump = true,
            })

            -- Add hitbox component (smaller, tighter hitbox for better gameplay feel)
            self.entityManager:addComponent(entityId, "Hitbox", {
                size = Vector2.new(28, 36), -- Tight hitbox: 28 wide x 36 tall
                offset = Vector2.new(0, 4), -- Center on character body
                isTrigger = false,
                layer = 1, -- Player layer
                mask = bit32.bor(bit32.lshift(1, 2), bit32.lshift(1, 6)), -- Collides with enemies and walls
                debugDraw = self.debugMode,
            })

            -- Create CharacterController for player entities
            local charController = CharacterController.new(entityId, {
                moveSpeed = 120,  -- Reduced from 200 for more controlled movement
                runSpeed = 200,   -- Reduced from 350
                jumpPower = 0, -- Not used in top-down
                airControl = 1,
                gravity = 0, -- Top-down 2D (no gravity)
                maxFallSpeed = 0,
                groundFriction = 8, -- Friction for smooth stopping
                airFriction = 0,
                dashSpeed = 400,  -- Reduced from 500
                dashDuration = 0.2,
                dashCooldown = 1,
                attackDuration = 0.67,  -- Match animation length: 8 frames at 12 FPS
                attackCooldown = 0.2,  -- Short cooldown to allow rapid attacks
                health = 100,
                maxHealth = 100,
            })

            -- Initialize controller position from transform
            local transform = self.entityManager:getComponent(entityId, "Transform")
            if transform then
                charController.position = transform.position
            end

            -- Store character controller
            self.characterControllers[entityId] = charController

            -- Register player hitbox with HitboxSystem
            local hitbox = self.entityManager:getComponent(entityId, "Hitbox")
            if transform and hitbox then
                self.hitboxSystem:registerHitbox(entityId, hitbox, transform)
            end

            -- If this is the local player
            if data.playerId == tostring(self.localPlayer.UserId) then
                self.localEntityId = entityId
                self.localCharacter = charController
                self:setupLocalPlayer(entityId)
            end
        end
    end

    -- Entity despawned
    self.networkClient.onEntityDespawn = function(entityId: string)
        print("Entity despawned:", entityId)

        -- Unregister hitbox from HitboxSystem
        self.hitboxSystem:unregisterHitbox(entityId)

        -- Remove character controller
        if self.characterControllers[entityId] then
            self.characterControllers[entityId] = nil
        end

        -- Remove renderer
        self.worldRenderer:removeEntityRenderer(entityId)

        -- Remove from ECS
        self.entityManager:destroyEntity(entityId)

        -- If this was the local player
        if entityId == self.localEntityId then
            self.localEntityId = nil
            self.localCharacter = nil
        end
    end

    -- Entity update
    self.networkClient.onEntityUpdate = function(entityId: string, update: Types.EntityUpdate)
        if update.position and tick() % 2 < 0.016 then
            print("[CLIENT] Received update for", entityId, "pos:", math.floor(update.position.x), math.floor(update.position.y))
        end

        -- Update entity components
        local transform = self.entityManager:getComponent(entityId, "Transform")
        if transform and update.position then
            -- For remote players, DO NOT immediately apply position!
            -- NetworkClient will handle interpolation between updates.
            -- We only update the transform for local player or if it's a significant teleport

            if entityId == self.localEntityId then
                -- Local player is fully client-authoritative - ignore server position updates
                -- Server only relays our position to other players, doesn't send corrections back
                -- (This prevents jitter and teleporting from delayed server corrections)
            else
                -- For remote players, let the interpolation system handle smooth movement
                -- We'll update their position in the update loop using interpolation

                -- Only update character controller velocity for animation purposes
                local charController = self.characterControllers[entityId]
                if charController and update.velocity then
                    charController.velocity = Vector2.new(update.velocity.x, update.velocity.y)
                end

                -- Check for teleportation (position change > 500 units indicates teleport/respawn)
                local newPosition = Vector2.new(update.position.x, update.position.y)
                local distance = Vector2.distance(transform.position, newPosition)
                if distance > 500 then
                    -- This is a teleport, apply immediately
                    transform.position = newPosition
                    if self.worldRenderer then
                        self.worldRenderer:updateEntityPosition(entityId, newPosition)
                    end
                    if charController then
                        charController.position = newPosition
                    end
                end
            end
        end

        if update.state then
            local character = self.entityManager:getComponent(entityId, "Character")
            if character then
                character.state = update.state
            end
        end

        if update.health then
            local character = self.entityManager:getComponent(entityId, "Character")
            if character then
                character.health = update.health
            end
        end
    end

    -- World state (for late joiners to see existing entities)
    self.networkClient.onWorldState = function(state: any)
        print("Received world state with", #state.entities, "entities")

        -- Spawn all entities from world state
        for _, entityData in ipairs(state.entities) do
            -- Skip if this entity already exists (like our own player)
            if self.entityManager:getEntity(entityData.entityId) then
                print("Skipping already existing entity:", entityData.entityId)
                continue
            end

            print("Spawning entity from world state:", entityData.entityId, "Type:", entityData.entityType)

            -- Call the entity spawn handler to create the entity
            if self.networkClient.onEntitySpawn then
                self.networkClient.onEntitySpawn(entityData.entityId, entityData)
            end
        end
    end
end

function GameClient:setupInputCallbacks()
    -- Movement
    self.inputManager:onAction("jump", function(pressed)
        if pressed and self.localCharacter then
            self.localCharacter:performAction("jump")
        end
    end)

    self.inputManager:onAction("attack", function(pressed)
        if pressed and self.localCharacter then
            self.localCharacter:performAction("attack")
        end
    end)

    self.inputManager:onAction("skill", function(pressed)
        if pressed and self.localCharacter then
            self.localCharacter:performAction("skill")
        end
    end)

    self.inputManager:onAction("dash", function(pressed)
        if pressed and self.localCharacter then
            self.localCharacter:performAction("dash")
        end
    end)

    -- Debug toggle - Use direct UserInputService binding to avoid conflicts
    local UserInputService = game:GetService("UserInputService")
    self.debugInputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if input.KeyCode == Enum.KeyCode.U and not gameProcessedEvent then
            self:toggleDebugMode()
        end
    end)
end

function GameClient:setupLocalPlayer(entityId: string)
    print("Setting up local player:", entityId)

    -- Get the existing character controller (already created in spawn callback)
    self.localCharacter = self.characterControllers[entityId]
    if not self.localCharacter then
        warn("No character controller found for local player:", entityId)
        return
    end

    -- Set camera to follow player
    self.camera:follow(entityId)

    -- Set up character callbacks
    self.localCharacter.onStateChange = function(oldState, newState)
        -- Update animation based on state
        local renderer = self.worldRenderer.entityRenderers[entityId]
        if renderer then
            -- Animation logic would go here
        end
    end

    self.localCharacter.onDamage = function(damage, source)
        print("Player took damage:", damage, "from:", source or "unknown")
        -- Show damage effect
        self.camera:shake(5, 0.2)
        self.inputManager:vibrate(0.1, 0.5)
    end

    self.localCharacter.onDeath = function()
        print("Player died!")
        -- Handle death
    end
end

function GameClient:registerSystems()
    -- Character Controller system
    local CharacterControllerSystem = {
        name = "CharacterController",
        priority = 1,
        requiredComponents = {"Transform", "Character"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                local charController = self.characterControllers[entity.id]
                if not charController then
                    continue
                end

                -- Get transform component
                local transform = entity.components.Transform

                -- Only update character controller for local player
                -- Remote players get their positions from server updates
                if entity.id == self.localEntityId then
                    -- Get input state for local player
                    local inputState = {
                        moveLeft = false,
                        moveRight = false,
                        moveUp = false,
                        moveDown = false,
                        jump = false,
                        attack = false,
                        interact = false,
                        dash = false,
                    }

                    if self.inputManager then
                        inputState = self.inputManager.inputState
                    end

                    -- Get mouse position in world coordinates
                    local mouseWorldPos = nil
                    if self.inputManager and self.camera and self.worldRenderer then
                        local mouseScreenPos = self.inputManager:getMousePosition()
                        -- Convert screen position to world position using camera
                        local cameraPos = self.camera:getPosition()
                        local zoom = self.camera.zoom

                        -- Get actual pixel scale from world renderer
                        local pixelScale = self.worldRenderer.config.pixelScale

                        -- Get the world container to account for any scaling/positioning
                        local worldContainer = self.worldRenderer.worldContainer
                        if worldContainer then
                            -- Convert screen position to viewport-relative position
                            local viewportPos = Vector2.new(
                                mouseScreenPos.x - worldContainer.AbsolutePosition.X,
                                mouseScreenPos.y - worldContainer.AbsolutePosition.Y
                            )

                            -- Convert to world coordinates
                            mouseWorldPos = Vector2.new(
                                (viewportPos.x - worldContainer.AbsoluteSize.X/2) / (pixelScale * zoom) + cameraPos.x,
                                (viewportPos.y - worldContainer.AbsoluteSize.Y/2) / (pixelScale * zoom) + cameraPos.y
                            )
                        end
                    end

                    -- Track blocked directions from collisions
                    local blockedX = false
                    local blockedY = false

                    -- Update character controller with input and mouse position
                    charController:update(deltaTime, inputState, mouseWorldPos)

                    -- Sync transform with character controller for local player
                    transform.position = charController.position

                    -- Update hitbox BEFORE collision check
                    local hitbox = entity.components.Hitbox
                    if hitbox then
                        self.hitboxSystem:updateHitbox(entity.id, transform)

                        -- CLIENT-SIDE COLLISION DETECTION (before sending to server!)
                        local nearbyEntities = self.hitboxSystem:getNearbyEntities(entity.id)
                        for _, otherId in ipairs(nearbyEntities) do
                            local collision = self.hitboxSystem:checkCollision(entity.id, otherId)
                            if collision and not collision.isTrigger then
                                -- Resolve collision by pushing player back
                                -- penetration already points in the correction direction
                                charController.position = Vector2.add(charController.position, collision.penetration)
                                transform.position = charController.position

                                -- Determine which axis is blocked based on collision normal
                                if math.abs(collision.normal.x) > 0.5 then
                                    blockedX = true
                                end
                                if math.abs(collision.normal.y) > 0.5 then
                                    blockedY = true
                                end

                                -- Stop velocity in the direction of collision
                                -- When moving into a wall, velocity dot normal is negative
                                local normalDot = Vector2.dot(charController.velocity, collision.normal)
                                if normalDot < 0 then
                                    -- Remove the velocity component moving into the wall
                                    local velocityCorrection = Vector2.multiply(collision.normal, normalDot)
                                    charController.velocity = Vector2.subtract(charController.velocity, velocityCorrection)
                                end

                                -- Update hitbox position after correction
                                self.hitboxSystem:updateHitbox(entity.id, transform)
                            end
                        end

                        -- If movement was blocked, zero out velocity in blocked directions completely
                        if blockedX or blockedY then
                            charController.velocity = Vector2.new(
                                blockedX and 0 or charController.velocity.x,
                                blockedY and 0 or charController.velocity.y
                            )
                        end
                    end

                    -- NOW send validated position to server (after collision resolution)
                    self:sendInputToServer(inputState)
                else
                    -- For remote players, position is already being smoothed by RemotePlayerSmoothingSystem
                    -- Just keep CharacterController in sync with transform
                    charController.position = transform.position
                end

                -- Sync character component state
                local character = entity.components.Character
                character.state = charController.state
                character.facingDirection = charController.facingDirection
                character.health = charController.health
                character.isGrounded = charController.isGrounded

                -- Update position for rendering
                if self.worldRenderer then
                    self.worldRenderer:updateEntityPosition(entity.id, transform.position)
                end
            end
        end,
    }

    -- Animation system
    local AnimationSystem = {
        name = "Animation",
        priority = 2,
        requiredComponents = {"Sprite", "Character"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                -- Get animation controller for this entity
                local animController = self.worldRenderer:getEntityAnimation(entity.id)
                if not animController then
                    continue
                end

                -- Get character controller for velocity info
                local charController = self.characterControllers[entity.id]
                if not charController then
                    continue
                end

                local targetAnimation = "idle"
                local shouldFlip = false

                -- Check if character is using skill (highest priority)
                if charController.state == "skill" then
                    targetAnimation = "skill"

                    -- Flip sprite based on facing direction
                    if charController.facingDirection == "left" then
                        shouldFlip = true
                    end

                    -- Apply sprite flip
                    if self.worldRenderer then
                        self.worldRenderer:setEntityFlip(entity.id, shouldFlip)
                    end

                    -- Play skill animation ONCE - don't restart if already playing
                    local currentAnim = animController:getCurrentAnimation()
                    if currentAnim ~= "skill" then
                        animController:play(targetAnimation)
                    end

                    -- Check if we need to spawn the effect
                    if charController.skillEffectTriggered and not charController.skillEffectSpawned then
                        charController.skillEffectSpawned = true
                        -- Create a temporary effect entity at the player's position
                        local effectId = "skill_effect_" .. tostring(entity.id) .. "_" .. tostring(tick())

                        -- Position the effect at the same position as the player
                        local effectPosition = charController.skillEffectPosition or charController.position

                        -- Create renderer for the effect at 64x64 (will be scaled 2x to 128x128 by AnimationController due to 128x128 frames)
                        local renderer = self.worldRenderer:createEntityRenderer(effectId, "rbxassetid://111630265859486", Vector2.new(64, 64))

                        -- Set the position immediately
                        if renderer then
                            self.worldRenderer:updateEntityPosition(effectId, effectPosition)
                            -- Make sure it's visible
                            renderer.Visible = true
                            renderer.ZIndex = 100  -- Put it on top
                        end

                        -- Setup the effect animation with 128x128 frames and 7 columns
                        self.worldRenderer:setupEntityAnimation(effectId, {
                            spriteSheet = "rbxassetid://111630265859486",
                            frameWidth = 128,
                            frameHeight = 128,
                            animations = {
                                -- Effect frames 13-20 (8 frames) at 10 FPS with 7 columns
                                effect = { startFrame = 13, endFrame = 20, frameRate = 10, loop = false, columns = 7 },
                            }
                        })

                        -- Apply flip if character is facing left
                        if charController.facingDirection == "left" then
                            self.worldRenderer:setEntityFlip(effectId, true)
                        end

                        -- Play the effect animation
                        local effectAnimController = self.worldRenderer:getEntityAnimation(effectId)
                        if effectAnimController then
                            effectAnimController:play("effect")

                            -- Schedule cleanup after animation completes (0.8 seconds for 8 frames at 10 FPS)
                            task.spawn(function()
                                task.wait(0.8)
                                if self.worldRenderer then
                                    self.worldRenderer:removeEntityRenderer(effectId)
                                end
                                -- Don't reset skillEffectSpawned here - let CharacterController handle it when skill ends
                            end)
                        end
                    end
                -- Check if character is attacking (second priority)
                elseif charController.state == "attacking" then
                    -- Use stored attack direction to determine animation
                    local attackDir = charController.attackDirection

                    if attackDir == "right" then
                        targetAnimation = "attack_right"
                        -- Flip sprite when facing left
                        if charController.facingDirection == "left" then
                            shouldFlip = true
                        end
                    elseif attackDir == "up" then
                        targetAnimation = "attack_up"
                    else -- "down"
                        targetAnimation = "attack_down"
                    end

                    -- Apply sprite flip
                    if self.worldRenderer then
                        self.worldRenderer:setEntityFlip(entity.id, shouldFlip)
                    end

                    -- Play attack animation ONCE - don't restart if already playing
                    local currentAnim = animController:getCurrentAnimation()
                    if not currentAnim or not currentAnim:find("attack") then
                        animController:play(targetAnimation)
                    end
                else
                    -- Normal movement animations
                    local velocity = charController.velocity
                    local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

                    -- Use a higher threshold (5 px/s) to prevent animation flickering when barely moving
                    if speed > 5 then
                        -- Character is moving - determine direction based on velocity
                        if math.abs(velocity.x) > math.abs(velocity.y) then
                            -- Horizontal movement dominant
                            -- Use "right" animation for both left and right
                            targetAnimation = "right"

                            -- Flip sprite when moving left
                            if velocity.x < 0 then
                                shouldFlip = true
                            end
                        else
                            -- Vertical movement dominant
                            if velocity.y > 0 then
                                targetAnimation = "down"
                            else
                                targetAnimation = "up"
                            end
                        end
                    end

                    -- Apply sprite flip for horizontal movement
                    if self.worldRenderer then
                        self.worldRenderer:setEntityFlip(entity.id, shouldFlip)
                    end

                    -- Force play animation when transitioning from attack or when animation is not playing
                    local currentAnim = animController:getCurrentAnimation()
                    local isAttackAnim = currentAnim and currentAnim:find("attack")

                    -- Play animation if:
                    -- 1. Current animation is an attack animation (force transition)
                    -- 2. Target animation is not currently playing
                    if isAttackAnim or not animController:isPlaying(targetAnimation) then
                        animController:play(targetAnimation)
                    end
                end
            end
        end,
    }

    -- Static Object Rendering system (for obstacles/walls)
    local StaticObjectRenderingSystem = {
        name = "StaticObjectRendering",
        priority = 3,
        requiredComponents = {"Transform", "Sprite"},
        enabled = true,
        update = function(system, entityManager, entities, _deltaTime)
            for _, entity in ipairs(entities) do
                -- Only update if this is NOT a character (static objects)
                if not entity.components.Character then
                    local transform = entity.components.Transform
                    if self.worldRenderer then
                        self.worldRenderer:updateEntityPosition(entity.id, transform.position)
                    end
                end
            end
        end,
    }

    -- Camera system
    local CameraSystem = {
        name = "Camera",
        priority = 10,
        requiredComponents = {},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            if self.localEntityId and self.camera then
                local transform = self.entityManager:getComponent(self.localEntityId, "Transform")
                if transform then
                    self.camera:update(deltaTime, transform.position)
                    self.worldRenderer:setCameraPosition(self.camera:getPosition())
                    self.worldRenderer:setCameraZoom(self.camera.zoom)
                end
            end
        end,
    }

    -- Remote Player Smoothing system (runs before CharacterController)
    local RemotePlayerSmoothingSystem = {
        name = "RemotePlayerSmoothing",
        priority = 0, -- Run before CharacterController
        requiredComponents = {"Transform", "Character"},
        enabled = true,
        update = function(system, entityManager, entities, deltaTime)
            for _, entity in ipairs(entities) do
                -- Only smooth remote players, not local player
                if entity.id ~= self.localEntityId then
                    local transform = entity.components.Transform
                    local charController = self.characterControllers[entity.id]

                    if charController then
                        -- Get interpolated position from NetworkClient
                        local targetPos = self.networkClient:getInterpolatedPosition(entity.id)
                        if targetPos then
                            -- Convert to Vector2
                            local targetPosition = Vector2.new(targetPos.x, targetPos.y)

                            -- Apply exponential smoothing for extra smoothness
                            -- This creates a "rubber band" effect that smoothly pulls the player to target
                            local smoothingFactor = 12 -- Higher = snappier, Lower = smoother
                            local t = 1 - math.exp(-smoothingFactor * deltaTime)

                            -- Smooth both position and character controller
                            local currentPos = transform.position
                            local smoothedPos = Vector2.lerp(currentPos, targetPosition, t)

                            -- Update positions
                            transform.position = smoothedPos
                            charController.position = smoothedPos

                            -- Calculate smoothed velocity for animations
                            if not entity.lastSmoothPosition then
                                entity.lastSmoothPosition = smoothedPos
                            end
                            local smoothVelocity = Vector2.divide(
                                Vector2.subtract(smoothedPos, entity.lastSmoothPosition),
                                math.max(deltaTime, 0.001) -- Prevent divide by zero
                            )
                            entity.lastSmoothPosition = smoothedPos

                            -- Update velocity for animation purposes (if not already set from network)
                            if Vector2.length(charController.velocity) < 1 then
                                charController.velocity = smoothVelocity
                            end
                        end
                    end
                end
            end
        end,
    }

    self.entityManager:registerSystem(RemotePlayerSmoothingSystem)
    self.entityManager:registerSystem(CharacterControllerSystem)
    self.entityManager:registerSystem(AnimationSystem)
    self.entityManager:registerSystem(StaticObjectRenderingSystem)
    self.entityManager:registerSystem(CameraSystem)
end

function GameClient:start()
    if self.running then
        return
    end

    print("Starting game client...")
    self.running = true

    -- Main game loop
    self.gameLoop = RunService.Heartbeat:Connect(function(deltaTime)
        -- Cap deltaTime to prevent huge jumps when window is minimized/unfocused
        local cappedDeltaTime = math.min(deltaTime, 0.1) -- Max 100ms (10 FPS)
        self:update(cappedDeltaTime)
    end)

    -- Fixed update loop for physics
    self.fixedLoop = RunService.Stepped:Connect(function(time, deltaTime)
        -- Cap deltaTime for physics as well
        local cappedDeltaTime = math.min(deltaTime, 0.1)
        self:fixedUpdate(cappedDeltaTime)
    end)
end

function GameClient:stop()
    if not self.running then
        return
    end

    print("Stopping game client...")
    self.running = false

    if self.gameLoop then
        self.gameLoop:Disconnect()
        self.gameLoop = nil
    end

    if self.fixedLoop then
        self.fixedLoop:Disconnect()
        self.fixedLoop = nil
    end
end

function GameClient:update(deltaTime: number)
    self.deltaTime = deltaTime
    self.gameTime = self.gameTime + deltaTime

    -- Get input state
    local inputState = self.inputManager.inputState

    -- Send input to server (character controller is updated in CharacterControllerSystem)
    if self.localCharacter then
        local hasInput = inputState.moveLeft or inputState.moveRight or inputState.moveUp or inputState.moveDown
        if hasInput and tick() % 2 < deltaTime then -- Print every ~2 seconds when moving
            print("[CLIENT] Sending input - LocalChar exists:", self.localCharacter ~= nil, "Connected:", self.networkClient.connected)
        end
        self.networkClient:sendInput(inputState, deltaTime)
    else
        if tick() % 3 < deltaTime then
            print("[CLIENT] WARNING: No localCharacter! EntityID:", self.localEntityId)
        end
    end

    -- Update ECS
    self.entityManager:update(deltaTime)

    -- Update renderer culling
    local entities = {}
    for _, entity in pairs(self.entityManager.entities) do
        local transform = entity.components.Transform
        if transform then
            entities[entity.id] = {
                position = transform.position,
                size = Vector2.new(64, 64), -- Default size
            }
        end
    end
    self.worldRenderer:performCulling(entities)
end

function GameClient:fixedUpdate(deltaTime: number)
    -- Update hitbox system
    self.hitboxSystem:update()
end

function GameClient:sendInputToServer(inputState: any)
    -- Throttle position updates to reduce network traffic
    local currentTime = tick()
    if currentTime - self.lastInputSendTime < self.inputSendRate then
        return
    end

    self.lastInputSendTime = currentTime

    -- Send authoritative position/velocity to server (client-authoritative model)
    -- Client has already processed movement and collision at 60fps with full accuracy
    if self.networkClient and self.localEntityId and self.localCharacter then
        -- Send position update with velocity for smooth interpolation on other clients
        self.networkClient:sendPositionUpdate(
            self.localCharacter.position,
            self.localCharacter.velocity,
            self.localCharacter.state
        )
    end
end

function GameClient:toggleDebugMode()
    self.debugMode = not self.debugMode

    print("Debug mode:", self.debugMode and "ON" or "OFF")

    -- Update renderer debug mode
    if self.worldRenderer then
        self.worldRenderer:setDebugMode(self.debugMode)
    end

    -- Update hitbox debug visualization
    if self.hitboxSystem then
        -- Get the debug container from WorldRenderer instead of screenGui
        local debugContainer = self.worldRenderer.debugContainer
        self.hitboxSystem:setDebugDraw(self.debugMode, debugContainer, self.worldRenderer)
    end

    -- Update entity manager debug
    self.entityManager:setDebug(self.debugMode)

    if self.debugMode then
        print(self.entityManager:getDebugInfo())
    end
end

function GameClient:destroy()
    self:stop()

    -- MEMORY LEAK FIX: Disconnect debug input connection
    if self.debugInputConnection then
        self.debugInputConnection:Disconnect()
        self.debugInputConnection = nil
    end

    -- Clean up all systems
    if self.networkClient then
        self.networkClient:disconnect()
    end

    if self.inputManager then
        self.inputManager:destroy()
    end

    if self.worldRenderer then
        self.worldRenderer:destroy()
    end

    if self.camera then
        self.camera:destroy()
    end

    if self.entityManager then
        self.entityManager:destroy()
    end

    if self.screenGui then
        self.screenGui:Destroy()
    end
end

return GameClient