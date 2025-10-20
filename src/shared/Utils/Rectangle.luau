--!strict

local Types = require(script.Parent.Parent.Types)
type Rectangle = Types.Rectangle
type Vector2 = Types.Vector2

local Vector2 = require(script.Parent.Vector2)

local Rectangle = {}
Rectangle.__index = Rectangle

function Rectangle.new(x: number?, y: number?, width: number?, height: number?): Rectangle
    return {
        x = x or 0,
        y = y or 0,
        width = width or 0,
        height = height or 0,
    }
end

function Rectangle.fromPoints(p1: Vector2, p2: Vector2): Rectangle
    local x = math.min(p1.x, p2.x)
    local y = math.min(p1.y, p2.y)
    local width = math.abs(p2.x - p1.x)
    local height = math.abs(p2.y - p1.y)
    return Rectangle.new(x, y, width, height)
end

function Rectangle.fromCenter(center: Vector2, size: Vector2): Rectangle
    return Rectangle.new(
        center.x - size.x / 2,
        center.y - size.y / 2,
        size.x,
        size.y
    )
end

function Rectangle.getCenter(rect: Rectangle): Vector2
    return Vector2.new(
        rect.x + rect.width / 2,
        rect.y + rect.height / 2
    )
end

function Rectangle.getMin(rect: Rectangle): Vector2
    return Vector2.new(rect.x, rect.y)
end

function Rectangle.getMax(rect: Rectangle): Vector2
    return Vector2.new(rect.x + rect.width, rect.y + rect.height)
end

function Rectangle.getSize(rect: Rectangle): Vector2
    return Vector2.new(rect.width, rect.height)
end

function Rectangle.contains(rect: Rectangle, point: Vector2): boolean
    return point.x >= rect.x and
           point.x <= rect.x + rect.width and
           point.y >= rect.y and
           point.y <= rect.y + rect.height
end

function Rectangle.intersects(a: Rectangle, b: Rectangle): boolean
    return not (
        a.x > b.x + b.width or
        a.x + a.width < b.x or
        a.y > b.y + b.height or
        a.y + a.height < b.y
    )
end

function Rectangle.intersection(a: Rectangle, b: Rectangle): Rectangle?
    if not Rectangle.intersects(a, b) then
        return nil
    end

    local x = math.max(a.x, b.x)
    local y = math.max(a.y, b.y)
    local width = math.min(a.x + a.width, b.x + b.width) - x
    local height = math.min(a.y + a.height, b.y + b.height) - y

    return Rectangle.new(x, y, width, height)
end

function Rectangle.union(a: Rectangle, b: Rectangle): Rectangle
    local x = math.min(a.x, b.x)
    local y = math.min(a.y, b.y)
    local width = math.max(a.x + a.width, b.x + b.width) - x
    local height = math.max(a.y + a.height, b.y + b.height) - y

    return Rectangle.new(x, y, width, height)
end

function Rectangle.expand(rect: Rectangle, amount: number): Rectangle
    return Rectangle.new(
        rect.x - amount,
        rect.y - amount,
        rect.width + amount * 2,
        rect.height + amount * 2
    )
end

function Rectangle.translate(rect: Rectangle, offset: Vector2): Rectangle
    return Rectangle.new(
        rect.x + offset.x,
        rect.y + offset.y,
        rect.width,
        rect.height
    )
end

function Rectangle.scale(rect: Rectangle, factor: number): Rectangle
    local center = Rectangle.getCenter(rect)
    local newWidth = rect.width * factor
    local newHeight = rect.height * factor

    return Rectangle.new(
        center.x - newWidth / 2,
        center.y - newHeight / 2,
        newWidth,
        newHeight
    )
end

function Rectangle.equals(a: Rectangle, b: Rectangle, epsilon: number?): boolean
    epsilon = epsilon or 0.0001
    return math.abs(a.x - b.x) < epsilon and
           math.abs(a.y - b.y) < epsilon and
           math.abs(a.width - b.width) < epsilon and
           math.abs(a.height - b.height) < epsilon
end

function Rectangle.toScreenSpace(rect: Rectangle, screenSize: Vector2): Rectangle
    return Rectangle.new(
        rect.x * screenSize.x,
        rect.y * screenSize.y,
        rect.width * screenSize.x,
        rect.height * screenSize.y
    )
end

function Rectangle.fromScreenSpace(rect: Rectangle, screenSize: Vector2): Rectangle
    return Rectangle.new(
        rect.x / screenSize.x,
        rect.y / screenSize.y,
        rect.width / screenSize.x,
        rect.height / screenSize.y
    )
end

return Rectangle