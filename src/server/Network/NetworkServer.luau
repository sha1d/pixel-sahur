--!strict
-- Server-side networking module

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

-- Use SimplePackets instead of ByteNet for compatibility
local Packets = require(game.ReplicatedStorage.Shared.Network.SimplePackets)
local Types = require(game.ReplicatedStorage.Shared.Types)

type Vector2 = Types.Vector2
type InputState = Types.InputState
type EntityUpdate = Types.EntityUpdate
type Entity = Types.Entity

local NetworkServer = {}
NetworkServer.__index = NetworkServer

function NetworkServer.new()
    local self = setmetatable({}, NetworkServer)

    -- Player management
    self.players = {} :: {[Player]: {
        playerId: string,
        entityId: string?,
        lastInput: InputState?,
        lastSequence: number,
        lastActivity: number,
        position: Vector2,
        velocity: Vector2,
    }}

    -- Entity management
    self.entities = {} :: {[string]: Entity}
    self.dirtyEntities = {} :: {[string]: boolean}

    -- Network settings
    self.tickRate = 20 -- 20Hz server tick rate
    self.sendRate = 10 -- 10Hz update rate to clients
    self.maxPlayerTimeout = 30 -- Disconnect after 30 seconds of inactivity

    -- State
    self.running = false
    self.sequence = 0
    self.lastSendTime = 0

    -- Callbacks
    self.onPlayerJoined = nil :: ((player: Player) -> ())?
    self.onPlayerLeft = nil :: ((player: Player) -> ())?
    self.onPlayerInput = nil :: ((player: Player, input: InputState, deltaTime: number) -> ())?
    self.onPlayerAction = nil :: ((player: Player, action: string, data: any) -> ())?

    return self
end

function NetworkServer:start()
    if self.running then
        return
    end

    self.running = true

    -- Set up player connections
    self:setupPlayerConnections()

    -- Set up packet handlers
    self:setupPacketHandlers()

    -- Start update loops
    self:startUpdateLoop()
    self:startSendLoop()

    print("NetworkServer started")
end

function NetworkServer:stop()
    self.running = false

    if self.updateLoop then
        self.updateLoop:Disconnect()
        self.updateLoop = nil
    end

    if self.sendLoop then
        self.sendLoop:Disconnect()
        self.sendLoop = nil
    end

    -- Disconnect all players
    for player, _ in pairs(self.players) do
        self:removePlayer(player)
    end

    print("NetworkServer stopped")
end

function NetworkServer:setupPlayerConnections()
    -- Handle new players
    Players.PlayerAdded:Connect(function(player)
        self:addPlayer(player)
    end)

    -- Handle players leaving
    Players.PlayerRemoving:Connect(function(player)
        self:removePlayer(player)
    end)

    -- Add any players already in the game
    for _, player in ipairs(Players:GetPlayers()) do
        self:addPlayer(player)
    end
end

function NetworkServer:addPlayer(player: Player)
    local playerId = tostring(player.UserId)

    self.players[player] = {
        playerId = playerId,
        entityId = nil,
        lastInput = nil,
        lastSequence = 0,
        lastActivity = tick(),
        position = {x = 0, y = 0},
        velocity = {x = 0, y = 0},
    }

    print("Player added:", player.Name, playerId)

    if self.onPlayerJoined then
        self.onPlayerJoined(player)
    end
end

function NetworkServer:removePlayer(player: Player)
    local playerData = self.players[player]
    if not playerData then
        return
    end

    -- Despawn player entity
    if playerData.entityId then
        self:despawnEntity(playerData.entityId)

        -- Notify all other players
        Packets.PlayerLeft.sendToAll({
            playerId = playerData.playerId,
            entityId = playerData.entityId,
        })
    end

    self.players[player] = nil

    print("Player removed:", player.Name, playerData.playerId)

    if self.onPlayerLeft then
        self.onPlayerLeft(player)
    end
end

function NetworkServer:setupPacketHandlers()
    -- Player input
    Packets.PlayerInput.onServerEvent = function(data, player)
        local playerData = self.players[player]
        if not playerData then
            return
        end

        playerData.lastInput = data.input
        playerData.lastSequence = data.sequence
        playerData.lastActivity = tick()

        if self.onPlayerInput then
            self.onPlayerInput(player, data.input, data.deltaTime)
        end
    end

    -- Player action
    Packets.PlayerAction.onServerEvent = function(data, player)
        local playerData = self.players[player]
        if not playerData then
            return
        end

        playerData.lastActivity = tick()

        if self.onPlayerAction then
            self.onPlayerAction(player, data.action, data)
        end
    end

    -- Request spawn
    Packets.RequestSpawn.onServerEvent = function(data, player)
        self:spawnPlayerEntity(player, data.characterType, data.position)
    end

    -- Chat messages
    Packets.Chat.onServerEvent = function(data, player)
        local playerData = self.players[player]
        if not playerData then
            return
        end

        -- Broadcast chat to all players
        Packets.Chat.sendToAll({
            playerId = playerData.playerId,
            message = data.message,
            timestamp = tick(),
        })
    end

    -- Ping
    Packets.Ping.onServerEvent = function(data, player)
        -- Echo back with server time
        Packets.Ping.sendTo(player, {
            clientTime = data.clientTime,
            serverTime = tick(),
        })
    end
end

function NetworkServer:spawnPlayerEntity(player: Player, characterType: string, position: Vector2)
    local playerData = self.players[player]
    if not playerData then
        return
    end

    -- Generate entity ID
    local entityId = "player_" .. playerData.playerId

    -- If player already has an entity, despawn it first
    if playerData.entityId then
        self:despawnEntity(playerData.entityId)
    end

    -- Create entity
    local entity: Entity = {
        id = entityId,
        components = {},
        active = true,
    }

    -- Add to entities
    self.entities[entityId] = entity
    playerData.entityId = entityId
    playerData.position = position

    -- Send spawn packet to all players
    local spawnData = {
        entityId = entityId,
        entityType = "player",
        position = position,
        velocity = {x = 0, y = 0},
        playerId = playerData.playerId,
        data = characterType,
    }

    Packets.EntitySpawn.sendToAll(spawnData)

    -- Send player joined notification
    Packets.PlayerJoined.sendToAll({
        playerId = playerData.playerId,
        entityId = entityId,
        position = position,
        characterData = characterType,
    })

    -- Send current world state to the new player
    self:sendWorldState(player)

    print("Spawned player entity:", player.Name, entityId)
end

function NetworkServer:spawnEntity(entityType: string, position: Vector2, data: any?): string
    local entityId = HttpService:GenerateGUID(false)

    local entity: Entity = {
        id = entityId,
        components = {},
        active = true,
    }

    self.entities[entityId] = entity

    -- Send spawn packet to all players
    Packets.EntitySpawn.sendToAll({
        entityId = entityId,
        entityType = entityType,
        position = position,
        velocity = {x = 0, y = 0},
        playerId = nil,
        data = if data then HttpService:JSONEncode(data) else nil,
    })

    return entityId
end

function NetworkServer:despawnEntity(entityId: string, reason: string?)
    local entity = self.entities[entityId]
    if not entity then
        return
    end

    self.entities[entityId] = nil
    self.dirtyEntities[entityId] = nil

    -- Send despawn packet to all players
    Packets.EntityDespawn.sendToAll({
        entityId = entityId,
        reason = reason,
    })
end

function NetworkServer:updateEntity(entityId: string, update: EntityUpdate)
    local entity = self.entities[entityId]
    if not entity then
        return
    end

    -- Mark entity as dirty for next update
    self.dirtyEntities[entityId] = true

    -- Update server state (this would be expanded with actual component updates)
    -- For now, we'll just track it for replication
end

function NetworkServer:sendWorldState(player: Player)
    local worldEntities = {}

    for entityId, entity in pairs(self.entities) do
        local playerData = nil

        -- Find if this entity belongs to a player
        for _, pData in pairs(self.players) do
            if pData.entityId == entityId then
                playerData = pData
                break
            end
        end

        table.insert(worldEntities, {
            entityId = entityId,
            entityType = if playerData then "player" else "entity",
            position = if playerData then playerData.position else {x = 0, y = 0},
            velocity = if playerData then playerData.velocity else {x = 0, y = 0},
            state = "idle",
            playerId = if playerData then playerData.playerId else nil,
        })
    end

    self.sequence = self.sequence + 1

    Packets.WorldState.sendTo(player, {
        entities = worldEntities,
        sequence = self.sequence,
        timestamp = tick(),
    })
end

function NetworkServer:startUpdateLoop()
    self.updateLoop = RunService.Heartbeat:Connect(function(deltaTime)
        if not self.running then
            return
        end

        -- Check for timed out players
        local currentTime = tick()
        for player, playerData in pairs(self.players) do
            if currentTime - playerData.lastActivity > self.maxPlayerTimeout then
                print("Player timed out:", player.Name)
                self:removePlayer(player)
            end
        end

        -- Process physics/game logic here
        -- This would be expanded with actual game logic
    end)
end

function NetworkServer:startSendLoop()
    local sendInterval = 1 / self.sendRate

    self.sendLoop = RunService.Heartbeat:Connect(function()
        if not self.running then
            return
        end

        local currentTime = tick()
        if currentTime - self.lastSendTime < sendInterval then
            return
        end

        self.lastSendTime = currentTime

        -- Collect all dirty entity updates
        local updates = {}

        for entityId, _ in pairs(self.dirtyEntities) do
            local entity = self.entities[entityId]
            if entity then
                -- Find player data if this is a player entity
                local playerData = nil
                for _, pData in pairs(self.players) do
                    if pData.entityId == entityId then
                        playerData = pData
                        break
                    end
                end

                if playerData then
                    table.insert(updates, {
                        entityId = entityId,
                        position = playerData.position,
                        velocity = playerData.velocity,
                        state = "idle", -- This would come from actual state
                    })
                end
            end
        end

        -- Send batch update if there are any updates
        if #updates > 0 then
            self.sequence = self.sequence + 1

            Packets.BatchEntityUpdate.sendToAll({
                updates = updates,
                sequence = self.sequence,
                timestamp = currentTime,
            })

            -- Clear dirty flags
            self.dirtyEntities = {}
        end
    end)
end

function NetworkServer:broadcastDamage(targetId: string, damage: number, sourceId: string?, damageType: string?, knockback: Vector2?)
    Packets.DamageDealt.sendToAll({
        targetId = targetId,
        damage = damage,
        sourceId = sourceId,
        damageType = damageType,
        knockback = knockback,
    })
end

return NetworkServer