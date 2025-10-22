--!strict

local GameServer = require(script.GameServer)

local gameServer = GameServer.new()
gameServer:initialize()
gameServer:start()

game:BindToClose(function()
    gameServer:destroy()
end)

print("Pixel Sahur Game Server Started!")
