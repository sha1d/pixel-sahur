--!strict
-- Simple networking using RemoteEvents/RemoteFunctions

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Create remotes folder
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
    if RunService:IsServer() then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    else
        remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
    end
end

local Packets = {}

-- Helper function to create or get a remote event
local function getOrCreateRemoteEvent(name: string): RemoteEvent
    local remote = remotesFolder:FindFirstChild(name)
    if not remote then
        if RunService:IsServer() then
            remote = Instance.new("RemoteEvent")
            remote.Name = name
            remote.Parent = remotesFolder
        else
            remote = remotesFolder:WaitForChild(name) :: RemoteEvent
        end
    end
    return remote :: RemoteEvent
end

-- Helper function to create packet wrapper
local function createPacket(name: string, isReliable: boolean?)
    local remote = getOrCreateRemoteEvent(name)

    return {
        -- Server methods
        sendToAll = function(data: any)
            if RunService:IsServer() then
                remote:FireAllClients(data)
            end
        end,

        sendTo = function(player: Player, data: any)
            if RunService:IsServer() then
                remote:FireClient(player, data)
            end
        end,

        onServerEvent = nil :: ((data: any, player: Player) -> ())?,

        -- Client methods
        send = function(data: any)
            if RunService:IsClient() then
                remote:FireServer(data)
            end
        end,

        onClientEvent = nil :: ((data: any) -> ())?,

        -- Internal setup
        _setup = function(self)
            if RunService:IsServer() then
                remote.OnServerEvent:Connect(function(player: Player, data: any)
                    if self.onServerEvent then
                        self.onServerEvent(data, player)
                    end
                end)
            else
                remote.OnClientEvent:Connect(function(data: any)
                    if self.onClientEvent then
                        self.onClientEvent(data)
                    end
                end)
            end
        end
    }
end

-- Create all packets
Packets.PlayerInput = createPacket("PlayerInput", false)
Packets.PlayerAction = createPacket("PlayerAction", true)
Packets.RequestSpawn = createPacket("RequestSpawn", true)
Packets.EntitySpawn = createPacket("EntitySpawn", true)
Packets.EntityDespawn = createPacket("EntityDespawn", true)
Packets.EntityUpdate = createPacket("EntityUpdate", false)
Packets.BatchEntityUpdate = createPacket("BatchEntityUpdate", false)
Packets.PlayerJoined = createPacket("PlayerJoined", true)
Packets.PlayerLeft = createPacket("PlayerLeft", true)
Packets.WorldState = createPacket("WorldState", true)
Packets.DamageDealt = createPacket("DamageDealt", true)
Packets.ActionResult = createPacket("ActionResult", true)
Packets.Chat = createPacket("Chat", true)
Packets.Ping = createPacket("Ping", false)

-- Setup all packets
for _, packet in pairs(Packets) do
    if packet._setup then
        packet:_setup()
    end
end

return Packets