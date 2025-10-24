--!strict

local Snake = {}

Snake.CONFIG = {
    health = 75,
    maxHealth = 75,
    damage = 15,
    moveSpeed = 80,

    aggroRange = 500,  -- Increased from 250 so snakes detect players from further away
    attackRange = 60,  -- Sweet spot for attack distance - not too close, not too far
    attackCooldown = 3.0,  -- 3 seconds cooldown to give animation time to complete

    mass = 1.2,
    friction = 0.15,

    size = {x = 48, y = 48},

    spriteSheet = "rbxassetid://92332550828541",
    frameSize = {x = 64, y = 64},
    columns = 7,  -- 7 frames per row in the sprite sheet (7 columns)
    animations = {
        idle = {
            frames = {1, 2, 3, 4},
            frameRate = 10,
            loop = true
        },
        move_left = {
            frames = {1, 2, 3, 4},
            frameRate = 10,
            loop = true
        },
        move_right = {
            frames = {1, 2, 3, 4}, -- Same frames, will be flipped
            frameRate = 10,
            loop = true,
            flipX = true
        },
        attack_left = {
            frames = {5, 6, 7, 8, 9, 10, 11},
            frameRate = 10,
            loop = true
        },
        attack_right = {
            frames = {5, 6, 7, 8, 9, 10, 11},
            frameRate = 10,
            loop = true,
            flipX = true
        }
    }
}

Snake.AIStates = {
    IDLE = "idle",
    PATROL = "patrol",
    CHASE = "chase",
    ATTACK = "attack",
    COOLDOWN = "cooldown"
}

function Snake.getAnimationData(animationName: string)
    local animData = Snake.CONFIG.animations[animationName]
    if not animData then
        return nil
    end

    return {
        name = animationName,
        spriteSheet = Snake.CONFIG.spriteSheet,
        frameSize = Snake.CONFIG.frameSize,
        frames = animData.frames,
        frameRate = animData.frameRate,
        loop = animData.loop,
        flipX = animData.flipX
    }
end

function Snake.createComponents(position: {x: number, y: number})
    return {
        Transform = {
            position = position,
            rotation = 0,
            scale = {x = 1, y = 1},
            zIndex = 8,  -- Enemies render below players (20) but above obstacles (5)
        },

        Enemy = {
            type = "snake",
            health = Snake.CONFIG.health,
            maxHealth = Snake.CONFIG.maxHealth,
            damage = Snake.CONFIG.damage,
            moveSpeed = Snake.CONFIG.moveSpeed,
            aggroRange = Snake.CONFIG.aggroRange,
        },

        Physics = {
            velocity = {x = 0, y = 0},
            acceleration = {x = 0, y = 0},
            mass = Snake.CONFIG.mass,
            friction = Snake.CONFIG.friction,
            restitution = 0,
            isStatic = false,
        },

        Hitbox = {
            size = Snake.CONFIG.size,
            offset = {x = 0, y = 0},
            isTrigger = false,
            layer = 2, -- Enemy layer
            mask = bit32.bor(bit32.lshift(1, 1), bit32.lshift(1, 2), bit32.lshift(1, 3), bit32.lshift(1, 6)), -- Collides with player, other enemies, player attacks, and walls
            debugDraw = false,
        },

        AI = {
            behavior = Snake.AIStates.PATROL,
            target = nil,
            patrolPoints = {
                position,
                {x = position.x + 200, y = position.y},
                {x = position.x + 200, y = position.y + 100},
                {x = position.x, y = position.y + 100}
            },
            currentPatrolIndex = 1,
            state = Snake.AIStates.IDLE,
            attackCooldown = 0,
            lastAttackTime = 0,
        },

        Sprite = {
            imageId = Snake.CONFIG.spriteSheet,
            size = Snake.CONFIG.frameSize,
            offset = {x = 0, y = 0},
            color = {r = 255, g = 255, b = 255},
            transparency = 0,
            flipX = false,
            flipY = false,
        },

        Animation = {
            currentAnimation = "idle",
            spriteSheet = Snake.CONFIG.spriteSheet,
            frameSize = Snake.CONFIG.frameSize,
            animations = Snake.CONFIG.animations,
        }
    }
end

return Snake