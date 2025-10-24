--!strict
-- Client-side networking module

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

-- Use SimplePackets instead of ByteNet for compatibility
local Packets = require(game.ReplicatedStorage.Shared.Network.SimplePackets)
local Types = require(game.ReplicatedStorage.Shared.Types)

type Vector2 = Types.Vector2
type InputState = Types.InputState
type EntityUpdate = Types.EntityUpdate

local NetworkClient = {}
NetworkClient.__index = NetworkClient

function NetworkClient.new()
    local self = setmetatable({}, NetworkClient)

    self.localPlayer = Players.LocalPlayer
    self.playerId = tostring(self.localPlayer.UserId)

    -- State management
    self.connected = false
    self.sequence = 0
    self.lastServerSequence = 0
    self.serverTimeOffset = 0
    self.ping = 0

    -- Input buffering for client-side prediction
    self.inputBuffer = {} :: {{input: InputState, sequence: number, timestamp: number}}
    self.maxInputBufferSize = 120 -- 2 seconds at 60fps

    -- Entity interpolation
    self.entityStates = {} :: {[string]: {current: EntityUpdate, previous: EntityUpdate?, lastUpdate: number}}
    self.interpolationDelay = 0.1 -- 100ms interpolation delay

    -- Callbacks
    self.onEntitySpawn = nil :: ((entityId: string, data: any) -> ())?
    self.onEntityDespawn = nil :: ((entityId: string) -> ())?
    self.onEntityUpdate = nil :: ((entityId: string, update: EntityUpdate) -> ())?
    self.onPlayerJoined = nil :: ((playerId: string, entityId: string) -> ())?
    self.onPlayerLeft = nil :: ((playerId: string) -> ())?
    self.onWorldState = nil :: ((state: any) -> ())?
    self.onDamageDealt = nil :: ((targetId: string, damage: number, sourceId: string?) -> ())?

    return self
end

function NetworkClient:connect()
    if self.connected then
        return
    end

    -- Set up packet receivers
    self:setupPacketHandlers()

    -- Start ping loop
    self:startPingLoop()

    -- Server will automatically spawn the player when they join
    -- No need to request spawn here (prevents race condition with server-side spawn)
    -- self:requestSpawn()

    self.connected = true
end

function NetworkClient:disconnect()
    self.connected = false

    -- Clean up
    if self.pingLoop then
        self.pingLoop:Disconnect()
        self.pingLoop = nil
    end

    if self.updateLoop then
        self.updateLoop:Disconnect()
        self.updateLoop = nil
    end
end

function NetworkClient:setupPacketHandlers()
    -- Entity spawn
    Packets.EntitySpawn.onClientEvent = function(data)
        -- Decode JSON data if present
        if data.data and type(data.data) == "string" then
            local success, decoded = pcall(function()
                return HttpService:JSONDecode(data.data)
            end)
            if success then
                data.data = decoded
            else
                warn("Failed to decode entity data JSON:", data.data)
            end
        end

        if self.onEntitySpawn then
            self.onEntitySpawn(data.entityId, data)
        end

        -- Initialize entity state for interpolation
        self.entityStates[data.entityId] = {
            current = {
                entityId = data.entityId,
                position = data.position,
                velocity = data.velocity,
                state = data.state,
                health = nil,
            },
            previous = nil,
            lastUpdate = tick(),
        }
    end

    -- Entity despawn
    Packets.EntityDespawn.onClientEvent = function(data)
        if self.onEntityDespawn then
            self.onEntityDespawn(data.entityId)
        end

        self.entityStates[data.entityId] = nil
    end

    -- Entity update
    Packets.EntityUpdate.onClientEvent = function(data)
        local state = self.entityStates[data.entityId]
        if state then
            state.previous = state.current
            state.current = {
                entityId = data.entityId,
                position = data.position,
                velocity = data.velocity,
                state = data.state,
                health = data.health,
                facingDirection = data.facingDirection,
            }
            state.lastUpdate = tick()
        end

        if self.onEntityUpdate then
            self.onEntityUpdate(data.entityId, data)
        end
    end

    -- Batch entity updates
    Packets.BatchEntityUpdate.onClientEvent = function(data)
        self.lastServerSequence = data.sequence

        -- Debug: Log batch updates occasionally
        if not self.lastBatchDebug or (tick() - self.lastBatchDebug) > 2 then
            self.lastBatchDebug = tick()
            print("[CLIENT] Received batch with", #data.updates, "updates, sequence:", data.sequence)
            for i, update in ipairs(data.updates) do
                if i <= 3 then  -- Only log first 3
                    print("  Update", i, "entity:", update.entityId:sub(1, 8), "pos:", math.floor(update.position.x), math.floor(update.position.y), "vel:", math.floor(update.velocity and update.velocity.x or 0), math.floor(update.velocity and update.velocity.y or 0))
                end
            end
        end

        for _, update in ipairs(data.updates) do
            local state = self.entityStates[update.entityId]
            if state then
                state.previous = state.current
                state.current = update
                state.lastUpdate = tick()
            else
                -- Entity state doesn't exist yet - create it on-demand
                -- This can happen if batch updates arrive before spawn packets due to network ordering
                print("[CLIENT] Creating entityState on-demand for", update.entityId:sub(1, 8))
                self.entityStates[update.entityId] = {
                    current = update,
                    previous = nil,
                    lastUpdate = tick(),
                }
            end

            if self.onEntityUpdate then
                self.onEntityUpdate(update.entityId, update)
            end
        end
    end

    -- Player joined
    Packets.PlayerJoined.onClientEvent = function(data)
        if self.onPlayerJoined then
            self.onPlayerJoined(data.playerId, data.entityId)
        end
    end

    -- Player left
    Packets.PlayerLeft.onClientEvent = function(data)
        if self.onPlayerLeft then
            self.onPlayerLeft(data.playerId)
        end
    end

    -- World state (for initial sync or reconnection)
    Packets.WorldState.onClientEvent = function(data)
        self.lastServerSequence = data.sequence

        -- Reset entity states
        self.entityStates = {}

        -- Initialize all entities
        for _, entity in ipairs(data.entities) do
            self.entityStates[entity.entityId] = {
                current = entity,
                previous = nil,
                lastUpdate = tick(),
            }
        end

        if self.onWorldState then
            self.onWorldState(data)
        end
    end

    -- Damage dealt
    Packets.DamageDealt.onClientEvent = function(data)
        if self.onDamageDealt then
            self.onDamageDealt(data.targetId, data.damage, data.sourceId)
        end
    end

    -- Ping response
    Packets.Ping.onClientEvent = function(data)
        if data.serverTime then
            local currentTime = tick()
            self.ping = (currentTime - data.clientTime) * 1000 -- Convert to milliseconds
            self.serverTimeOffset = data.serverTime - currentTime
        end
    end
end

function NetworkClient:startPingLoop()
    self.pingLoop = RunService.Heartbeat:Connect(function()
        if self.connected and tick() % 1 < 0.016 then -- Send ping every second
            Packets.Ping.send({
                clientTime = tick(),
            })
        end
    end)
end

function NetworkClient:sendInput(input: InputState, deltaTime: number)
    if not self.connected then
        return
    end

    self.sequence = self.sequence + 1

    -- Add to input buffer for reconciliation
    table.insert(self.inputBuffer, {
        input = input,
        sequence = self.sequence,
        timestamp = tick(),
    })

    -- Trim buffer if too large
    while #self.inputBuffer > self.maxInputBufferSize do
        table.remove(self.inputBuffer, 1)
    end

    -- Send input to server
    Packets.PlayerInput.send({
        input = input,
        sequence = self.sequence,
        deltaTime = deltaTime,
    })
end

function NetworkClient:sendPositionUpdate(position: Vector2, velocity: Vector2, state: string?)
    if not self.connected then
        return
    end

    self.sequence = self.sequence + 1

    -- Send client-authoritative position update to server
    -- Client has already processed movement/collision at 60fps
    -- IMPORTANT: Convert Vector2 to plain tables for network transmission
    Packets.PlayerInput.send({
        position = {x = position.x, y = position.y},
        velocity = {x = velocity.x, y = velocity.y},
        state = state or "idle",
        sequence = self.sequence,
        timestamp = tick(),
    })
end

function NetworkClient:sendAction(action: string, targetId: string?, position: Vector2?, data: string?)
    if not self.connected then
        return
    end

    Packets.PlayerAction.send({
        action = action,
        targetId = targetId,
        position = position,
        data = data,
    })
end

function NetworkClient:requestSpawn(characterType: string?, position: Vector2?)
    Packets.RequestSpawn.send({
        characterType = characterType or "default",
        position = position or {x = 0, y = 0},
    })
end

function NetworkClient:getInterpolatedPosition(entityId: string): Vector2?
    local state = self.entityStates[entityId]
    if not state then
        return nil
    end

    if not state.previous then
        return state.current.position
    end

    -- Calculate interpolation factor
    local currentTime = tick()
    local timeSinceUpdate = currentTime - state.lastUpdate

    -- Use a shorter interpolation window (33ms) for more responsive movement
    -- Server sends at 30Hz (33ms), so we interpolate over that period
    local interpolationWindow = 0.033 -- 33ms to match server send rate
    local interpolationFactor = math.min(timeSinceUpdate / interpolationWindow, 1)

    -- Use smooth step interpolation for more natural movement
    -- smoothstep(t) = t * t * (3 - 2 * t)
    local smoothFactor = interpolationFactor * interpolationFactor * (3 - 2 * interpolationFactor)

    -- Lerp between previous and current position with smoothstep
    local lerpedPosition = {
        x = state.previous.position.x + (state.current.position.x - state.previous.position.x) * smoothFactor,
        y = state.previous.position.y + (state.current.position.y - state.previous.position.y) * smoothFactor,
    }

    -- If we have velocity, add extrapolation for even smoother movement
    if state.current.velocity and interpolationFactor >= 0.8 then
        -- Extrapolate slightly beyond current position using velocity
        -- This helps bridge the gap between updates
        local extrapolationTime = math.min((timeSinceUpdate - interpolationWindow) * 0.5, 0.025) -- Max 25ms extrapolation
        lerpedPosition.x = lerpedPosition.x + state.current.velocity.x * extrapolationTime
        lerpedPosition.y = lerpedPosition.y + state.current.velocity.y * extrapolationTime
    end

    return lerpedPosition
end

function NetworkClient:getServerTime(): number
    return tick() + self.serverTimeOffset
end

function NetworkClient:getPing(): number
    return self.ping
end

function NetworkClient:reconcileWithServer(serverSequence: number, serverPosition: Vector2)
    -- Find the input that corresponds to the server sequence
    local inputIndex = nil
    for i, input in ipairs(self.inputBuffer) do
        if input.sequence == serverSequence then
            inputIndex = i
            break
        end
    end

    if not inputIndex then
        return -- Input not found in buffer
    end

    -- Remove all inputs before and including the acknowledged one
    for _ = 1, inputIndex do
        table.remove(self.inputBuffer, 1)
    end

    -- The remaining inputs in the buffer need to be re-applied
    -- This would be done by the movement system
    return self.inputBuffer
end

return NetworkClient