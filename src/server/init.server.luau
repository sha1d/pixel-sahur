--!strict
-- Server entry point for the 2D multiplayer game

local GameServer = require(script.GameServer)

-- Create and initialize the game server
local gameServer = GameServer.new()
gameServer:initialize()
gameServer:start()

-- Clean up on shutdown
game:BindToClose(function()
    gameServer:destroy()
end)

print("Pixel Sahur 2D Game Server Started!")
