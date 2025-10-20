--!strict
-- Input manager for handling player inputs across different devices

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Types = require(game.ReplicatedStorage.Shared.Types)
local Vector2 = require(game.ReplicatedStorage.Shared.Utils.Vector2)

type InputState = Types.InputState
type Vector2Type = Types.Vector2

local InputManager = {}
InputManager.__index = InputManager

export type InputBinding = {
    action: string,
    inputTypes: {Enum.KeyCode | Enum.UserInputType},
    gamepadButton: Enum.KeyCode?,
    touchButton: TextButton?,
    hold: boolean?,
    callback: ((state: boolean) -> ())?,
}

export type TouchControl = {
    button: TextButton | ImageButton,
    action: string,
    isPressed: boolean,
}

export type InputConfig = {
    deadZone: number,
    sensitivity: number,
    invertY: boolean,
    vibration: boolean,
    touchControlsEnabled: boolean,
}

function InputManager.new(config: InputConfig?)
    local self = setmetatable({}, InputManager)

    -- Configuration
    local defaultConfig = {
        deadZone = 0.2,
        sensitivity = 1,
        invertY = false,
        vibration = true,
        touchControlsEnabled = true,
    }
    self.config = config or defaultConfig

    -- Input state
    self.inputState = {
        moveLeft = false,
        moveRight = false,
        moveUp = false,
        moveDown = false,
        jump = false,
        attack = false,
        interact = false,
        dash = false,
    } :: InputState

    -- Analog input values
    self.analogInput = {
        moveX = 0,
        moveY = 0,
        lookX = 0,
        lookY = 0,
    }

    -- Input bindings
    self.bindings = {} :: {[string]: InputBinding}
    self.actionPriorities = {} :: {[string]: number}

    -- Touch controls
    self.touchControls = {} :: {[string]: TouchControl}
    self.touchGui = nil :: ScreenGui?
    self.virtualJoystick = nil :: Frame?
    self.joystickThumb = nil :: Frame?
    self.joystickActive = false
    self.joystickStartPos = Vector2.zero()
    self.joystickMaxRadius = 50

    -- Device detection
    self.currentDevice = "Keyboard" :: "Keyboard" | "Gamepad" | "Touch"
    self.gamepadConnected = false

    -- Input buffering
    self.inputBuffer = {} :: {{action: string, timestamp: number}}
    self.inputBufferTime = 0.2

    -- Callbacks
    self.onInputChanged = {} :: {[string]: (state: boolean) -> ()}
    self.onDeviceChanged = nil :: ((device: string) -> ())?

    -- Initialize
    self:initialize()

    return self
end

function InputManager:initialize()
    -- Set up default bindings
    self:setupDefaultBindings()

    -- Detect initial device
    self:detectDevice()

    -- Set up device change detection
    UserInputService.LastInputTypeChanged:Connect(function(inputType)
        self:onInputTypeChanged(inputType)
    end)

    -- Set up gamepad connection detection
    UserInputService.GamepadConnected:Connect(function(gamepad)
        self.gamepadConnected = true
        self.currentDevice = "Gamepad"
        self:onDeviceChange("Gamepad")
    end)

    UserInputService.GamepadDisconnected:Connect(function(gamepad)
        self.gamepadConnected = false
        self.currentDevice = "Keyboard"
        self:onDeviceChange("Keyboard")
    end)

    -- Set up touch controls if on mobile
    if UserInputService.TouchEnabled and self.config.touchControlsEnabled then
        self:createTouchControls()
    end

    -- Start input update loop
    self:startUpdateLoop()
end

function InputManager:setupDefaultBindings()
    -- Movement
    self:bindAction("moveLeft", {Enum.KeyCode.A, Enum.KeyCode.Left}, Enum.KeyCode.DPadLeft)
    self:bindAction("moveRight", {Enum.KeyCode.D, Enum.KeyCode.Right}, Enum.KeyCode.DPadRight)
    self:bindAction("moveUp", {Enum.KeyCode.W, Enum.KeyCode.Up}, Enum.KeyCode.DPadUp)
    self:bindAction("moveDown", {Enum.KeyCode.S, Enum.KeyCode.Down}, Enum.KeyCode.DPadDown)

    -- Actions
    self:bindAction("jump", {Enum.KeyCode.Space}, Enum.KeyCode.ButtonA)
    self:bindAction("attack", {Enum.UserInputType.MouseButton1, Enum.KeyCode.J}, Enum.KeyCode.ButtonX)
    self:bindAction("dash", {Enum.KeyCode.LeftShift}, Enum.KeyCode.ButtonB)
    self:bindAction("interact", {Enum.KeyCode.E}, Enum.KeyCode.ButtonY)

    -- Menu
    self:bindAction("pause", {Enum.KeyCode.Escape}, Enum.KeyCode.ButtonStart)
    self:bindAction("inventory", {Enum.KeyCode.Tab}, Enum.KeyCode.ButtonSelect)
end

function InputManager:bindAction(action: string, inputs: {Enum.KeyCode | Enum.UserInputType}, gamepadButton: Enum.KeyCode?, hold: boolean?)
    local binding: InputBinding = {
        action = action,
        inputTypes = inputs,
        gamepadButton = gamepadButton,
        touchButton = nil,
        hold = hold,
        callback = nil,
    }

    self.bindings[action] = binding

    -- Set up context action
    ContextActionService:BindAction(
        action,
        function(actionName, inputState, inputObject)
            self:handleInput(actionName, inputState, inputObject)
        end,
        false,
        table.unpack(inputs)
    )

    -- Bind gamepad button if provided
    if gamepadButton then
        ContextActionService:BindAction(
            action .. "_gamepad",
            function(actionName, inputState, inputObject)
                self:handleInput(action, inputState, inputObject)
            end,
            false,
            gamepadButton
        )
    end
end

function InputManager:unbindAction(action: string)
    ContextActionService:UnbindAction(action)
    ContextActionService:UnbindAction(action .. "_gamepad")
    self.bindings[action] = nil
end

function InputManager:handleInput(action: string, inputState: Enum.UserInputState, inputObject: InputObject)
    local isPressed = inputState == Enum.UserInputState.Begin
    local isReleased = inputState == Enum.UserInputState.End

    -- Update input state
    if self.inputState[action] ~= nil then
        if isPressed then
            self.inputState[action] = true
            self:bufferInput(action)
        elseif isReleased then
            self.inputState[action] = false
        end
    end

    -- Trigger callbacks
    local callback = self.onInputChanged[action]
    if callback then
        if isPressed or isReleased then
            callback(isPressed)
        end
    end

    -- Handle binding-specific callback
    local binding = self.bindings[action]
    if binding and binding.callback then
        binding.callback(isPressed)
    end
end

function InputManager:createTouchControls()
    -- Create screen GUI for touch controls
    self.touchGui = Instance.new("ScreenGui")
    self.touchGui.Name = "TouchControls"
    self.touchGui.ResetOnSpawn = false
    self.touchGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    self.touchGui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")

    -- Create virtual joystick for movement
    self:createVirtualJoystick()

    -- Create action buttons
    self:createTouchButton("jump", UDim2.new(0.85, 0, 0.7, 0), UDim2.fromOffset(80, 80), "A")
    self:createTouchButton("attack", UDim2.new(0.85, 0, 0.55, 0), UDim2.fromOffset(60, 60), "X")
    self:createTouchButton("dash", UDim2.new(0.75, 0, 0.65, 0), UDim2.fromOffset(60, 60), "B")
    self:createTouchButton("interact", UDim2.new(0.75, 0, 0.5, 0), UDim2.fromOffset(60, 60), "Y")
end

function InputManager:createVirtualJoystick()
    if not self.touchGui then
        return
    end

    -- Joystick background
    local joystickFrame = Instance.new("Frame")
    joystickFrame.Name = "VirtualJoystick"
    joystickFrame.Size = UDim2.fromOffset(120, 120)
    joystickFrame.Position = UDim2.new(0.15, 0, 0.65, 0)
    joystickFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    joystickFrame.BackgroundColor3 = Color3.new(0.2, 0.2, 0.2)
    joystickFrame.BackgroundTransparency = 0.5
    joystickFrame.BorderSizePixel = 2
    joystickFrame.BorderColor3 = Color3.new(1, 1, 1)

    local joystickCorner = Instance.new("UICorner")
    joystickCorner.CornerRadius = UDim.new(1, 0)
    joystickCorner.Parent = joystickFrame

    joystickFrame.Parent = self.touchGui
    self.virtualJoystick = joystickFrame

    -- Joystick thumb
    local thumb = Instance.new("Frame")
    thumb.Name = "Thumb"
    thumb.Size = UDim2.fromOffset(40, 40)
    thumb.Position = UDim2.fromScale(0.5, 0.5)
    thumb.AnchorPoint = Vector2.new(0.5, 0.5)
    thumb.BackgroundColor3 = Color3.new(0.8, 0.8, 0.8)
    thumb.BorderSizePixel = 0

    local thumbCorner = Instance.new("UICorner")
    thumbCorner.CornerRadius = UDim.new(1, 0)
    thumbCorner.Parent = thumb

    thumb.Parent = joystickFrame
    self.joystickThumb = thumb

    -- Set up joystick input handling
    local function onTouchStart(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            local touchPos = Vector2.new(input.Position.X, input.Position.Y)
            local joystickPos = Vector2.new(
                joystickFrame.AbsolutePosition.X + joystickFrame.AbsoluteSize.X / 2,
                joystickFrame.AbsolutePosition.Y + joystickFrame.AbsoluteSize.Y / 2
            )

            local distance = Vector2.distance(touchPos, joystickPos)
            if distance <= self.joystickMaxRadius + 20 then
                self.joystickActive = true
                self.joystickStartPos = joystickPos
            end
        end
    end

    local function onTouchMove(input)
        if self.joystickActive and input.UserInputType == Enum.UserInputType.Touch then
            local touchPos = Vector2.new(input.Position.X, input.Position.Y)
            local offset = Vector2.subtract(touchPos, self.joystickStartPos)
            local distance = Vector2.length(offset)

            -- Clamp to max radius
            if distance > self.joystickMaxRadius then
                offset = Vector2.multiply(Vector2.normalize(offset), self.joystickMaxRadius)
                distance = self.joystickMaxRadius
            end

            -- Update thumb position
            thumb.Position = UDim2.new(
                0.5, offset.x,
                0.5, offset.y
            )

            -- Update analog input
            self.analogInput.moveX = offset.x / self.joystickMaxRadius
            self.analogInput.moveY = offset.y / self.joystickMaxRadius

            -- Update digital input based on analog values
            self.inputState.moveLeft = self.analogInput.moveX < -self.config.deadZone
            self.inputState.moveRight = self.analogInput.moveX > self.config.deadZone
            self.inputState.moveUp = self.analogInput.moveY < -self.config.deadZone
            self.inputState.moveDown = self.analogInput.moveY > self.config.deadZone
        end
    end

    local function onTouchEnd(input)
        if self.joystickActive and input.UserInputType == Enum.UserInputType.Touch then
            self.joystickActive = false

            -- Reset thumb position
            thumb.Position = UDim2.fromScale(0.5, 0.5)

            -- Reset analog input
            self.analogInput.moveX = 0
            self.analogInput.moveY = 0

            -- Reset digital input
            self.inputState.moveLeft = false
            self.inputState.moveRight = false
            self.inputState.moveUp = false
            self.inputState.moveDown = false
        end
    end

    UserInputService.InputBegan:Connect(onTouchStart)
    UserInputService.InputChanged:Connect(onTouchMove)
    UserInputService.InputEnded:Connect(onTouchEnd)
end

function InputManager:createTouchButton(action: string, position: UDim2, size: UDim2, label: string)
    if not self.touchGui then
        return
    end

    local button = Instance.new("TextButton")
    button.Name = action .. "Button"
    button.Size = size
    button.Position = position
    button.AnchorPoint = Vector2.new(0.5, 0.5)
    button.BackgroundColor3 = Color3.new(0.3, 0.3, 0.3)
    button.BackgroundTransparency = 0.3
    button.BorderSizePixel = 2
    button.BorderColor3 = Color3.new(1, 1, 1)
    button.Text = label
    button.TextColor3 = Color3.new(1, 1, 1)
    button.TextScaled = true
    button.Font = Enum.Font.SourceSansBold

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.2, 0)
    corner.Parent = button

    button.Parent = self.touchGui

    -- Set up button input handling
    button.MouseButton1Down:Connect(function()
        self.inputState[action] = true
        button.BackgroundTransparency = 0
        self:bufferInput(action)

        local callback = self.onInputChanged[action]
        if callback then
            callback(true)
        end
    end)

    button.MouseButton1Up:Connect(function()
        self.inputState[action] = false
        button.BackgroundTransparency = 0.3

        local callback = self.onInputChanged[action]
        if callback then
            callback(false)
        end
    end)

    self.touchControls[action] = {
        button = button,
        action = action,
        isPressed = false,
    }
end

function InputManager:detectDevice()
    if UserInputService.TouchEnabled then
        self.currentDevice = "Touch"
    elseif UserInputService.GamepadEnabled then
        self.currentDevice = "Gamepad"
    else
        self.currentDevice = "Keyboard"
    end
end

function InputManager:onInputTypeChanged(inputType: Enum.UserInputType)
    local newDevice = self.currentDevice

    if inputType == Enum.UserInputType.Touch then
        newDevice = "Touch"
    elseif inputType == Enum.UserInputType.Gamepad1 then
        newDevice = "Gamepad"
    elseif inputType == Enum.UserInputType.Keyboard or inputType == Enum.UserInputType.MouseButton1 then
        newDevice = "Keyboard"
    end

    if newDevice ~= self.currentDevice then
        self.currentDevice = newDevice
        self:onDeviceChange(newDevice)
    end
end

function InputManager:onDeviceChange(device: string)
    -- Show/hide touch controls based on device
    if self.touchGui then
        self.touchGui.Enabled = device == "Touch"
    end

    -- Trigger callback
    if self.onDeviceChanged then
        self.onDeviceChanged(device)
    end
end

function InputManager:startUpdateLoop()
    RunService.Heartbeat:Connect(function(deltaTime)
        -- Update gamepad analog sticks
        if self.currentDevice == "Gamepad" then
            self:updateGamepadInput()
        end

        -- Process input buffer
        self:processInputBuffer()
    end)
end

function InputManager:updateGamepadInput()
    local gamepad = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)

    for _, input in ipairs(gamepad) do
        -- Left stick for movement
        if input.KeyCode == Enum.KeyCode.Thumbstick1 then
            local x = input.Position.X
            local y = input.Position.Y

            -- Apply dead zone
            if math.abs(x) < self.config.deadZone then
                x = 0
            end
            if math.abs(y) < self.config.deadZone then
                y = 0
            end

            self.analogInput.moveX = x
            self.analogInput.moveY = y

            -- Update digital movement
            self.inputState.moveLeft = x < -self.config.deadZone
            self.inputState.moveRight = x > self.config.deadZone
            self.inputState.moveUp = y > self.config.deadZone
            self.inputState.moveDown = y < -self.config.deadZone

        -- Right stick for camera/aiming
        elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
            local x = input.Position.X
            local y = input.Position.Y

            -- Apply dead zone
            if math.abs(x) < self.config.deadZone then
                x = 0
            end
            if math.abs(y) < self.config.deadZone then
                y = 0
            end

            self.analogInput.lookX = x * self.config.sensitivity
            self.analogInput.lookY = y * self.config.sensitivity * (self.config.invertY and -1 or 1)
        end
    end
end

function InputManager:bufferInput(action: string)
    table.insert(self.inputBuffer, {
        action = action,
        timestamp = tick(),
    })

    -- Clean old inputs
    local currentTime = tick()
    for i = #self.inputBuffer, 1, -1 do
        if currentTime - self.inputBuffer[i].timestamp > self.inputBufferTime then
            table.remove(self.inputBuffer, i)
        end
    end
end

function InputManager:processInputBuffer()
    -- This is handled by the character controller
    -- But we keep the buffer for combo detection and other uses
end

function InputManager:isActionPressed(action: string): boolean
    return self.inputState[action] == true
end

function InputManager:getAnalogInput(): {moveX: number, moveY: number, lookX: number, lookY: number}
    return self.analogInput
end

function InputManager:onAction(action: string, callback: (state: boolean) -> ())
    self.onInputChanged[action] = callback
end

function InputManager:vibrate(duration: number?, intensity: number?)
    if not self.config.vibration or not self.gamepadConnected then
        return
    end

    duration = duration or 0.1
    intensity = intensity or 0.5

    -- Haptic feedback for gamepad
    pcall(function()
        local haptic = Enum.VibrationMotor.Large
        UserInputService:SetMotor(Enum.UserInputType.Gamepad1, haptic, intensity)

        task.wait(duration)

        UserInputService:SetMotor(Enum.UserInputType.Gamepad1, haptic, 0)
    end)
end

function InputManager:destroy()
    -- Unbind all actions
    for action, _ in pairs(self.bindings) do
        self:unbindAction(action)
    end

    -- Clean up touch controls
    if self.touchGui then
        self.touchGui:Destroy()
        self.touchGui = nil
    end

    -- Clear callbacks
    self.onInputChanged = {}
end

return InputManager