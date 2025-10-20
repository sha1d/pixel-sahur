local GuiElements = {}

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local mainScreenGui = Instance.new("ScreenGui", PlayerGui)
GuiElements["ScreenGui"] = mainScreenGui

mainScreenGui.Name = "MainScreenGui"
mainScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local watermarkImageLabel = Instance.new("ImageLabel", mainScreenGui)
GuiElements["ImageLabel"] = watermarkImageLabel

watermarkImageLabel.Name = "WatermarkImageLabel"
watermarkImageLabel.BorderSizePixel = 0
watermarkImageLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
watermarkImageLabel.ImageTransparency = 0.9
watermarkImageLabel.AnchorPoint = Vector2.new(0.9, 0.9)
watermarkImageLabel.Image = "rbxassetid://112564202907644"
watermarkImageLabel.Size = UDim2.new(0, 100, 0, 100)
watermarkImageLabel.BorderColor3 = Color3.fromRGB(0, 0, 0)
watermarkImageLabel.BackgroundTransparency = 1
watermarkImageLabel.Position = UDim2.new(0.2527, 0, 0.32813, 0)

local CONFIG = {
    ImageSize = UDim2.fromOffset(128, 128),
    HitBoxSize = Vector2.new(64, 64),

    Rows = 4,
    Cols = 5,

    CellW = 64,
    CellH = 64,

    StartX = 0,
    StartY = 0,

    Speed = 10,

    Animations = {
        Idle = "rbxassetid://112564202907644",
        Left = "rbxassetid://112564202907644",
        Right = "rbxassetid://112564202907644",
        Up = "rbxassetid://112564202907644",
        Down = "rbxassetid://112564202907644",
    },

    Ranges = {
        Idle = {0, 4},
        Left = {5, 8},
        Right = {5, 8},
        Up = {9, 12},
        Down = {13, 16}
    },

    SPEED = 200,
    ZOOM = 4,
}