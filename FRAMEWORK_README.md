# Pixel Sahur 2D Game Framework

A comprehensive 2D multiplayer game framework for Roblox, built entirely with UI elements.

## Features

### Core Systems

#### 1. **Networking System** (`src/shared/Network/`)
- Buffer-based packet replication using ByteNet
- Client-side prediction with server reconciliation
- Entity interpolation for smooth movement
- Optimized batch updates
- Input buffering and sequencing

#### 2. **Entity Component System (ECS)** (`src/shared/ECS/`)
- Flexible entity management
- Component-based architecture
- System prioritization and caching
- Archetype support for entity templates
- Performance monitoring and debugging

#### 3. **2D Physics & Hitbox System** (`src/shared/Physics/`)
- AABB collision detection
- Spatial partitioning for optimization
- Layer-based collision filtering
- Trigger and solid collisions
- Debug visualization

#### 4. **Animation System** (`src/shared/Animation/`)
- Sprite sheet based animations
- Frame-by-frame control
- Animation blending and priorities
- Support for multiple animation states
- Automatic sprite sheet UV mapping

#### 5. **Character Controller** (`src/shared/Character/`)
- State machine for character actions
- Input buffering for combos
- Action system (jump, dash, attack, etc.)
- Health and damage management
- Physics-based movement

#### 6. **World Renderer** (`src/client/Rendering/`)
- Responsive UI-based rendering
- Multi-layer parallax support
- Viewport culling for performance
- Pixel-perfect rendering option
- Debug visualization tools

#### 7. **Camera System** (`src/client/Rendering/Camera2D.luau`)
- Smooth following with dead zones
- Screen shake effects
- Zoom controls with limits
- Camera bounds and constraints
- World-to-screen coordinate conversion

#### 8. **Input Manager** (`src/client/Input/`)
- Multi-device support (Keyboard, Gamepad, Touch)
- Virtual joystick for mobile
- Input buffering
- Customizable key bindings
- Haptic feedback support

## Architecture

### Client-Server Model

```
Client                          Server
------                          ------
InputManager ──> NetworkClient ──> NetworkServer ──> GameServer
     │                │                                   │
     v                v                                   v
CharacterController   │                           EntityManager
     │                │                                   │
     v                v                                   v
WorldRenderer <── Entity Updates <──── Physics & Game Logic
     │
     v
Camera2D
```

### Entity Component System

Entities are composed of components, and systems process entities with specific component combinations:

```lua
-- Example: Creating a player entity
local entity = entityManager:createEntity()
entityManager:addComponent(entity.id, "Transform", {position = Vector2.new(0, 0)})
entityManager:addComponent(entity.id, "Character", {health = 100})
entityManager:addComponent(entity.id, "Hitbox", {size = Vector2.new(48, 60)})
```

## Usage

### Creating a New Character Type

```lua
-- In your character configuration
local myCharacter = {
    moveSpeed = 250,
    jumpPower = 450,
    health = 120,
    animations = {
        idle = "rbxassetid://YOUR_IDLE_SPRITE",
        walk = "rbxassetid://YOUR_WALK_SPRITE",
        attack = "rbxassetid://YOUR_ATTACK_SPRITE",
    }
}
```

### Adding Custom Systems

```lua
local CustomSystem = {
    name = "CustomSystem",
    priority = 5,
    requiredComponents = {"Transform", "CustomComponent"},
    enabled = true,
    update = function(system, entityManager, entities, deltaTime)
        for _, entity in ipairs(entities) do
            -- Your system logic here
        end
    end
}

entityManager:registerSystem(CustomSystem)
```

### Creating Sprite Animations

```lua
local animConfig = {
    spriteSheet = "rbxassetid://YOUR_SPRITE_SHEET",
    frameWidth = 64,
    frameHeight = 64,
    animations = {
        idle = {row = 1, startCol = 1, frameCount = 4, duration = 0.2},
        walk = {row = 2, startCol = 1, frameCount = 8, duration = 0.1},
        jump = {row = 3, startCol = 1, frameCount = 3, duration = 0.15},
    }
}

local animations = AnimationController.createAnimationsFromSheet(animConfig)
```

### Network Packet Definition

```lua
-- Define custom packet in PacketDefinitions.luau
CustomPacket = ByteNet.definePacket({
    playerId = ByteNet.string,
    action = ByteNet.string,
    data = ByteNet.optional(ByteNet.string),
})

-- Send from client
Packets.CustomPacket:send({
    playerId = localPlayer.UserId,
    action = "custom_action",
    data = "some_data"
})

-- Listen on server
Packets.CustomPacket:listen(function(data, player)
    -- Handle packet
end)
```

## Configuration

### World Settings

Edit in `GameServer.luau`:
```lua
self.worldBounds = {
    x = -2000,
    y = -2000,
    width = 4000,
    height = 4000,
}
```

### Rendering Settings

Edit in `GameClient.luau`:
```lua
self.worldRenderer = WorldRenderer.new(self.screenGui, {
    pixelScale = 4,           -- Pixel size multiplier
    targetResolution = Vector2.new(1920, 1080),
    maintainAspectRatio = true,
    pixelPerfect = true,      -- Crisp pixel art
    backgroundColor = Color3.new(0.1, 0.1, 0.2),
})
```

### Input Configuration

Edit in `InputManager.luau`:
```lua
local defaultConfig = {
    deadZone = 0.2,          -- Gamepad stick dead zone
    sensitivity = 1,         -- Look sensitivity
    invertY = false,
    vibration = true,        -- Haptic feedback
    touchControlsEnabled = true,
}
```

## Performance Considerations

1. **Entity Culling**: Only renders entities within camera view
2. **Spatial Partitioning**: Hitbox system uses grid-based partitioning
3. **Batch Updates**: Network updates are batched for efficiency
4. **System Caching**: ECS caches entities for each system
5. **Pixel Perfect**: Optional pixel-perfect rendering for retro aesthetics

## Debugging

Press `F3` in-game to toggle debug mode, which shows:
- FPS counter
- Entity count (visible/total)
- Hitbox visualization
- System performance metrics

## Adding Assets

1. Upload sprite sheets to Roblox
2. Note the asset IDs (rbxassetid://...)
3. Configure in animation/sprite components
4. Ensure sprite sheets follow grid layout

## Multiplayer Synchronization

The framework handles:
- Position interpolation
- State synchronization
- Input prediction
- Server reconciliation
- Lag compensation

## Next Steps

1. Add more character types and enemies
2. Implement item/powerup system
3. Create level editor
4. Add particle effects system
5. Implement sound manager
6. Create UI menus and HUD
7. Add save/load system
8. Implement matchmaking
9. Create leaderboards
10. Add achievements system

## File Structure

```
pixel-sahur/
├── src/
│   ├── client/
│   │   ├── GameClient.luau         # Main client orchestrator
│   │   ├── Input/
│   │   │   └── InputManager.luau   # Input handling
│   │   ├── Network/
│   │   │   └── NetworkClient.luau  # Client networking
│   │   └── Rendering/
│   │       ├── Camera2D.luau       # Camera system
│   │       └── WorldRenderer.luau  # UI rendering
│   ├── server/
│   │   ├── GameServer.luau         # Main server orchestrator
│   │   └── Network/
│   │       └── NetworkServer.luau  # Server networking
│   └── shared/
│       ├── Animation/
│       │   └── AnimationController.luau
│       ├── Character/
│       │   └── CharacterController.luau
│       ├── ECS/
│       │   └── EntityManager.luau
│       ├── Network/
│       │   └── PacketDefinitions.luau
│       ├── Physics/
│       │   └── HitboxSystem.luau
│       ├── Utils/
│       │   ├── Rectangle.luau
│       │   └── Vector2.luau
│       └── Types.luau              # Type definitions
└── wally.toml                       # Dependencies
```

## Dependencies

- **React**: UI framework (optional, for future UI components)
- **ReactRoblox**: React bindings for Roblox
- **ByteNet**: Efficient networking library

## License

This framework is part of the Pixel Sahur project.