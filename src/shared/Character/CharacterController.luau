--!strict

local Types = require(script.Parent.Parent.Types)
local Vector2 = require(script.Parent.Parent.Utils.Vector2)

type Vector2Type = Types.Vector2
type CharacterState = Types.CharacterState
type InputState = Types.InputState

local CharacterController = {}
CharacterController.__index = CharacterController

export type CharacterConfig = {
    moveSpeed: number,
    runSpeed: number,
    jumpPower: number,
    airControl: number,
    gravity: number,
    maxFallSpeed: number,
    groundFriction: number,
    airFriction: number,
    dashSpeed: number,
    dashDuration: number,
    dashCooldown: number,
    attackDuration: number,
    attackCooldown: number,
    health: number,
    maxHealth: number,
}

export type CharacterAction = {
    name: string,
    duration: number,
    cooldown: number,
    canMove: boolean,
    canJump: boolean,
    canCancel: boolean,
    animation: string,
    onStart: ((self: CharacterController) -> ())?,
    onUpdate: ((self: CharacterController, dt: number) -> ())?,
    onEnd: ((self: CharacterController) -> ())?,
}

function CharacterController.new(entityId: string, config: CharacterConfig?)
    local self = setmetatable({}, CharacterController)

    self.entityId = entityId

    -- Configuration
    local defaultConfig = {
        moveSpeed = 200,
        runSpeed = 350,
        jumpPower = 400,
        airControl = 0.3,
        gravity = 980,
        maxFallSpeed = 600,
        groundFriction = 10,
        airFriction = 0.5,
        dashSpeed = 500,
        dashDuration = 0.2,
        dashCooldown = 1,
        attackDuration = 0.3,
        attackCooldown = 0.5,
        health = 100,
        maxHealth = 100,
    }
    self.config = config or defaultConfig

    -- State
    self.state = "idle" :: CharacterState
    self.previousState = "idle" :: CharacterState
    self.stateTime = 0

    -- Physics
    self.position = Vector2.new(0, 0)
    self.velocity = Vector2.new(0, 0)
    self.acceleration = Vector2.new(0, 0)
    self.facingDirection = "right" :: "left" | "right"
    self.isGrounded = self.config.gravity == 0 -- Always grounded in top-down mode
    self.jumpCount = 0
    self.maxJumps = 2

    -- Health
    self.health = self.config.health
    self.maxHealth = self.config.maxHealth
    self.isDead = false
    self.invulnerable = false
    self.invulnerabilityTime = 0

    -- Movement flags
    self.canMove = true
    self.canJump = true
    self.canAttack = true
    self.canDash = true

    -- Action system
    self.currentAction = nil :: CharacterAction?
    self.actionTime = 0
    self.actionCooldowns = {} :: {[string]: number}
    self.registeredActions = {} :: {[string]: CharacterAction}

    -- Input
    self.inputBuffer = {} :: {action: string, timestamp: number}
    self.inputBufferTime = 0.2 -- Buffer inputs for 200ms
    self.previousInput = {
        jump = false,
        attack = false,
        dash = false,
        interact = false,
    }

    -- Animation states
    self.animationOverride = nil :: string?

    -- Callbacks
    self.onStateChange = nil :: ((oldState: CharacterState, newState: CharacterState) -> ())?
    self.onActionStart = nil :: ((action: CharacterAction) -> ())?
    self.onActionEnd = nil :: ((action: CharacterAction) -> ())?
    self.onDamage = nil :: ((damage: number, source: string?) -> ())?
    self.onDeath = nil :: (() -> ())?
    self.onGroundHit = nil :: (() -> ())?
    self.onWallHit = nil :: ((normal: Vector2Type) -> ())?

    -- Register default actions
    self:registerDefaultActions()

    return self
end

function CharacterController:registerDefaultActions()
    -- Jump action
    self:registerAction({
        name = "jump",
        duration = 0,
        cooldown = 0,
        canMove = true,
        canJump = false,
        canCancel = false,
        animation = "jump",
        onStart = function(controller)
            controller.velocity = Vector2.new(
                controller.velocity.x,
                -controller.config.jumpPower
            )
            controller.jumpCount = controller.jumpCount + 1
            controller:setState("jumping")
        end,
    })

    -- Double jump action
    self:registerAction({
        name = "doubleJump",
        duration = 0,
        cooldown = 0,
        canMove = true,
        canJump = false,
        canCancel = false,
        animation = "doubleJump",
        onStart = function(controller)
            controller.velocity = Vector2.new(
                controller.velocity.x * 0.8,
                -controller.config.jumpPower * 0.9
            )
            controller.jumpCount = controller.jumpCount + 1
            controller:setState("jumping")
        end,
    })

    -- Dash action
    self:registerAction({
        name = "dash",
        duration = self.config.dashDuration,
        cooldown = self.config.dashCooldown,
        canMove = false,
        canJump = false,
        canCancel = false,
        animation = "dash",
        onStart = function(controller)
            local dashDir = if controller.facingDirection == "right" then 1 else -1
            controller.velocity = Vector2.new(
                controller.config.dashSpeed * dashDir,
                0
            )
            controller.invulnerable = true
            controller:setState("dashing")
        end,
        onEnd = function(controller)
            controller.invulnerable = false
            controller.velocity = Vector2.multiply(controller.velocity, 0.5)
        end,
    })

    -- Attack action
    self:registerAction({
        name = "attack",
        duration = self.config.attackDuration,
        cooldown = self.config.attackCooldown,
        canMove = false,
        canJump = true,
        canCancel = false,
        animation = "attack",
        onStart = function(controller)
            controller:setState("attacking")
            -- Attack hitbox would be spawned here
        end,
        onEnd = function(controller)
            if controller.isGrounded then
                controller:setState("idle")
            else
                controller:setState("falling")
            end
        end,
    })
end

function CharacterController:registerAction(action: CharacterAction)
    self.registeredActions[action.name] = action
end

function CharacterController:performAction(actionName: string): boolean
    local action = self.registeredActions[actionName]
    if not action then
        return false
    end

    -- Check if on cooldown
    local cooldown = self.actionCooldowns[actionName]
    if cooldown and cooldown > 0 then
        -- Add to input buffer for later
        self:bufferInput(actionName)
        return false
    end

    -- Check if current action can be cancelled
    if self.currentAction and not self.currentAction.canCancel then
        -- Add to input buffer for later
        self:bufferInput(actionName)
        return false
    end

    -- Special handling for jump actions
    if actionName == "jump" then
        if not self.canJump then
            return false
        end
        if not self.isGrounded and self.jumpCount >= self.maxJumps then
            return false
        end
        if self.jumpCount == 0 and self.isGrounded then
            -- First jump
            action = self.registeredActions.jump
        elseif self.jumpCount == 1 then
            -- Double jump
            action = self.registeredActions.doubleJump
        else
            return false
        end
    end

    -- Cancel current action if any
    if self.currentAction then
        self:endCurrentAction()
    end

    -- Start new action
    self.currentAction = action
    self.actionTime = 0
    self.actionCooldowns[actionName] = action.cooldown

    -- Update movement flags
    self.canMove = action.canMove
    self.canJump = action.canJump

    -- Set animation override
    if action.animation then
        self.animationOverride = action.animation
    end

    -- Call action start callback
    if action.onStart then
        action.onStart(self)
    end

    -- Call controller callback
    if self.onActionStart then
        self.onActionStart(action)
    end

    return true
end

function CharacterController:endCurrentAction()
    if not self.currentAction then
        return
    end

    local action = self.currentAction

    -- Call action end callback
    if action.onEnd then
        action.onEnd(self)
    end

    -- Call controller callback
    if self.onActionEnd then
        self.onActionEnd(action)
    end

    -- Reset flags
    self.canMove = true
    self.canJump = true
    self.animationOverride = nil
    self.currentAction = nil
end

function CharacterController:setState(newState: CharacterState)
    if self.state == newState then
        return
    end

    self.previousState = self.state
    self.state = newState
    self.stateTime = 0

    if self.onStateChange then
        self.onStateChange(self.previousState, newState)
    end
end

function CharacterController:update(deltaTime: number, input: InputState)
    -- Update state time
    self.stateTime = self.stateTime + deltaTime

    -- Update cooldowns
    for name, cooldown in pairs(self.actionCooldowns) do
        self.actionCooldowns[name] = math.max(0, cooldown - deltaTime)
    end

    -- Update current action
    if self.currentAction then
        self.actionTime = self.actionTime + deltaTime

        -- Call action update
        if self.currentAction.onUpdate then
            self.currentAction.onUpdate(self, deltaTime)
        end

        -- Check if action finished
        if self.actionTime >= self.currentAction.duration then
            self:endCurrentAction()
        end
    end

    -- Process buffered inputs
    self:processInputBuffer()

    -- Handle input
    self:handleInput(input, deltaTime)

    -- Update physics
    self:updatePhysics(deltaTime)

    -- Update state
    self:updateState()

    -- Update invulnerability
    if self.invulnerable and self.invulnerabilityTime > 0 then
        self.invulnerabilityTime = self.invulnerabilityTime - deltaTime
        if self.invulnerabilityTime <= 0 then
            self.invulnerable = false
        end
    end
end

function CharacterController:handleInput(input: InputState, deltaTime: number)
    if self.isDead then
        return
    end

    -- Movement
    if self.canMove then
        local moveX = 0
        local moveY = 0

        -- Determine game mode
        local isTopDown = self.config.gravity == 0

        -- Horizontal movement
        if input.moveLeft then
            moveX = moveX - 1
            self.facingDirection = "left"
        end
        if input.moveRight then
            moveX = moveX + 1
            self.facingDirection = "right"
        end

        -- Vertical movement (for top-down games)
        if input.moveUp then
            moveY = moveY - 1
        end
        if input.moveDown then
            moveY = moveY + 1
        end

        -- Normalize diagonal movement
        if moveX ~= 0 and moveY ~= 0 then
            local magnitude = math.sqrt(moveX * moveX + moveY * moveY)
            moveX = moveX / magnitude
            moveY = moveY / magnitude
        end

        -- Apply movement
        local isMoving = moveX ~= 0 or moveY ~= 0
        if isMoving then
            local moveSpeed = self.config.moveSpeed
            if self.state == "running" then
                moveSpeed = self.config.runSpeed
            end

            -- For platformers: only apply air control to X axis
            -- For top-down: always apply full control
            if isTopDown then
                -- Top-down movement: direct velocity control
                self.velocity = Vector2.new(
                    moveX * moveSpeed,
                    moveY * moveSpeed
                )
            else
                -- Platformer movement: acceleration-based horizontal movement
                local control = if self.isGrounded then 1 else self.config.airControl
                self.velocity = Vector2.new(
                    self.velocity.x + moveX * moveSpeed * control * deltaTime,
                    self.velocity.y
                )
            end

            if (isTopDown or self.isGrounded) and self.state ~= "attacking" then
                self:setState("walking")
            end
        else
            -- Not moving - stop velocity in top-down mode
            if isTopDown then
                self.velocity = Vector2.zero()
            end

            -- Set state to idle if velocity is low
            if (isTopDown or self.isGrounded) and math.abs(self.velocity.x) < 10 and math.abs(self.velocity.y) < 10 then
                if self.state ~= "attacking" then
                    self:setState("idle")
                end
            end
        end
    end

    -- Jump (only for platformers) - trigger only on press, not hold
    if input.jump and not self.previousInput.jump and self.canJump and self.config.gravity > 0 then
        self:performAction("jump")
    end

    -- Attack - trigger only on press, not hold
    if input.attack and not self.previousInput.attack and self.canAttack then
        self:performAction("attack")
    end

    -- Dash - trigger only on press, not hold
    if input.dash and not self.previousInput.dash and self.canDash then
        self:performAction("dash")
    end

    -- Interact - trigger only on press, not hold
    if input.interact and not self.previousInput.interact then
        -- Interact action would go here
    end

    -- Store current input for next frame
    self.previousInput.jump = input.jump
    self.previousInput.attack = input.attack
    self.previousInput.dash = input.dash
    self.previousInput.interact = input.interact
end

function CharacterController:updatePhysics(deltaTime: number)
    -- Apply gravity
    if not self.isGrounded then
        self.velocity = Vector2.new(
            self.velocity.x,
            math.min(self.velocity.y + self.config.gravity * deltaTime, self.config.maxFallSpeed)
        )
    end

    -- Apply friction
    local friction = if self.isGrounded then self.config.groundFriction else self.config.airFriction
    self.velocity = Vector2.new(
        self.velocity.x * (1 - friction * deltaTime),
        self.velocity.y
    )

    -- Update position
    self.position = Vector2.add(self.position, Vector2.multiply(self.velocity, deltaTime))
end

function CharacterController:updateState()
    if self.isDead then
        return
    end

    -- Don't update state during actions
    if self.currentAction then
        return
    end

    if self.isGrounded then
        if math.abs(self.velocity.x) > 10 then
            if math.abs(self.velocity.x) > self.config.moveSpeed * 1.5 then
                self:setState("running")
            else
                self:setState("walking")
            end
        else
            self:setState("idle")
        end
    else
        if self.velocity.y < -10 then
            self:setState("jumping")
        elseif self.velocity.y > 10 then
            self:setState("falling")
        end
    end
end

function CharacterController:setGrounded(grounded: boolean)
    local wasGrounded = self.isGrounded
    self.isGrounded = grounded

    if grounded and not wasGrounded then
        -- Just landed
        self.jumpCount = 0
        self.velocity = Vector2.new(self.velocity.x, 0)

        if self.onGroundHit then
            self.onGroundHit()
        end
    end
end

function CharacterController:takeDamage(damage: number, source: string?, knockback: Vector2Type?)
    if self.invulnerable or self.isDead then
        return
    end

    self.health = math.max(0, self.health - damage)

    -- Apply knockback
    if knockback then
        self.velocity = Vector2.add(self.velocity, knockback)
    end

    -- Trigger invulnerability frames
    self.invulnerable = true
    self.invulnerabilityTime = 1 -- 1 second of invulnerability

    -- Trigger damage callback
    if self.onDamage then
        self.onDamage(damage, source)
    end

    -- Check for death
    if self.health <= 0 then
        self:die()
    else
        self:setState("hurt")
    end
end

function CharacterController:heal(amount: number)
    if self.isDead then
        return
    end

    self.health = math.min(self.maxHealth, self.health + amount)
end

function CharacterController:die()
    if self.isDead then
        return
    end

    self.isDead = true
    self.health = 0
    self:setState("dead")
    self.canMove = false
    self.canJump = false
    self.canAttack = false

    if self.onDeath then
        self.onDeath()
    end
end

function CharacterController:respawn(position: Vector2Type)
    self.isDead = false
    self.health = self.maxHealth
    self.position = position
    self.velocity = Vector2.zero()
    self.canMove = true
    self.canJump = true
    self.canAttack = true
    self:setState("idle")
end

function CharacterController:bufferInput(action: string)
    local currentTime = tick()

    -- Check if this action was just buffered recently (within 50ms)
    -- This prevents spam from held inputs
    for _, bufferedInput in ipairs(self.inputBuffer) do
        if bufferedInput.action == action and (currentTime - bufferedInput.timestamp) < 0.05 then
            -- Already buffered recently, don't add duplicate
            return
        end
    end

    -- Add input to buffer with timestamp
    table.insert(self.inputBuffer, {
        action = action,
        timestamp = currentTime,
    })

    -- Clean old inputs
    for i = #self.inputBuffer, 1, -1 do
        if currentTime - self.inputBuffer[i].timestamp > self.inputBufferTime then
            table.remove(self.inputBuffer, i)
        end
    end
end

function CharacterController:processInputBuffer()
    if #self.inputBuffer == 0 then
        return
    end

    -- Try to execute buffered inputs
    for i, input in ipairs(self.inputBuffer) do
        if self:performAction(input.action) then
            -- Action performed, remove from buffer
            table.remove(self.inputBuffer, i)
            break
        end
    end
end

function CharacterController:getAnimationState(): string
    -- Return animation override or current state
    return self.animationOverride or self.state
end

return CharacterController