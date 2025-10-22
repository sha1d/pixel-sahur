--!strict

local RunService = game:GetService("RunService")

-- Save reference to Roblox Vector2 before importing custom types
local RobloxVector2 = Vector2

local Types = require(script.Parent.Parent.Types)

type AnimationFrame = Types.AnimationFrame
type Animation = Types.Animation
type Vector2 = Types.Vector2

local AnimationController = {}
AnimationController.__index = AnimationController

export type AnimationData = {
    name: string,
    spriteSheet: string, -- Asset ID for the sprite sheet
    frameSize: Vector2, -- Size of each frame in pixels
    frames: {AnimationFrame}, -- List of frames
    loop: boolean,
    speed: number, -- Playback speed multiplier
    priority: number?, -- Animation priority for blending
}

export type AnimationState = {
    animation: AnimationData,
    currentFrame: number,
    frameTime: number,
    playing: boolean,
    finished: boolean,
    onComplete: (() -> ())?,
}

function AnimationController.new(imageLabel: ImageLabel)
    local self = setmetatable({}, AnimationController)

    self.imageLabel = imageLabel
    self.animations = {} :: {[string]: AnimationData}
    self.currentState = nil :: AnimationState?
    self.queuedAnimation = nil :: string?

    -- Animation blending
    self.blendTime = 0.1
    self.isBlending = false
    self.blendProgress = 0

    -- Events
    self.onAnimationEnd = nil :: ((animationName: string) -> ())?
    self.onFrameChange = nil :: ((animationName: string, frameIndex: number) -> ())?

    -- Start update loop
    self.connection = nil :: RBXScriptConnection?
    self:startUpdateLoop()

    return self
end

function AnimationController:registerAnimation(animationData: AnimationData)
    self.animations[animationData.name] = animationData
end

function AnimationController:registerAnimationsFromConfig(config: {
    spriteSheet: string,
    frameSize: Vector2,
    animations: {[string]: {
        frames: {{x: number, y: number, duration: number?}},
        loop: boolean?,
        speed: number?,
        priority: number?,
    }}
})
    for name, animData in pairs(config.animations) do
        local frames = {}
        for _, frameData in ipairs(animData.frames) do
            table.insert(frames, {
                x = frameData.x,
                y = frameData.y,
                width = config.frameSize.x,
                height = config.frameSize.y,
                duration = frameData.duration or 0.1,
            })
        end

        self:registerAnimation({
            name = name,
            spriteSheet = config.spriteSheet,
            frameSize = config.frameSize,
            frames = frames,
            loop = (if animData.loop ~= nil then animData.loop else true),
            speed = animData.speed or 1,
            priority = animData.priority,
        })
    end
end

function AnimationController:play(animationName: string, forceRestart: boolean?, onComplete: (() -> ())?)
    local animation = self.animations[animationName]
    if not animation then
        warn("Animation not found:", animationName)
        return
    end

    -- Check if same animation is already playing
    if self.currentState and self.currentState.animation.name == animationName and not forceRestart then
        return
    end

    -- Check animation priority
    if self.currentState and not forceRestart then
        local currentPriority = self.currentState.animation.priority or 0
        local newPriority = animation.priority or 0
        if newPriority < currentPriority and self.currentState.playing then
            -- Queue the animation for later
            self.queuedAnimation = animationName
            return
        end
    end

    -- Create new animation state
    self.currentState = {
        animation = animation,
        currentFrame = 1,
        frameTime = 0,
        playing = true,
        finished = false,
        onComplete = onComplete,
    }

    -- Set sprite sheet
    self.imageLabel.Image = animation.spriteSheet

    -- Update frame immediately
    self:updateFrame()
end

function AnimationController:stop()
    if self.currentState then
        self.currentState.playing = false
        self.currentState = nil
    end
end

function AnimationController:pause()
    if self.currentState then
        self.currentState.playing = false
    end
end

function AnimationController:resume()
    if self.currentState then
        self.currentState.playing = true
    end
end

function AnimationController:isPlaying(animationName: string?): boolean
    if not self.currentState or not self.currentState.playing then
        return false
    end

    if animationName then
        return self.currentState.animation.name == animationName
    end

    return true
end

function AnimationController:getCurrentAnimation(): string?
    if self.currentState then
        return self.currentState.animation.name
    end
    return nil
end

function AnimationController:setSpeed(speed: number)
    if self.currentState then
        self.currentState.animation.speed = speed
    end
end

function AnimationController:updateFrame()
    if not self.currentState then
        return
    end

    local state = self.currentState
    local animation = state.animation
    local frame = animation.frames[state.currentFrame]

    if not frame then
        return
    end

    -- Check for flip state stored as attributes
    local flipX = self.imageLabel:GetAttribute("FlipX") or false
    local flipY = self.imageLabel:GetAttribute("FlipY") or false

    -- Calculate ImageRect values based on flip state
    local offsetX = frame.x
    local offsetY = frame.y
    local sizeX = frame.width
    local sizeY = frame.height

    -- Apply horizontal flip: move offset to end of frame and use negative width
    if flipX then
        offsetX = frame.x + frame.width
        sizeX = -frame.width
    end

    -- Apply vertical flip: move offset to end of frame and use negative height
    if flipY then
        offsetY = frame.y + frame.height
        sizeY = -frame.height
    end

    -- Apply to ImageLabel using ImageRectOffset and ImageRectSize
    self.imageLabel.ImageRectOffset = RobloxVector2.new(offsetX, offsetY)
    self.imageLabel.ImageRectSize = RobloxVector2.new(sizeX, sizeY)

    -- Trigger frame change event
    if self.onFrameChange then
        self.onFrameChange(animation.name, state.currentFrame)
    end
end

function AnimationController:getSpritesheetSize(assetId: string): Vector2?
    -- This is a simplified version. In a real implementation,
    -- you would cache sprite sheet sizes or load them from metadata
    -- For now, we'll use a default size
    return Vector2.new(1024, 1024)
end

function AnimationController:startUpdateLoop()
    if self.connection then
        return
    end

    self.connection = RunService.Heartbeat:Connect(function(deltaTime)
        self:update(deltaTime)
    end)
end

function AnimationController:update(deltaTime: number)
    if not self.currentState or not self.currentState.playing then
        return
    end

    local state = self.currentState
    local animation = state.animation

    -- Update frame time
    state.frameTime = state.frameTime + (deltaTime * animation.speed)

    -- Get current frame duration
    local currentFrameData = animation.frames[state.currentFrame]
    if not currentFrameData then
        return
    end

    -- Check if we need to advance to next frame
    if state.frameTime >= currentFrameData.duration then
        state.frameTime = 0
        state.currentFrame = state.currentFrame + 1

        -- Check if animation finished
        if state.currentFrame > #animation.frames then
            if animation.loop then
                -- Loop back to first frame
                state.currentFrame = 1
                self:updateFrame()
            else
                -- Animation finished
                state.finished = true
                state.playing = false

                -- Trigger completion callback
                if state.onComplete then
                    state.onComplete()
                end

                -- Trigger animation end event
                if self.onAnimationEnd then
                    self.onAnimationEnd(animation.name)
                end

                -- Play queued animation if any
                if self.queuedAnimation then
                    local queuedName = self.queuedAnimation
                    self.queuedAnimation = nil
                    self:play(queuedName)
                else
                    self.currentState = nil
                end
            end
        else
            -- Update to next frame
            self:updateFrame()
        end
    end
end

function AnimationController:destroy()
    if self.connection then
        self.connection:Disconnect()
        self.connection = nil
    end

    self.currentState = nil
    self.animations = {}
end

-- Utility function to create animation frames from a grid
function AnimationController.createFramesFromGrid(
    startCol: number,
    startRow: number,
    frameCount: number,
    frameWidth: number,
    frameHeight: number,
    duration: number?,
    direction: "horizontal" | "vertical"?
): {AnimationFrame}
    direction = direction or "horizontal"
    duration = duration or 0.1

    local frames = {}
    local col = startCol
    local row = startRow

    for i = 1, frameCount do
        table.insert(frames, {
            x = (col - 1) * frameWidth,
            y = (row - 1) * frameHeight,
            width = frameWidth,
            height = frameHeight,
            duration = duration,
        })

        if direction == "horizontal" then
            col = col + 1
        else
            row = row + 1
        end
    end

    return frames
end

-- Utility function to create animations from a sprite sheet configuration
function AnimationController.createAnimationsFromSheet(config: {
    spriteSheet: string,
    frameWidth: number,
    frameHeight: number,
    animations: {[string]: {
        row: number,
        startCol: number,
        frameCount: number,
        duration: number?,
        loop: boolean?,
        speed: number?,
    }}
}): {[string]: AnimationData}
    local animations = {}

    for name, animConfig in pairs(config.animations) do
        local frames = AnimationController.createFramesFromGrid(
            animConfig.startCol,
            animConfig.row,
            animConfig.frameCount,
            config.frameWidth,
            config.frameHeight,
            animConfig.duration,
            "horizontal"
        )

        animations[name] = {
            name = name,
            spriteSheet = config.spriteSheet,
            frameSize = {x = config.frameWidth, y = config.frameHeight},
            frames = frames,
            loop = (if animConfig.loop ~= nil then animConfig.loop else true),
            speed = animConfig.speed or 1,
            priority = nil,
        }
    end

    return animations
end

return AnimationController