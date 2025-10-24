--!strict
local RunService = game:GetService("RunService")

local Snake = require(game.ReplicatedStorage.Shared.Enemies.Snake)
local Vector2 = require(game.ReplicatedStorage.Shared.Utils.Vector2)

local SnakeAI = {}
SnakeAI.__index = SnakeAI

type EntityManager = any
type Entity = any
type Vector2Type = {x: number, y: number}

function SnakeAI.new(entityManager: EntityManager)
    local self = setmetatable({}, SnakeAI)
    self.entityManager = entityManager
    self.detectionDistance = Snake.CONFIG.aggroRange
    self.attackRange = Snake.CONFIG.attackRange
    self.attackCooldown = Snake.CONFIG.attackCooldown
    -- Separation behavior config
    self.separationRadius = 150  -- Distance at which enemies start avoiding each other
    self.separationStrength = 0.6  -- How strongly they push apart (0-1)
    return self
end

function SnakeAI:update(entity: Entity, deltaTime: number)
    local ai = entity.components.AI
    local transform = entity.components.Transform
    local physics = entity.components.Physics
    local enemy = entity.components.Enemy

    if not ai or not transform or not physics or not enemy then
        return
    end

    if ai.attackCooldown > 0 then
        ai.attackCooldown = ai.attackCooldown - deltaTime
    end

    local nearestPlayer = self:findNearestPlayer(transform.position)

    -- Debug: Print AI state once per second
    if not self.lastDebugTime then self.lastDebugTime = {} end
    if not self.lastDebugTime[entity.id] or (tick() - self.lastDebugTime[entity.id]) > 1 then
        self.lastDebugTime[entity.id] = tick()
        local distance = nearestPlayer and self:getDistance(transform.position, nearestPlayer.position) or 999
        print("SnakeAI:", entity.id:sub(1,8), "State:", ai.state, "Dist:", math.floor(distance),
              "Cooldown:", string.format("%.1f", ai.attackCooldown),
              "Pos:", math.floor(transform.position.x), math.floor(transform.position.y),
              "Vel:", math.floor(physics.velocity.x), math.floor(physics.velocity.y))
    end

    if nearestPlayer then
        local distance = self:getDistance(transform.position, nearestPlayer.position)

        -- Attack animation duration: 7 frames at 15fps = ~0.47 seconds
        local attackAnimDuration = 0.8
        local timeSinceAttack = tick() - (ai.lastAttackTime or 0)

        if distance <= self.attackRange and ai.attackCooldown <= 0 then
            -- Set state to ATTACK - the GameServer AI System will handle creating the attack
            ai.state = Snake.AIStates.ATTACK
            ai.target = nearestPlayer.id
            ai.wantsToAttack = true  -- Flag for GameServer to create attack hitbox
            -- Don't move while attacking
            physics.velocity = Vector2.zero()

            -- Set cooldown immediately to prevent multiple attacks
            ai.attackCooldown = self.attackCooldown
            ai.lastAttackTime = tick()

            -- Lock facing direction at start of attack (don't change during animation)
            if not ai.attackFacingLocked then
                local directionToPlayer = nearestPlayer.position.x - transform.position.x
                if directionToPlayer > 0 then
                    enemy.facingDirection = "right"
                elseif directionToPlayer < 0 then
                    enemy.facingDirection = "left"
                end
                ai.attackFacingLocked = true
            end
        elseif distance <= self.attackRange and timeSinceAttack < attackAnimDuration then
            -- Stay in ATTACK state long enough for animation to play
            ai.state = Snake.AIStates.ATTACK
            ai.target = nearestPlayer.id
            physics.velocity = Vector2.zero()
        elseif distance <= self.attackRange then
            -- Within attack range but on cooldown - STOP and wait
            ai.state = Snake.AIStates.COOLDOWN
            ai.target = nearestPlayer.id
            physics.velocity = Vector2.zero()

            -- Keep facing direction locked during cooldown (don't change animation mid-loop)
            -- Facing direction will be unlocked when leaving attack/cooldown state
        elseif distance <= self.detectionDistance then
            -- In detection range but not in attack range - chase
            ai.state = Snake.AIStates.CHASE
            ai.target = nearestPlayer.id
            ai.attackFacingLocked = false  -- Unlock facing direction
            self:chaseTarget(entity, nearestPlayer, deltaTime)

            -- Update facing direction based on velocity when moving
            if physics.velocity.x > 0 then
                enemy.facingDirection = "right"
            elseif physics.velocity.x < 0 then
                enemy.facingDirection = "left"
            end
        else
            ai.state = Snake.AIStates.PATROL
            ai.target = nil
            ai.attackFacingLocked = false  -- Unlock facing direction
            self:patrol(entity, deltaTime)

            -- Update facing direction based on velocity when patrolling
            if physics.velocity.x > 0 then
                enemy.facingDirection = "right"
            elseif physics.velocity.x < 0 then
                enemy.facingDirection = "left"
            end
        end
    else
        ai.state = Snake.AIStates.PATROL
        ai.target = nil
        ai.attackFacingLocked = false  -- Unlock facing direction
        self:patrol(entity, deltaTime)

        -- Update facing direction based on velocity when patrolling
        if physics.velocity.x > 0 then
            enemy.facingDirection = "right"
        elseif physics.velocity.x < 0 then
            enemy.facingDirection = "left"
        end
    end

    self:updateAnimation(entity)
end

function SnakeAI:patrol(entity: Entity, deltaTime: number)
    local ai = entity.components.AI
    local transform = entity.components.Transform
    local physics = entity.components.Physics
    local enemy = entity.components.Enemy

    if not ai.patrolPoints or #ai.patrolPoints == 0 then
        physics.velocity = Vector2.zero()
        return
    end

    local targetPoint = ai.patrolPoints[ai.currentPatrolIndex]
    if not targetPoint then
        ai.currentPatrolIndex = 1
        targetPoint = ai.patrolPoints[1]
    end

    local direction = Vector2.subtract(targetPoint, transform.position)
    local distance = Vector2.length(direction)

    if distance < 10 then
        ai.currentPatrolIndex = (ai.currentPatrolIndex % #ai.patrolPoints) + 1
    else
        direction = Vector2.normalize(direction)
        local baseVelocity = Vector2.multiply(direction, enemy.moveSpeed * 0.5)

        -- Apply separation steering to avoid grouping with other enemies
        local separationForce = self:calculateSeparation(entity)
        local separationVelocity = Vector2.multiply(separationForce, enemy.moveSpeed * self.separationStrength)

        physics.velocity = Vector2.add(baseVelocity, separationVelocity)
    end
end

function SnakeAI:chaseTarget(entity: Entity, targetPlayer: any, deltaTime: number)
    local transform = entity.components.Transform
    local physics = entity.components.Physics
    local enemy = entity.components.Enemy

    if not targetPlayer then
        physics.velocity = Vector2.zero()
        return
    end

    local direction = Vector2.subtract(targetPlayer.position, transform.position)
    direction = Vector2.normalize(direction)

    local baseVelocity = Vector2.multiply(direction, enemy.moveSpeed)

    -- Apply separation steering to avoid grouping with other enemies
    local separationForce = self:calculateSeparation(entity)
    local separationVelocity = Vector2.multiply(separationForce, enemy.moveSpeed * self.separationStrength)

    physics.velocity = Vector2.add(baseVelocity, separationVelocity)
end

function SnakeAI:performAttack(entity: Entity, targetPlayer: any)
    local transform = entity.components.Transform
    local enemy = entity.components.Enemy

    -- Cooldown is now set in update() when entering ATTACK state
    -- This just creates the attack hitbox data

    local attackDirection = Vector2.subtract(targetPlayer.position, transform.position)
    attackDirection = Vector2.normalize(attackDirection)

    local attackOffset = Vector2.multiply(attackDirection, 30)
    local attackPosition = Vector2.add(transform.position, attackOffset)

    return {
        position = attackPosition,
        size = {x = 40, y = 40},
        damage = enemy.damage,
        knockback = Vector2.multiply(attackDirection, 150),
        lifetime = 0.2,
        owner = entity.id
    }
end

function SnakeAI:calculateSeparation(entity: Entity): Vector2Type
    local transform = entity.components.Transform
    local separationForce = Vector2.zero()
    local neighborCount = 0

    -- Find all other enemies
    local enemies = self.entityManager:queryComponents("Enemy")

    for entityId, _ in pairs(enemies) do
        -- Skip self
        if entityId ~= entity.id then
            local otherEntity = self.entityManager:getEntity(entityId)
            if otherEntity and otherEntity.active then
                local otherTransform = otherEntity.components.Transform
                if otherTransform then
                    local distance = self:getDistance(transform.position, otherTransform.position)

                    -- If within separation radius, add force pushing away
                    if distance > 0 and distance < self.separationRadius then
                        local awayDirection = Vector2.subtract(transform.position, otherTransform.position)
                        awayDirection = Vector2.normalize(awayDirection)
                        -- Stronger force the closer they are (quadratic falloff for more aggressive separation)
                        local distanceRatio = 1 - (distance / self.separationRadius)
                        local forceMagnitude = distanceRatio * distanceRatio  -- Square it for stronger close-range repulsion
                        separationForce = Vector2.add(separationForce, Vector2.multiply(awayDirection, forceMagnitude))
                        neighborCount = neighborCount + 1
                    end
                end
            end
        end
    end

    -- Average the separation force if there are neighbors
    if neighborCount > 0 then
        separationForce = Vector2.divide(separationForce, neighborCount)
    end

    return separationForce
end

function SnakeAI:findNearestPlayer(position: Vector2Type): any?
    local nearestPlayer = nil
    local nearestDistance = math.huge

    local players = self.entityManager:queryComponents("Character")

    -- Debug: Log player search
    if not self.lastPlayerSearchDebug or (tick() - self.lastPlayerSearchDebug) > 3 then
        self.lastPlayerSearchDebug = tick()
        local playerCount = 0
        for _ in pairs(players) do
            playerCount = playerCount + 1
        end
        print("SnakeAI: Searching for players from pos", math.floor(position.x), math.floor(position.y), "- Found", playerCount, "characters, detection range:", self.detectionDistance)
    end

    for entityId, character in pairs(players) do
        local entity = self.entityManager:getEntity(entityId)
        if entity and entity.active and character.health > 0 then
            local transform = entity.components.Transform
            if transform then
                local distance = self:getDistance(position, transform.position)

                -- Debug: Log distance check occasionally
                if not self.lastDistanceDebug or (tick() - self.lastDistanceDebug) > 3 then
                    self.lastDistanceDebug = tick()
                    print("  Player", entityId:sub(1, 8), "at", math.floor(transform.position.x), math.floor(transform.position.y), "distance:", math.floor(distance), "in range?:", distance <= self.detectionDistance)
                end

                if distance < nearestDistance and distance <= self.detectionDistance then
                    nearestDistance = distance
                    nearestPlayer = {
                        id = entityId,
                        position = transform.position,
                        character = character
                    }
                end
            end
        end
    end

    return nearestPlayer
end

function SnakeAI:getDistance(pos1: Vector2Type, pos2: Vector2Type): number
    return Vector2.length(Vector2.subtract(pos2, pos1))
end

function SnakeAI:updateAnimation(entity: Entity)
    local ai = entity.components.AI
    local enemy = entity.components.Enemy
    local animation = entity.components.Animation
    local physics = entity.components.Physics

    if not animation then
        return
    end

    local newAnimation = "idle"

    if ai.state == Snake.AIStates.ATTACK then
        -- Show attack animation only during active attack
        newAnimation = enemy.facingDirection == "right" and "attack_right" or "attack_left"
    elseif ai.state == Snake.AIStates.COOLDOWN then
        -- Show idle during cooldown so it's clear snake is waiting before next attack
        newAnimation = "idle"
    elseif ai.state == Snake.AIStates.CHASE or ai.state == Snake.AIStates.PATROL then
        local speed = Vector2.length(physics.velocity)
        if speed > 10 then
            newAnimation = enemy.facingDirection == "right" and "move_right" or "move_left"
        end
    end

    if animation.currentAnimation ~= newAnimation then
        animation.currentAnimation = newAnimation
    end
end

return SnakeAI