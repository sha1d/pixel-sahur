--!strict
-- Zoom Controller for manual and automatic zoom adjustments

local UserInputService = game:GetService("UserInputService")
local Types = require(game.ReplicatedStorage.Shared.Types)

type WorldRenderer = any

local ZoomController = {}
ZoomController.__index = ZoomController

function ZoomController.new(worldRenderer: WorldRenderer)
    local self = setmetatable({}, ZoomController)

    self.worldRenderer = worldRenderer
    self.baseZoom = 1.0
    self.currentZoom = 1.0
    self.minZoom = 0.5
    self.maxZoom = 2.0
    self.zoomStep = 0.1

    -- Adaptive zoom settings
    self.enableAdaptive = false
    self.adaptiveStrength = 0.5  -- 0.0 to 1.0, how strong the effect is

    return self
end

function ZoomController:setAdaptiveZoom(enabled: boolean, strength: number?)
    self.enableAdaptive = enabled
    if strength then
        self.adaptiveStrength = math.clamp(strength, 0, 1)
    end
    self:updateZoom()
end

function ZoomController:zoomIn()
    self.baseZoom = math.min(self.baseZoom + self.zoomStep, self.maxZoom)
    self:updateZoom()
end

function ZoomController:zoomOut()
    self.baseZoom = math.max(self.baseZoom - self.zoomStep, self.minZoom)
    self:updateZoom()
end

function ZoomController:setZoom(zoom: number)
    self.baseZoom = math.clamp(zoom, self.minZoom, self.maxZoom)
    self:updateZoom()
end

function ZoomController:resetZoom()
    self.baseZoom = 1.0
    self:updateZoom()
end

function ZoomController:updateZoom()
    local finalZoom = self.baseZoom

    if self.enableAdaptive and self.worldRenderer then
        -- Get screen size
        local screenSize = self.worldRenderer.screenSize
        if screenSize then
            -- Simple adaptive calculation
            local screenWidth = screenSize.x
            local referenceWidth = 1920

            if screenWidth < referenceWidth then
                -- Smaller screens: slight zoom in
                local ratio = screenWidth / referenceWidth
                local adaptiveBoost = (1 - ratio) * self.adaptiveStrength
                finalZoom = finalZoom * (1 + adaptiveBoost)
            end
        end
    end

    self.currentZoom = finalZoom

    if self.worldRenderer then
        self.worldRenderer:setCameraZoom(finalZoom)
    end
end

function ZoomController:getCurrentZoom(): number
    return self.currentZoom
end

function ZoomController:getBaseZoom(): number
    return self.baseZoom
end

return ZoomController