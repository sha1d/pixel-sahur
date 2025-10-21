--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

-- Save reference to Roblox Vector2 before importing custom Vector2
local RobloxVector2 = Vector2

local Types = require(game.ReplicatedStorage.Shared.Types)
local Vector2 = require(game.ReplicatedStorage.Shared.Utils.Vector2)
local Rectangle = require(game.ReplicatedStorage.Shared.Utils.Rectangle)

type Vector2Type = Types.Vector2
type Rectangle = Types.Rectangle
type Camera = Types.Camera
type Entity = Types.Entity

local WorldRenderer = {}
WorldRenderer.__index = WorldRenderer

export type RenderLayer = {
    name: string,
    zIndex: number,
    parallaxFactor: Vector2Type,
    opacity: number,
    visible: boolean,
    frame: Frame,
    entities: {[string]: ImageLabel},
}

export type RenderConfig = {
    pixelScale: number, -- Base pixel scale (e.g., 4 for 4x pixels)
    targetResolution: Vector2Type, -- Target resolution for scaling
    maintainAspectRatio: boolean,
    antiAliasing: boolean,
    pixelPerfect: boolean,
    backgroundColor: Color3,
}

function WorldRenderer.new(screenGui: ScreenGui, config: RenderConfig?)
    local self = setmetatable({}, WorldRenderer)

    self.screenGui = screenGui

    -- Configuration
    local defaultConfig = {
        pixelScale = 4,
        targetResolution = Vector2.new(1920, 1080),
        maintainAspectRatio = true,
        antiAliasing = false,
        pixelPerfect = true,
        backgroundColor = Color3.new(0.1, 0.1, 0.2),
    }
    self.config = config or defaultConfig

    -- Viewport
    self.viewport = Rectangle.new(0, 0, 1920, 1080)
    self.screenSize = Vector2.new(1920, 1080)
    self.scaleFactor = 1

    -- Main containers
    self.viewportFrame = nil :: Frame?
    self.worldContainer = nil :: Frame?
    self.uiContainer = nil :: Frame?
    self.debugContainer = nil :: Frame?

    -- Rendering layers
    self.layers = {} :: {[string]: RenderLayer}
    self.layerOrder = {} :: {string}

    -- Entity rendering
    self.entityRenderers = {} :: {[string]: ImageLabel}
    self.entityAnimations = {} :: {[string]: any} -- Animation controllers

    -- Camera
    self.camera = {
        position = Vector2.new(0, 0),
        zoom = 1,
        rotation = 0,
        viewport = Rectangle.new(0, 0, 1920, 1080),
        followTarget = nil,
        smoothing = 0.1,
        bounds = nil,
    } :: Camera

    -- Performance
    self.visibleEntities = {} :: {[string]: boolean}
    self.cullingEnabled = true
    self.cullingMargin = 200 -- Extra pixels in world space to keep objects rendered beyond screen bounds
    self.batchRendering = true

    -- Debug
    self.debugMode = false
    self.showFPS = false
    self.showEntityCount = false
    self.fpsLabel = nil :: TextLabel?

    -- MEMORY LEAK FIX: Store connections for cleanup
    self.resizeConnection = nil :: RBXScriptConnection?
    self.debugConnection = nil :: RBXScriptConnection?

    -- Resize debouncing
    self.resizeDebounceTime = 0.1 -- 100ms debounce
    self.lastResizeTime = 0
    self.resizeScheduled = false

    -- Initialize
    self:initialize()

    return self
end

function WorldRenderer:initialize()
    -- Create main viewport frame
    self.viewportFrame = Instance.new("Frame")
    self.viewportFrame.Name = "Viewport"
    self.viewportFrame.Size = UDim2.fromScale(1, 1)
    self.viewportFrame.BackgroundColor3 = self.config.backgroundColor
    self.viewportFrame.BorderSizePixel = 0
    self.viewportFrame.ClipsDescendants = true
    self.viewportFrame.Parent = self.screenGui

    -- Create world container (for game entities)
    self.worldContainer = Instance.new("Frame")
    self.worldContainer.Name = "World"
    self.worldContainer.Size = UDim2.fromScale(1, 1)
    self.worldContainer.BackgroundTransparency = 1
    self.worldContainer.BorderSizePixel = 0
    self.worldContainer.Parent = self.viewportFrame

    -- Create UI container (for HUD elements)
    self.uiContainer = Instance.new("Frame")
    self.uiContainer.Name = "UI"
    self.uiContainer.Size = UDim2.fromScale(1, 1)
    self.uiContainer.BackgroundTransparency = 1
    self.uiContainer.BorderSizePixel = 0
    self.uiContainer.ZIndex = 1000
    self.uiContainer.Parent = self.viewportFrame

    -- Create debug container
    self.debugContainer = Instance.new("Frame")
    self.debugContainer.Name = "Debug"
    self.debugContainer.Size = UDim2.fromScale(1, 1)
    self.debugContainer.BackgroundTransparency = 1
    self.debugContainer.BorderSizePixel = 0
    self.debugContainer.ZIndex = 2000
    self.debugContainer.Visible = false
    self.debugContainer.Parent = self.viewportFrame

    -- Create default layers
    self:createLayer("background", -100, Vector2.new(0.5, 0.5))
    self:createLayer("midground", 0, Vector2.new(1, 1))
    self:createLayer("foreground", 100, Vector2.new(1.5, 1.5))
    self:createLayer("entities", 50, Vector2.new(1, 1))
    self:createLayer("effects", 200, Vector2.new(1, 1))

    -- Set up viewport scaling
    self:updateViewportScale()

    -- Listen for screen size changes with debouncing
    -- PERFORMANCE FIX: Debounce screen size changes to prevent jitter during window resize
    self.resizeConnection = self.screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        self:scheduleViewportUpdate()
    end)
end

function WorldRenderer:createLayer(name: string, zIndex: number, parallaxFactor: Vector2Type?)
    local layerFrame = Instance.new("Frame")
    layerFrame.Name = "Layer_" .. name
    layerFrame.Size = UDim2.fromScale(1, 1)
    layerFrame.BackgroundTransparency = 1
    layerFrame.BorderSizePixel = 0
    layerFrame.ZIndex = zIndex + 500 -- Offset to avoid negative ZIndex
    layerFrame.Parent = self.worldContainer

    local layer: RenderLayer = {
        name = name,
        zIndex = zIndex,
        parallaxFactor = parallaxFactor or Vector2.new(1, 1),
        opacity = 1,
        visible = true,
        frame = layerFrame,
        entities = {},
    }

    self.layers[name] = layer
    table.insert(self.layerOrder, name)

    -- Sort layers by zIndex
    table.sort(self.layerOrder, function(a, b)
        return self.layers[a].zIndex < self.layers[b].zIndex
    end)

    return layer
end

function WorldRenderer:scheduleViewportUpdate()
    -- PERFORMANCE FIX: Debounce viewport updates during rapid screen size changes
    -- This prevents jitter and performance issues when dragging window or going fullscreen
    local currentTime = tick()
    self.lastResizeTime = currentTime

    if not self.resizeScheduled then
        self.resizeScheduled = true

        task.delay(self.resizeDebounceTime, function()
            -- Check if enough time has passed since last resize
            if tick() - self.lastResizeTime >= self.resizeDebounceTime then
                -- Enough time passed, update viewport
                self:updateViewportScale()
                self.resizeScheduled = false
            else
                -- More resizes happened during debounce, reschedule
                self.resizeScheduled = false
                self:scheduleViewportUpdate()
            end
        end)
    end
end

function WorldRenderer:updateViewportScale()
    local screenSize = self.screenGui.AbsoluteSize
    self.screenSize = Vector2.new(screenSize.X, screenSize.Y)

    if self.config.maintainAspectRatio then
        local targetAspect = self.config.targetResolution.x / self.config.targetResolution.y
        local screenAspect = screenSize.X / screenSize.Y

        if screenAspect > targetAspect then
            -- Screen is wider than target
            self.scaleFactor = screenSize.Y / self.config.targetResolution.y
            local width = screenSize.Y * targetAspect
            self.viewport = Rectangle.new(
                (screenSize.X - width) / 2,
                0,
                width,
                screenSize.Y
            )
        else
            -- Screen is taller than target
            self.scaleFactor = screenSize.X / self.config.targetResolution.x
            local height = screenSize.X / targetAspect
            self.viewport = Rectangle.new(
                0,
                (screenSize.Y - height) / 2,
                screenSize.X,
                height
            )
        end
    else
        self.scaleFactor = math.min(
            screenSize.X / self.config.targetResolution.x,
            screenSize.Y / self.config.targetResolution.y
        )
        self.viewport = Rectangle.new(0, 0, screenSize.X, screenSize.Y)
    end

    -- Apply pixel scale
    self.scaleFactor = self.scaleFactor * self.config.pixelScale

    -- Update camera viewport
    self.camera.viewport = self.viewport

    -- Update all entity renderer sizes to match new scale
    self:updateAllEntitySizes()
end

function WorldRenderer:createEntityRenderer(entityId: string, imageId: string, size: Vector2Type, layer: string?)
    layer = layer or "entities"
    local layerData = self.layers[layer]
    if not layerData then
        warn("Layer not found:", layer)
        return nil
    end

    -- Check if renderer already exists - if so, return existing one
    if self.entityRenderers[entityId] then
        warn("Entity renderer already exists for:", entityId, "- returning existing renderer")
        return self.entityRenderers[entityId]
    end

    local imageLabel = Instance.new("ImageLabel")
    imageLabel.Name = "Entity_" .. entityId
    imageLabel.Image = imageId
    -- Ensure sizes are at least 1 pixel to prevent UI errors
    local scaledWidth = math.max(1, math.abs(size.x * self.scaleFactor))
    local scaledHeight = math.max(1, math.abs(size.y * self.scaleFactor))
    imageLabel.Size = UDim2.fromOffset(scaledWidth, scaledHeight)

    -- If no image, show background color (for obstacles/walls)
    if imageId == "" or imageId == nil then
        imageLabel.BackgroundTransparency = 0
        imageLabel.BackgroundColor3 = Color3.new(0.5, 0.5, 0.5) -- Default gray
    else
        imageLabel.BackgroundTransparency = 1
    end

    imageLabel.BorderSizePixel = 0
    imageLabel.ScaleType = Enum.ScaleType.Fit
    imageLabel.AnchorPoint = RobloxVector2.new(0.5, 0.5)

    -- Store original world size as attributes for future scale updates
    imageLabel:SetAttribute("WorldWidth", size.x)
    imageLabel:SetAttribute("WorldHeight", size.y)

    -- Apply pixel-perfect rendering
    if self.config.pixelPerfect then
        imageLabel.ResampleMode = Enum.ResamplerMode.Pixelated
    end

    imageLabel.Parent = layerData.frame
    layerData.entities[entityId] = imageLabel
    self.entityRenderers[entityId] = imageLabel

    return imageLabel
end

function WorldRenderer:setupEntityAnimation(entityId: string, config: {
    spriteSheet: string,
    frameWidth: number,
    frameHeight: number,
    animations: {[string]: {
        startFrame: number,
        endFrame: number,
        frameRate: number?,
        loop: boolean?,
    }}
})
    local renderer = self.entityRenderers[entityId]
    if not renderer then
        warn("Cannot setup animation: renderer not found for entity", entityId)
        return nil
    end

    -- MEMORY LEAK FIX: Destroy existing animation controller if it exists
    -- This prevents accumulation of RunService.Heartbeat connections
    if self.entityAnimations[entityId] then
        self.entityAnimations[entityId]:destroy()
        self.entityAnimations[entityId] = nil
    end

    -- Import AnimationController (local to avoid global pollution)
    local AnimationController = require(game.ReplicatedStorage.Shared.Animation.AnimationController)

    -- Create animation controller
    local animController = AnimationController.new(renderer)

    -- Calculate frames per row
    local cols = 5 -- Based on Character.luau config

    -- Register animations
    for name, animConfig in pairs(config.animations) do
        local frames = {}
        local frameDuration = if animConfig.frameRate then 1 / animConfig.frameRate else 0.1

        -- Convert frame indices to grid positions
        for frameIdx = animConfig.startFrame, animConfig.endFrame do
            local col = frameIdx % cols
            local row = math.floor(frameIdx / cols)

            table.insert(frames, {
                x = col * config.frameWidth,
                y = row * config.frameHeight,
                width = config.frameWidth,
                height = config.frameHeight,
                duration = frameDuration,
            })
        end

        animController:registerAnimation({
            name = name,
            spriteSheet = config.spriteSheet,
            frameSize = Vector2.new(config.frameWidth, config.frameHeight),
            frames = frames,
            loop = if animConfig.loop ~= nil then animConfig.loop else true,
            speed = 1,
        })
    end

    -- Store animation controller
    self.entityAnimations[entityId] = animController

    return animController
end

function WorldRenderer:getEntityAnimation(entityId: string): any?
    return self.entityAnimations[entityId]
end

function WorldRenderer:setEntityFlip(entityId: string, flipX: boolean, flipY: boolean?)
    local renderer = self.entityRenderers[entityId]
    if not renderer then
        return
    end

    -- Store flip state as attributes so AnimationController can respect it
    renderer:SetAttribute("FlipX", flipX)
    renderer:SetAttribute("FlipY", if flipY ~= nil then flipY else false)

    -- Get the animation controller for this entity
    local animController = self.entityAnimations[entityId]
    if animController then
        -- If there's an animation playing, trigger a frame update to apply the flip
        animController:updateFrame()
    else
        -- No animation controller, apply flip directly to current ImageRect
        local currentOffset = renderer.ImageRectOffset
        local currentSize = renderer.ImageRectSize

        -- Calculate new ImageRect values based on flip state
        local newOffsetX = currentOffset.X
        local newOffsetY = currentOffset.Y
        local newSizeX = currentSize.X
        local newSizeY = currentSize.Y

        -- Flip horizontally: move offset to end of image and use negative width
        if flipX and newSizeX > 0 then
            newOffsetX = currentOffset.X + currentSize.X
            newSizeX = -currentSize.X
        elseif not flipX and newSizeX < 0 then
            newOffsetX = currentOffset.X + currentSize.X
            newSizeX = -currentSize.X
        end

        -- Flip vertically: move offset to end of image and use negative height
        if flipY and newSizeY > 0 then
            newOffsetY = currentOffset.Y + currentSize.Y
            newSizeY = -currentSize.Y
        elseif not flipY and newSizeY < 0 then
            newOffsetY = currentOffset.Y + currentSize.Y
            newSizeY = -currentSize.Y
        end

        -- Apply the flipped ImageRect
        renderer.ImageRectOffset = RobloxVector2.new(newOffsetX, newOffsetY)
        renderer.ImageRectSize = RobloxVector2.new(newSizeX, newSizeY)
    end
end

function WorldRenderer:removeEntityRenderer(entityId: string)
    local renderer = self.entityRenderers[entityId]
    if renderer then
        renderer:Destroy()
        self.entityRenderers[entityId] = nil

        -- Remove from all layers
        for _, layer in pairs(self.layers) do
            layer.entities[entityId] = nil
        end

        -- Clean up animation controller if exists
        if self.entityAnimations[entityId] then
            self.entityAnimations[entityId]:destroy()
            self.entityAnimations[entityId] = nil
        end
    end
end

function WorldRenderer:updateEntityPosition(entityId: string, worldPosition: Vector2Type, layer: string?)
    local renderer = self.entityRenderers[entityId]
    if not renderer then
        return
    end

    -- Apply parallax if entity is in a specific layer
    local parallaxFactor = Vector2.one()
    if layer then
        local layerData = self.layers[layer]
        if layerData then
            parallaxFactor = layerData.parallaxFactor
        end
    end

    -- Convert world position to screen position
    local screenPos = self:worldToScreen(worldPosition, parallaxFactor)

    -- Apply pixel-perfect positioning
    if self.config.pixelPerfect then
        screenPos = Vector2.new(
            math.floor(screenPos.x + 0.5),
            math.floor(screenPos.y + 0.5)
        )
    end

    renderer.Position = UDim2.fromOffset(screenPos.x, screenPos.y)
end

function WorldRenderer:updateEntitySprite(entityId: string, imageId: string, imageRect: Rectangle?)
    local renderer = self.entityRenderers[entityId]
    if not renderer then
        return
    end

    renderer.Image = imageId

    if imageRect then
        renderer.ImageRectOffset = RobloxVector2.new(imageRect.x, imageRect.y)
        renderer.ImageRectSize = RobloxVector2.new(imageRect.width, imageRect.height)
    else
        renderer.ImageRectOffset = RobloxVector2.new(0, 0)
        renderer.ImageRectSize = RobloxVector2.new(0, 0)
    end
end

function WorldRenderer:worldToScreen(worldPos: Vector2Type, parallaxFactor: Vector2Type?): Vector2Type
    parallaxFactor = parallaxFactor or Vector2.one()

    -- Apply camera transform
    local cameraOffset = Vector2.scale(self.camera.position, parallaxFactor)
    local relativePos = Vector2.subtract(worldPos, cameraOffset)

    -- Apply zoom
    relativePos = Vector2.multiply(relativePos, self.camera.zoom * self.scaleFactor)

    -- Center on screen
    local screenCenter = Vector2.new(
        self.viewport.width / 2,
        self.viewport.height / 2
    )

    return Vector2.add(relativePos, screenCenter)
end

function WorldRenderer:screenToWorld(screenPos: Vector2Type): Vector2Type
    -- Reverse the world to screen transformation
    local screenCenter = Vector2.new(
        self.viewport.width / 2,
        self.viewport.height / 2
    )

    local relativePos = Vector2.subtract(screenPos, screenCenter)
    relativePos = Vector2.divide(relativePos, self.camera.zoom * self.scaleFactor)

    return Vector2.add(relativePos, self.camera.position)
end

function WorldRenderer:setCameraPosition(position: Vector2Type)
    self.camera.position = position
    self:updateAllEntityPositions()
end

function WorldRenderer:setCameraZoom(zoom: number)
    self.camera.zoom = math.clamp(zoom, 0.1, 10)
    self:updateAllEntityPositions()
    self:updateAllEntityScales()
end

function WorldRenderer:followEntity(entityId: string?, smoothing: number?)
    self.camera.followTarget = entityId
    self.camera.smoothing = smoothing or 0.1
end

function WorldRenderer:updateCamera(deltaTime: number, targetPosition: Vector2Type?)
    if self.camera.followTarget and targetPosition then
        -- Smooth camera following
        local targetCameraPos = targetPosition
        self.camera.position = Vector2.lerp(
            self.camera.position,
            targetCameraPos,
            1 - math.exp(-self.camera.smoothing * 60 * deltaTime)
        )
    end

    -- Apply camera bounds if set
    if self.camera.bounds then
        self.camera.position = Vector2.clamp(
            self.camera.position,
            Vector2.new(self.camera.bounds.x, self.camera.bounds.y),
            Vector2.new(
                self.camera.bounds.x + self.camera.bounds.width,
                self.camera.bounds.y + self.camera.bounds.height
            )
        )
    end
end

function WorldRenderer:updateAllEntityPositions()
    -- Update all entity positions based on new camera position
    -- This would be called from the game loop with actual entity positions
end

function WorldRenderer:updateAllEntityScales()
    for entityId, renderer in pairs(self.entityRenderers) do
        local currentSize = renderer.AbsoluteSize
        local scaledWidth = math.max(1, math.abs(currentSize.X * self.camera.zoom))
        local scaledHeight = math.max(1, math.abs(currentSize.Y * self.camera.zoom))

        renderer.Size = UDim2.fromOffset(scaledWidth, scaledHeight)
    end
end

function WorldRenderer:updateAllEntitySizes()
    -- Update all entity renderer sizes based on current scale factor
    -- This is needed when the viewport scale changes (e.g., window resize, fullscreen)
    for entityId, renderer in pairs(self.entityRenderers) do
        -- Get the original world size from attributes
        local worldWidth = renderer:GetAttribute("WorldWidth")
        local worldHeight = renderer:GetAttribute("WorldHeight")

        if worldWidth and worldHeight then
            local scaledWidth = math.max(1, math.abs(worldWidth * self.scaleFactor * self.camera.zoom))
            local scaledHeight = math.max(1, math.abs(worldHeight * self.scaleFactor * self.camera.zoom))
            renderer.Size = UDim2.fromOffset(scaledWidth, scaledHeight)
        end
    end
end

function WorldRenderer:performCulling(entities: {[string]: {position: Vector2Type, size: Vector2Type}})
    if not self.cullingEnabled then
        return
    end

    -- Calculate visible bounds in world space
    local screenBounds = Rectangle.new(
        -self.viewport.width / (2 * self.camera.zoom * self.scaleFactor),
        -self.viewport.height / (2 * self.camera.zoom * self.scaleFactor),
        self.viewport.width / (self.camera.zoom * self.scaleFactor),
        self.viewport.height / (self.camera.zoom * self.scaleFactor)
    )
    screenBounds = Rectangle.translate(screenBounds, self.camera.position)

    -- Expand screen bounds with margin to prevent objects from popping in/out at screen edges
    -- This keeps objects rendered slightly beyond the visible area for smooth transitions
    screenBounds = Rectangle.expand(screenBounds, self.cullingMargin)

    -- Cull entities outside visible bounds
    for entityId, entityData in pairs(entities) do
        local entityBounds = Rectangle.fromCenter(entityData.position, entityData.size)
        local isVisible = Rectangle.intersects(screenBounds, entityBounds)

        local renderer = self.entityRenderers[entityId]
        if renderer then
            renderer.Visible = isVisible
            self.visibleEntities[entityId] = isVisible
        end
    end
end

function WorldRenderer:setCullingMargin(margin: number)
    -- Set the culling margin (in world space pixels)
    -- Higher values keep objects rendered further beyond screen edges
    -- Lower values improve performance but may cause visible pop-in/pop-out
    self.cullingMargin = math.max(0, margin)
end

function WorldRenderer:setDebugMode(enabled: boolean)
    self.debugMode = enabled
    if self.debugContainer then
        self.debugContainer.Visible = enabled
    end

    -- MEMORY LEAK FIX: Clean up existing debug connection before creating new one
    if enabled then
        if not self.fpsLabel then
            self:createDebugUI()
        end
    else
        -- When disabling debug mode, clean up the debug connection
        if self.debugConnection then
            self.debugConnection:Disconnect()
            self.debugConnection = nil
        end
    end
end

function WorldRenderer:createDebugUI()
    -- FPS counter (bottom center)
    self.fpsLabel = Instance.new("TextLabel")
    self.fpsLabel.Name = "FPSCounter"
    self.fpsLabel.Size = UDim2.new(0, 200, 0, 50)
    self.fpsLabel.Position = UDim2.new(0.5, 0, 1, -70) -- Center horizontally, 70px from bottom
    self.fpsLabel.AnchorPoint = RobloxVector2.new(0.5, 1) -- Anchor from center-bottom
    self.fpsLabel.BackgroundTransparency = 0.3
    self.fpsLabel.BackgroundColor3 = Color3.new(0, 0, 0)
    self.fpsLabel.TextColor3 = Color3.new(0, 1, 0)
    self.fpsLabel.TextScaled = true
    self.fpsLabel.Font = Enum.Font.Code
    self.fpsLabel.Text = "FPS: 0"
    self.fpsLabel.Parent = self.debugContainer

    -- Entity count (above FPS counter)
    local entityCountLabel = Instance.new("TextLabel")
    entityCountLabel.Name = "EntityCount"
    entityCountLabel.Size = UDim2.new(0, 200, 0, 50)
    entityCountLabel.Position = UDim2.new(0.5, 0, 1, -130) -- Center horizontally, 130px from bottom
    entityCountLabel.AnchorPoint = RobloxVector2.new(0.5, 1) -- Anchor from center-bottom
    entityCountLabel.BackgroundTransparency = 0.3
    entityCountLabel.BackgroundColor3 = Color3.new(0, 0, 0)
    entityCountLabel.TextColor3 = Color3.new(0, 1, 0)
    entityCountLabel.TextScaled = true
    entityCountLabel.Font = Enum.Font.Code
    entityCountLabel.Text = "Entities: 0 / 0"
    entityCountLabel.Parent = self.debugContainer

    -- Update debug info
    local lastTime = tick()
    local frameCount = 0

    -- MEMORY LEAK FIX: Store debug update connection for cleanup
    self.debugConnection = RunService.Heartbeat:Connect(function()
        if not self.debugMode then
            return
        end

        frameCount = frameCount + 1
        local currentTime = tick()
        if currentTime - lastTime >= 1 then
            local fps = frameCount / (currentTime - lastTime)
            self.fpsLabel.Text = string.format("FPS: %.1f", fps)

            local visibleCount = 0
            for _, visible in pairs(self.visibleEntities) do
                if visible then
                    visibleCount = visibleCount + 1
                end
            end

            local totalCount = 0
            for _ in pairs(self.entityRenderers) do
                totalCount = totalCount + 1
            end

            entityCountLabel.Text = string.format("Entities: %d / %d", visibleCount, totalCount)

            frameCount = 0
            lastTime = currentTime
        end
    end)
end

function WorldRenderer:destroy()
    -- MEMORY LEAK FIX: Disconnect all event connections
    if self.resizeConnection then
        self.resizeConnection:Disconnect()
        self.resizeConnection = nil
    end

    if self.debugConnection then
        self.debugConnection:Disconnect()
        self.debugConnection = nil
    end

    if self.viewportFrame then
        self.viewportFrame:Destroy()
    end

    for _, animation in pairs(self.entityAnimations) do
        if animation.destroy then
            animation:destroy()
        end
    end

    self.entityRenderers = {}
    self.entityAnimations = {}
    self.layers = {}
end

return WorldRenderer