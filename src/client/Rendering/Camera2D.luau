--!strict

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Types = require(game.ReplicatedStorage.Shared.Types)
local Vector2 = require(game.ReplicatedStorage.Shared.Utils.Vector2)
local Rectangle = require(game.ReplicatedStorage.Shared.Utils.Rectangle)

type Vector2Type = Types.Vector2
type Rectangle = Types.Rectangle

local Camera2D = {}
Camera2D.__index = Camera2D

export type CameraConfig = {
    position: Vector2Type?,
    zoom: number?,
    minZoom: number?,
    maxZoom: number?,
    bounds: Rectangle?,
    smoothing: number?,
    rotationSmoothing: number?,
    deadZone: Rectangle?,
    lookAheadDistance: number?,
    screenShakeIntensity: number?,
}

export type ScreenShake = {
    intensity: number,
    duration: number,
    frequency: number,
    fadeOut: boolean,
    elapsed: number,
}

function Camera2D.new(viewportSize: Vector2Type, config: CameraConfig?)
    local self = setmetatable({}, Camera2D)

    -- Configuration
    config = config or {}
    self.position = config.position or Vector2.zero()
    self.targetPosition = self.position
    self.zoom = config.zoom or 1
    self.targetZoom = self.zoom
    self.minZoom = config.minZoom or 0.1
    self.maxZoom = config.maxZoom or 10
    self.bounds = config.bounds
    self.smoothing = config.smoothing or 5
    self.rotationSmoothing = config.rotationSmoothing or 5

    -- Viewport
    self.viewportSize = viewportSize
    self.viewportCenter = Vector2.divide(viewportSize, 2)

    -- Rotation
    self.rotation = 0
    self.targetRotation = 0

    -- Following
    self.followTarget = nil :: string?
    self.followOffset = Vector2.zero()
    self.deadZone = config.deadZone
    self.lookAheadDistance = config.lookAheadDistance or 0
    self.lookAheadDirection = Vector2.zero()

    -- Screen shake
    self.screenShakes = {} :: {ScreenShake}
    self.shakeOffset = Vector2.zero()
    self.maxShakeIntensity = config.screenShakeIntensity or 10

    -- Smooth zoom
    self.zoomTween = nil :: Tween?

    -- Transitions
    self.isTransitioning = false
    self.transitionTween = nil :: Tween?

    -- Callbacks
    self.onPositionChanged = nil :: ((position: Vector2Type) -> ())?
    self.onZoomChanged = nil :: ((zoom: number) -> ())?

    return self
end

function Camera2D:setPosition(position: Vector2Type, instant: boolean?)
    self.targetPosition = position

    if instant then
        self.position = position
        if self.onPositionChanged then
            self.onPositionChanged(position)
        end
    end

    -- Apply bounds if set
    if self.bounds then
        self:applyBounds()
    end
end

function Camera2D:getPosition(): Vector2Type
    return Vector2.add(self.position, self.shakeOffset)
end

function Camera2D:setZoom(zoom: number, instant: boolean?, duration: number?)
    zoom = math.clamp(zoom, self.minZoom, self.maxZoom)
    self.targetZoom = zoom

    if instant then
        self.zoom = zoom
        if self.onZoomChanged then
            self.onZoomChanged(zoom)
        end
    elseif duration and duration > 0 then
        -- Animated zoom using TweenService
        if self.zoomTween then
            self.zoomTween:Cancel()
        end

        local zoomValue = Instance.new("NumberValue")
        zoomValue.Value = self.zoom

        self.zoomTween = TweenService:Create(
            zoomValue,
            TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
            {Value = zoom}
        )

        local connection
        connection = zoomValue:GetPropertyChangedSignal("Value"):Connect(function()
            self.zoom = zoomValue.Value
            if self.onZoomChanged then
                self.onZoomChanged(self.zoom)
            end
        end)

        self.zoomTween.Completed:Connect(function()
            connection:Disconnect()
            zoomValue:Destroy()
            self.zoomTween = nil
        end)

        self.zoomTween:Play()
    end
end

function Camera2D:zoomIn(amount: number?)
    amount = amount or 0.1
    self:setZoom(self.targetZoom + amount)
end

function Camera2D:zoomOut(amount: number?)
    amount = amount or 0.1
    self:setZoom(self.targetZoom - amount)
end

function Camera2D:follow(targetId: string?, offset: Vector2Type?)
    self.followTarget = targetId
    self.followOffset = offset or Vector2.zero()
end

function Camera2D:stopFollowing()
    self.followTarget = nil
    self.followOffset = Vector2.zero()
end

function Camera2D:setDeadZone(deadZone: Rectangle?)
    self.deadZone = deadZone
end

function Camera2D:setBounds(bounds: Rectangle?)
    self.bounds = bounds
    if bounds then
        self:applyBounds()
    end
end

function Camera2D:applyBounds()
    if not self.bounds then
        return
    end

    -- Calculate camera bounds based on viewport and zoom
    local halfViewport = Vector2.divide(self.viewportSize, 2 * self.zoom)

    local minX = self.bounds.x + halfViewport.x
    local maxX = self.bounds.x + self.bounds.width - halfViewport.x
    local minY = self.bounds.y + halfViewport.y
    local maxY = self.bounds.y + self.bounds.height - halfViewport.y

    -- Clamp position to bounds
    self.targetPosition = Vector2.clamp(
        self.targetPosition,
        Vector2.new(minX, minY),
        Vector2.new(maxX, maxY)
    )
end

function Camera2D:shake(intensity: number?, duration: number?, frequency: number?, fadeOut: boolean?)
    local shake: ScreenShake = {
        intensity = intensity or 5,
        duration = duration or 0.5,
        frequency = frequency or 60,
        fadeOut = if fadeOut ~= nil then fadeOut else true,
        elapsed = 0,
    }

    table.insert(self.screenShakes, shake)
end

function Camera2D:stopShake()
    self.screenShakes = {}
    self.shakeOffset = Vector2.zero()
end

function Camera2D:updateShake(deltaTime: number)
    if #self.screenShakes == 0 then
        self.shakeOffset = Vector2.zero()
        return
    end

    local totalShake = Vector2.zero()

    -- Update and combine all active shakes
    for i = #self.screenShakes, 1, -1 do
        local shake = self.screenShakes[i]
        shake.elapsed = shake.elapsed + deltaTime

        if shake.elapsed >= shake.duration then
            -- Remove finished shake
            table.remove(self.screenShakes, i)
        else
            -- Calculate shake intensity
            local intensity = shake.intensity
            if shake.fadeOut then
                -- Fade out over time
                intensity = intensity * (1 - shake.elapsed / shake.duration)
            end

            -- Apply frequency
            local shakeAmount = math.sin(shake.elapsed * shake.frequency) * intensity

            -- Add random offset
            local shakeX = (math.random() - 0.5) * 2 * shakeAmount
            local shakeY = (math.random() - 0.5) * 2 * shakeAmount

            totalShake = Vector2.add(totalShake, Vector2.new(shakeX, shakeY))
        end
    end

    -- Clamp total shake to max intensity
    local shakeLength = Vector2.length(totalShake)
    if shakeLength > self.maxShakeIntensity then
        totalShake = Vector2.multiply(
            Vector2.normalize(totalShake),
            self.maxShakeIntensity
        )
    end

    self.shakeOffset = totalShake
end

function Camera2D:transitionTo(position: Vector2Type, zoom: number?, duration: number, easingStyle: Enum.EasingStyle?)
    if self.isTransitioning and self.transitionTween then
        self.transitionTween:Cancel()
    end

    self.isTransitioning = true
    easingStyle = easingStyle or Enum.EasingStyle.Quad

    -- Create value objects for tweening
    local posValue = Instance.new("Vector3Value")
    posValue.Value = Vector3.new(self.position.x, self.position.y, 0)

    local targetPos = Vector3.new(position.x, position.y, 0)

    self.transitionTween = TweenService:Create(
        posValue,
        TweenInfo.new(duration, easingStyle, Enum.EasingDirection.InOut),
        {Value = targetPos}
    )

    local connection
    connection = posValue:GetPropertyChangedSignal("Value"):Connect(function()
        self.position = Vector2.new(posValue.Value.X, posValue.Value.Y)
        self.targetPosition = self.position
    end)

    self.transitionTween.Completed:Connect(function()
        self.isTransitioning = false
        connection:Disconnect()
        posValue:Destroy()
        self.transitionTween = nil
    end)

    self.transitionTween:Play()

    -- Also transition zoom if provided
    if zoom then
        self:setZoom(zoom, false, duration)
    end
end

function Camera2D:update(deltaTime: number, targetPosition: Vector2Type?)
    -- Update screen shake
    self:updateShake(deltaTime)

    -- Update following if target position provided
    if self.followTarget and targetPosition then
        self:updateFollowing(targetPosition)
    end

    -- Smooth position lerping
    if not self.isTransitioning then
        local lerpSpeed = 1 - math.exp(-self.smoothing * deltaTime)
        self.position = Vector2.lerp(self.position, self.targetPosition, lerpSpeed)

        if self.onPositionChanged then
            self.onPositionChanged(self:getPosition())
        end
    end

    -- Smooth zoom lerping
    if not self.zoomTween then
        local zoomLerpSpeed = 1 - math.exp(-self.smoothing * deltaTime)
        self.zoom = self.zoom + (self.targetZoom - self.zoom) * zoomLerpSpeed

        if self.onZoomChanged then
            self.onZoomChanged(self.zoom)
        end
    end

    -- Smooth rotation lerping
    local rotLerpSpeed = 1 - math.exp(-self.rotationSmoothing * deltaTime)
    self.rotation = self.rotation + (self.targetRotation - self.rotation) * rotLerpSpeed
end

function Camera2D:updateFollowing(targetPosition: Vector2Type)
    local followPos = Vector2.add(targetPosition, self.followOffset)

    -- Apply dead zone if configured
    if self.deadZone then
        local cameraRect = Rectangle.fromCenter(self.position, self.deadZone:getSize())

        if not Rectangle.contains(cameraRect, targetPosition) then
            -- Target is outside dead zone, adjust camera
            local deadZoneCenter = Rectangle.getCenter(self.deadZone)
            local offset = Vector2.subtract(targetPosition, deadZoneCenter)

            -- Calculate how much to move camera
            local moveX = 0
            local moveY = 0

            if targetPosition.x < cameraRect.x then
                moveX = targetPosition.x - cameraRect.x
            elseif targetPosition.x > cameraRect.x + cameraRect.width then
                moveX = targetPosition.x - (cameraRect.x + cameraRect.width)
            end

            if targetPosition.y < cameraRect.y then
                moveY = targetPosition.y - cameraRect.y
            elseif targetPosition.y > cameraRect.y + cameraRect.height then
                moveY = targetPosition.y - (cameraRect.y + cameraRect.height)
            end

            followPos = Vector2.add(self.position, Vector2.new(moveX, moveY))
        else
            -- Target is within dead zone, don't move camera
            return
        end
    end

    -- Apply look ahead if configured
    if self.lookAheadDistance > 0 then
        followPos = Vector2.add(followPos, Vector2.multiply(self.lookAheadDirection, self.lookAheadDistance))
    end

    self:setPosition(followPos)
end

function Camera2D:setLookAheadDirection(direction: Vector2Type)
    self.lookAheadDirection = Vector2.normalize(direction)
end

function Camera2D:worldToScreen(worldPos: Vector2Type): Vector2Type
    -- Apply camera transform
    local cameraPos = self:getPosition()
    local relativePos = Vector2.subtract(worldPos, cameraPos)

    -- Apply zoom
    relativePos = Vector2.multiply(relativePos, self.zoom)

    -- Apply rotation
    if self.rotation ~= 0 then
        relativePos = Vector2.rotate(relativePos, self.rotation)
    end

    -- Center on viewport
    return Vector2.add(relativePos, self.viewportCenter)
end

function Camera2D:screenToWorld(screenPos: Vector2Type): Vector2Type
    -- Reverse the world to screen transformation
    local relativePos = Vector2.subtract(screenPos, self.viewportCenter)

    -- Reverse rotation
    if self.rotation ~= 0 then
        relativePos = Vector2.rotate(relativePos, -self.rotation)
    end

    -- Reverse zoom
    relativePos = Vector2.divide(relativePos, self.zoom)

    -- Add camera position
    local cameraPos = self:getPosition()
    return Vector2.add(relativePos, cameraPos)
end

function Camera2D:getVisibleBounds(): Rectangle
    local halfSize = Vector2.divide(self.viewportSize, 2 * self.zoom)
    local cameraPos = self:getPosition()

    return Rectangle.new(
        cameraPos.x - halfSize.x,
        cameraPos.y - halfSize.y,
        halfSize.x * 2,
        halfSize.y * 2
    )
end

function Camera2D:isVisible(worldBounds: Rectangle): boolean
    local visibleBounds = self:getVisibleBounds()
    return Rectangle.intersects(visibleBounds, worldBounds)
end

function Camera2D:setViewportSize(size: Vector2Type)
    self.viewportSize = size
    self.viewportCenter = Vector2.divide(size, 2)

    -- Reapply bounds with new viewport size
    if self.bounds then
        self:applyBounds()
    end
end

function Camera2D:destroy()
    if self.zoomTween then
        self.zoomTween:Cancel()
        self.zoomTween = nil
    end

    if self.transitionTween then
        self.transitionTween:Cancel()
        self.transitionTween = nil
    end

    self.screenShakes = {}
end

return Camera2D