--!strict
-- Network packet definitions using ByteNet

local ByteNet = require(game.ReplicatedStorage.Packages.ByteNet)

-- Create packets using ByteNet v0.4.1 API
local Packets = {}

-- Client to Server packets
Packets.PlayerInput = ByteNet.definePacket({
    reliabilityType = "unreliable",
})

Packets.PlayerAction = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.RequestSpawn = ByteNet.definePacket({
    reliabilityType = "reliable",
})

-- Server to Client packets
Packets.EntitySpawn = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.EntityDespawn = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.EntityUpdate = ByteNet.definePacket({
    reliabilityType = "unreliable",
})

Packets.BatchEntityUpdate = ByteNet.definePacket({
    reliabilityType = "unreliable",
})

Packets.PlayerJoined = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.PlayerLeft = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.WorldState = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.DamageDealt = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.ActionResult = ByteNet.definePacket({
    reliabilityType = "reliable",
})

-- Bi-directional packets
Packets.Chat = ByteNet.definePacket({
    reliabilityType = "reliable",
})

Packets.Ping = ByteNet.definePacket({
    reliabilityType = "unreliable",
})

return Packets