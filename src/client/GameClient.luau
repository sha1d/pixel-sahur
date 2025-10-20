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
    self.debugMode = false

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

        -- Create entity in ECS
        local entity = self.entityManager:createEntity(entityId)

        -- Determine entity type
        local entityType = data.entityType or "player"
        local isObstacle = entityType == "obstacle" or entityType == "wall"

        -- Add transform component
        self.entityManager:addComponent(entityId, "Transform", {
            position = data.position,
            rotation = 0,
            scale = Vector2.one(),
            zIndex = if isObstacle then 5 else 10,
        })

        -- Determine visual properties based on entity type
        local imageId = "rbxassetid://112564202907644"
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
                print("Created obstacle renderer:", entityId, "at", data.position.x, data.position.y, "size", size.x, size.y, "color", color)
            end
        else
            -- Create sprite renderer for players/entities
            self.worldRenderer:createEntityRenderer(entityId, imageId, size)
        end

        -- Immediately set position for obstacles (they don't move)
        if isObstacle and self.worldRenderer then
            local transform = self.entityManager:getComponent(entityId, "Transform")
            if transform then
                self.worldRenderer:updateEntityPosition(entityId, transform.position)
            end
        end

        -- Setup sprite sheet animation for player entities
        if data.playerId then
            self.worldRenderer:setupEntityAnimation(entityId, {
                spriteSheet = "rbxassetid://112564202907644",
                frameWidth = 64,
                frameHeight = 64,
                animations = {
                    idle = { startFrame = 0, endFrame = 4, frameRate = 10, loop = true },
                    right = { startFrame = 5, endFrame = 8, frameRate = 10, loop = true },  -- Used for both left (flipped) and right
                    up = { startFrame = 13, endFrame = 16, frameRate = 10, loop = true },
                    down = { startFrame = 9, endFrame = 12, frameRate = 10, loop = true },
                }
            })

            -- Start with idle animation
            local animController = self.worldRenderer:getEntityAnimation(entityId)
            if animController then
                animController:play("idle")
            end
        end

        -- If this is a player entity
        if data.playerId then
            -- Add character component
            self.entityManager:addComponent(entityId, "Character", {
                playerId = data.playerId,
                state = "idle",
                health = 100,
                maxHealth = 100,
                moveSpeed = 200,
                jumpPower = 400,
                facingDirection = "right",
                isGrounded = false,
                canMove = true,
                canJump = true,
            })

            -- Add hitbox component
            self.entityManager:addComponent(entityId, "Hitbox", {
                size = Vector2.new(48, 60),
                offset = Vector2.zero(),
                isTrigger = false,
                layer = 1, -- Player layer
                mask = bit32.bor(bit32.lshift(1, 2), bit32.lshift(1, 6)), -- Collides with enemies and walls
                debugDraw = self.debugMode,
            })

            -- Create CharacterController for player entities
            local charController = CharacterController.new(entityId, {
                moveSpeed = 200,
                runSpeed = 350,
                jumpPower = 0, -- Not used in top-down
                airControl = 1,
                gravity = 0, -- Top-down 2D (no gravity)
                maxFallSpeed = 0,
                groundFriction = 8, -- Friction for smooth stopping
                airFriction = 0,
                dashSpeed = 500,
                dashDuration = 0.2,
                dashCooldown = 1,
                attackDuration = 0.3,
                attackCooldown = 0.5,
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
        -- Update entity components
        local transform = self.entityManager:getComponent(entityId, "Transform")
        if transform and update.position then
            transform.position = update.position
        end

        -- If this is the local player, also update the character controller
        if entityId == self.localEntityId and update.position then
            local charController = self.characterControllers[entityId]
            if charController then
                -- Calculate distance between current position and correction
                local dx = update.position.x - charController.position.x
                local dy = update.position.y - charController.position.y
                local distance = math.sqrt(dx * dx + dy * dy)

                -- Only apply correction if distance is significant (> 5 pixels)
                -- This prevents micro-corrections from interfering with smooth movement
                if distance > 5 then
                    charController.position = update.position
                    -- Also update velocity
                    if update.velocity then
                        charController.velocity = update.velocity
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

    self.inputManager:onAction("dash", function(pressed)
        if pressed and self.localCharacter then
            self.localCharacter:performAction("dash")
        end
    end)

    -- Debug toggle
    self.inputManager:bindAction("debug", {Enum.KeyCode.F3}, nil)
    self.inputManager:onAction("debug", function(pressed)
        if pressed then
            self:toggleDebugMode()
        end
    end)
end

function GameClient:setupLocalPlayer(entityId: string)
    print("Setting up local player:", entityId)

    -- Create character controller
    self.localCharacter = CharacterController.new(entityId)

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

                -- Get input state (only for local player)
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

                if entity.id == self.localEntityId and self.inputManager then
                    inputState = self.inputManager.inputState
                end

                -- Update character controller
                charController:update(deltaTime, inputState)

                -- Sync transform with character controller
                local transform = entity.components.Transform
                transform.position = charController.position

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

                -- Send input to server (only for local player)
                if entity.id == self.localEntityId then
                    self:sendInputToServer(inputState)
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

                -- Determine which animation to play based on velocity
                local targetAnimation = "idle"
                local shouldFlip = false
                local velocity = charController.velocity
                local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

                if speed > 10 then
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

                -- Play animation if different from current
                if not animController:isPlaying(targetAnimation) then
                    animController:play(targetAnimation)
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

    -- Update local character
    if self.localCharacter then
        self.localCharacter:update(deltaTime, inputState)

        -- Send input to server
        self.networkClient:sendInput(inputState, deltaTime)
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
    -- Throttle input sending to reduce network traffic
    local currentTime = tick()
    if currentTime - self.lastInputSendTime < self.inputSendRate then
        return
    end

    self.lastInputSendTime = currentTime

    -- Send input state to server for server-side validation
    if self.networkClient and self.localEntityId then
        -- Use the NetworkClient's sendInput method
        -- It handles sequencing and buffering internally
        self.networkClient:sendInput(inputState, self.deltaTime)
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
        self.hitboxSystem:setDebugDraw(self.debugMode, self.screenGui)
    end

    -- Update entity manager debug
    self.entityManager:setDebug(self.debugMode)

    if self.debugMode then
        print(self.entityManager:getDebugInfo())
    end
end

function GameClient:destroy()
    self:stop()

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