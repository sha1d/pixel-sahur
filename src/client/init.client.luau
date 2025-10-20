--!strict
-- Client entry point for the 2D multiplayer game

local Players = game:GetService("Players")
local GameClient = require(script.GameClient)

-- Create and initialize the game client
local gameClient = GameClient.new()
gameClient:initialize()
gameClient:start()

-- Clean up when player leaves (client-side cleanup)
Players.LocalPlayer.AncestryChanged:Connect(function()
    if not Players.LocalPlayer:IsDescendantOf(game) then
        gameClient:destroy()
    end
end)

print("Pixel Sahur Started!")
