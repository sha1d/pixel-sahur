--!strict

local Types = require(script.Parent.Parent.Types)
type Vector2 = Types.Vector2

local Vector2 = {}
Vector2.__index = Vector2

function Vector2.new(x: number?, y: number?): Vector2
    return {
        x = x or 0,
        y = y or 0,
    }
end

function Vector2.fromUDim2(udim2: UDim2): Vector2
    return Vector2.new(udim2.X.Offset, udim2.Y.Offset)
end

function Vector2.toUDim2(v: Vector2, scaleX: number?, scaleY: number?): UDim2
    return UDim2.new(scaleX or 0, v.x, scaleY or 0, v.y)
end

function Vector2.add(a: Vector2, b: Vector2): Vector2
    return Vector2.new(a.x + b.x, a.y + b.y)
end

function Vector2.subtract(a: Vector2, b: Vector2): Vector2
    return Vector2.new(a.x - b.x, a.y - b.y)
end

function Vector2.multiply(v: Vector2, scalar: number): Vector2
    return Vector2.new(v.x * scalar, v.y * scalar)
end

function Vector2.scale(a: Vector2, b: Vector2): Vector2
    -- Component-wise multiplication
    return Vector2.new(a.x * b.x, a.y * b.y)
end

function Vector2.divide(v: Vector2, scalar: number): Vector2
    if scalar == 0 then
        return Vector2.new(0, 0)
    end
    return Vector2.new(v.x / scalar, v.y / scalar)
end

function Vector2.dot(a: Vector2, b: Vector2): number
    return a.x * b.x + a.y * b.y
end

function Vector2.length(v: Vector2): number
    return math.sqrt(v.x * v.x + v.y * v.y)
end

function Vector2.lengthSquared(v: Vector2): number
    return v.x * v.x + v.y * v.y
end

function Vector2.normalize(v: Vector2): Vector2
    local len = Vector2.length(v)
    if len == 0 then
        return Vector2.new(0, 0)
    end
    return Vector2.divide(v, len)
end

function Vector2.distance(a: Vector2, b: Vector2): number
    local diff = Vector2.subtract(b, a)
    return Vector2.length(diff)
end

function Vector2.lerp(a: Vector2, b: Vector2, t: number): Vector2
    return Vector2.new(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t
    )
end

function Vector2.angle(v: Vector2): number
    return math.atan2(v.y, v.x)
end

function Vector2.rotate(v: Vector2, angle: number): Vector2
    local cos = math.cos(angle)
    local sin = math.sin(angle)
    return Vector2.new(
        v.x * cos - v.y * sin,
        v.x * sin + v.y * cos
    )
end

function Vector2.clamp(v: Vector2, min: Vector2, max: Vector2): Vector2
    return Vector2.new(
        math.clamp(v.x, min.x, max.x),
        math.clamp(v.y, min.y, max.y)
    )
end

function Vector2.equals(a: Vector2, b: Vector2, epsilon: number?): boolean
    epsilon = epsilon or 0.0001
    return math.abs(a.x - b.x) < epsilon and math.abs(a.y - b.y) < epsilon
end

function Vector2.zero(): Vector2
    return Vector2.new(0, 0)
end

function Vector2.one(): Vector2
    return Vector2.new(1, 1)
end

function Vector2.up(): Vector2
    return Vector2.new(0, -1)
end

function Vector2.down(): Vector2
    return Vector2.new(0, 1)
end

function Vector2.left(): Vector2
    return Vector2.new(-1, 0)
end

function Vector2.right(): Vector2
    return Vector2.new(1, 0)
end

return Vector2