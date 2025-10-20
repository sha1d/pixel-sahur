--!strict

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Parent.Types)

type Entity = Types.Entity
type Component = Types.Component
type EntityId = Types.EntityId
type ComponentType = Types.ComponentType

local EntityManager = {}
EntityManager.__index = EntityManager

export type System = {
    name: string,
    priority: number,
    requiredComponents: {ComponentType},
    enabled: boolean,
    init: ((self: System, entityManager: EntityManager) -> ())?,
    update: ((self: System, entityManager: EntityManager, entities: {Entity}, deltaTime: number) -> ()),
    onEntityAdded: ((self: System, entity: Entity) -> ())?,
    onEntityRemoved: ((self: System, entity: Entity) -> ())?,
    onComponentAdded: ((self: System, entity: Entity, component: Component) -> ())?,
    onComponentRemoved: ((self: System, entity: Entity, component: Component) -> ())?,
}

export type ComponentFactory = (entityId: EntityId, data: any?) -> Component

function EntityManager.new()
    local self = setmetatable({}, EntityManager)

    -- Entity storage
    self.entities = {} :: {[EntityId]: Entity}
    self.entityCount = 0

    -- Component storage (for fast queries)
    self.componentsByType = {} :: {[ComponentType]: {[EntityId]: Component}}

    -- System management
    self.systems = {} :: {System}
    self.systemsByName = {} :: {[string]: System}
    self.systemEntities = {} :: {[System]: {[EntityId]: Entity}} -- Cache entities for each system

    -- Component factories
    self.componentFactories = {} :: {[ComponentType]: ComponentFactory}

    -- Entity archetypes (templates)
    self.archetypes = {} :: {[string]: {components: {[ComponentType]: any}}}

    -- Event callbacks
    self.onEntityCreated = {} :: {(entity: Entity) -> ()}
    self.onEntityDestroyed = {} :: {(entityId: EntityId) -> ()}
    self.onComponentAdded = {} :: {(entity: Entity, component: Component) -> ()}
    self.onComponentRemoved = {} :: {(entity: Entity, componentType: ComponentType) -> ()}

    -- Performance monitoring
    self.debug = false
    self.systemPerformance = {} :: {[string]: {time: number, calls: number}}

    return self
end

function EntityManager:createEntity(id: EntityId?): Entity
    local entityId = id or HttpService:GenerateGUID(false)

    local entity: Entity = {
        id = entityId,
        components = {},
        active = true,
    }

    self.entities[entityId] = entity
    self.entityCount = self.entityCount + 1

    -- Trigger callbacks
    for _, callback in ipairs(self.onEntityCreated) do
        callback(entity)
    end

    -- Notify systems
    for _, system in ipairs(self.systems) do
        if system.onEntityAdded then
            system:onEntityAdded(entity)
        end
    end

    return entity
end

function EntityManager:destroyEntity(entityId: EntityId)
    local entity = self.entities[entityId]
    if not entity then
        return
    end

    -- Remove all components
    for componentType, _ in pairs(entity.components) do
        self:removeComponent(entityId, componentType)
    end

    -- Notify systems
    for _, system in ipairs(self.systems) do
        if system.onEntityRemoved then
            system:onEntityRemoved(entity)
        end

        -- Remove from system cache
        if self.systemEntities[system] then
            self.systemEntities[system][entityId] = nil
        end
    end

    -- Trigger callbacks
    for _, callback in ipairs(self.onEntityDestroyed) do
        callback(entityId)
    end

    -- Remove entity
    self.entities[entityId] = nil
    self.entityCount = self.entityCount - 1
end

function EntityManager:getEntity(entityId: EntityId): Entity?
    return self.entities[entityId]
end

function EntityManager:getAllEntities(): {Entity}
    local entities = {}
    for _, entity in pairs(self.entities) do
        table.insert(entities, entity)
    end
    return entities
end

function EntityManager:addComponent(entityId: EntityId, componentType: ComponentType, componentData: any?): Component?
    local entity = self.entities[entityId]
    if not entity then
        warn("Entity not found:", entityId)
        return nil
    end

    -- Check if component already exists
    if entity.components[componentType] then
        warn("Component already exists:", componentType, "on entity:", entityId)
        return entity.components[componentType]
    end

    -- Create component using factory if available
    local component: Component
    local factory = self.componentFactories[componentType]
    if factory then
        component = factory(entityId, componentData)
    else
        -- Default component creation
        component = {
            type = componentType,
            entity = entityId,
        }
        -- Merge component data
        if componentData then
            for key, value in pairs(componentData) do
                component[key] = value
            end
        end
    end

    -- Add to entity
    entity.components[componentType] = component

    -- Add to component index
    if not self.componentsByType[componentType] then
        self.componentsByType[componentType] = {}
    end
    self.componentsByType[componentType][entityId] = component

    -- Update system caches
    self:updateSystemCaches(entity)

    -- Trigger callbacks
    for _, callback in ipairs(self.onComponentAdded) do
        callback(entity, component)
    end

    -- Notify systems
    for _, system in ipairs(self.systems) do
        if system.onComponentAdded then
            system:onComponentAdded(entity, component)
        end
    end

    return component
end

function EntityManager:removeComponent(entityId: EntityId, componentType: ComponentType)
    local entity = self.entities[entityId]
    if not entity then
        return
    end

    local component = entity.components[componentType]
    if not component then
        return
    end

    -- Notify systems before removal
    for _, system in ipairs(self.systems) do
        if system.onComponentRemoved then
            system:onComponentRemoved(entity, component)
        end
    end

    -- Remove from entity
    entity.components[componentType] = nil

    -- Remove from component index
    if self.componentsByType[componentType] then
        self.componentsByType[componentType][entityId] = nil
    end

    -- Update system caches
    self:updateSystemCaches(entity)

    -- Trigger callbacks
    for _, callback in ipairs(self.onComponentRemoved) do
        callback(entity, componentType)
    end
end

function EntityManager:getComponent(entityId: EntityId, componentType: ComponentType): Component?
    local entity = self.entities[entityId]
    if not entity then
        return nil
    end
    return entity.components[componentType]
end

function EntityManager:hasComponent(entityId: EntityId, componentType: ComponentType): boolean
    local entity = self.entities[entityId]
    if not entity then
        return false
    end
    return entity.components[componentType] ~= nil
end

function EntityManager:getComponents(entityId: EntityId, componentTypes: {ComponentType}): {Component}?
    local entity = self.entities[entityId]
    if not entity then
        return nil
    end

    local components = {}
    for _, componentType in ipairs(componentTypes) do
        local component = entity.components[componentType]
        if not component then
            return nil -- Entity doesn't have all required components
        end
        table.insert(components, component)
    end

    return components
end

function EntityManager:queryEntities(componentTypes: {ComponentType}): {Entity}
    local results = {}

    for _, entity in pairs(self.entities) do
        local hasAll = true
        for _, componentType in ipairs(componentTypes) do
            if not entity.components[componentType] then
                hasAll = false
                break
            end
        end

        if hasAll then
            table.insert(results, entity)
        end
    end

    return results
end

function EntityManager:queryComponents(componentType: ComponentType): {[EntityId]: Component}
    return self.componentsByType[componentType] or {}
end

function EntityManager:registerComponentFactory(componentType: ComponentType, factory: ComponentFactory)
    self.componentFactories[componentType] = factory
end

function EntityManager:registerArchetype(name: string, components: {[ComponentType]: any})
    self.archetypes[name] = {
        components = components,
    }
end

function EntityManager:createFromArchetype(archetypeName: string, id: EntityId?): Entity?
    local archetype = self.archetypes[archetypeName]
    if not archetype then
        warn("Archetype not found:", archetypeName)
        return nil
    end

    local entity = self:createEntity(id)

    for componentType, componentData in pairs(archetype.components) do
        self:addComponent(entity.id, componentType, componentData)
    end

    return entity
end

function EntityManager:registerSystem(system: System)
    table.insert(self.systems, system)
    self.systemsByName[system.name] = system

    -- Initialize system cache
    self.systemEntities[system] = {}

    -- Sort systems by priority
    table.sort(self.systems, function(a, b)
        return a.priority < b.priority
    end)

    -- Initialize system
    if system.init then
        system:init(self)
    end

    -- Cache existing entities for this system
    for _, entity in pairs(self.entities) do
        if self:entityMatchesSystem(entity, system) then
            self.systemEntities[system][entity.id] = entity
        end
    end
end

function EntityManager:unregisterSystem(systemName: string)
    local system = self.systemsByName[systemName]
    if not system then
        return
    end

    -- Remove from systems list
    for i, s in ipairs(self.systems) do
        if s == system then
            table.remove(self.systems, i)
            break
        end
    end

    -- Clean up references
    self.systemsByName[systemName] = nil
    self.systemEntities[system] = nil
end

function EntityManager:getSystem(systemName: string): System?
    return self.systemsByName[systemName]
end

function EntityManager:setSystemEnabled(systemName: string, enabled: boolean)
    local system = self.systemsByName[systemName]
    if system then
        system.enabled = enabled
    end
end

function EntityManager:entityMatchesSystem(entity: Entity, system: System): boolean
    if not entity.active then
        return false
    end

    for _, componentType in ipairs(system.requiredComponents) do
        if not entity.components[componentType] then
            return false
        end
    end

    return true
end

function EntityManager:updateSystemCaches(entity: Entity)
    for _, system in ipairs(self.systems) do
        local matches = self:entityMatchesSystem(entity, system)
        local cached = self.systemEntities[system][entity.id] ~= nil

        if matches and not cached then
            -- Add to cache
            self.systemEntities[system][entity.id] = entity
        elseif not matches and cached then
            -- Remove from cache
            self.systemEntities[system][entity.id] = nil
        end
    end
end

function EntityManager:update(deltaTime: number)
    for _, system in ipairs(self.systems) do
        if system.enabled then
            local entities = {}
            for _, entity in pairs(self.systemEntities[system]) do
                if entity.active then
                    table.insert(entities, entity)
                end
            end

            if #entities > 0 then
                local startTime = if self.debug then tick() else 0

                system:update(self, entities, deltaTime)

                if self.debug then
                    local elapsed = tick() - startTime
                    if not self.systemPerformance[system.name] then
                        self.systemPerformance[system.name] = {time = 0, calls = 0}
                    end
                    self.systemPerformance[system.name].time += elapsed
                    self.systemPerformance[system.name].calls += 1
                end
            end
        end
    end
end

function EntityManager:getDebugInfo(): string
    if not self.debug then
        return "Debug mode disabled"
    end

    local info = string.format("Entities: %d\n", self.entityCount)
    info = info .. "Systems Performance:\n"

    for systemName, perf in pairs(self.systemPerformance) do
        local avgTime = if perf.calls > 0 then perf.time / perf.calls * 1000 else 0
        info = info .. string.format("  %s: %.2fms avg (%d calls)\n", systemName, avgTime, perf.calls)
    end

    return info
end

function EntityManager:resetDebugInfo()
    self.systemPerformance = {}
end

function EntityManager:setDebug(enabled: boolean)
    self.debug = enabled
    if not enabled then
        self:resetDebugInfo()
    end
end

function EntityManager:clear()
    -- Destroy all entities
    for entityId, _ in pairs(self.entities) do
        self:destroyEntity(entityId)
    end

    -- Clear caches
    self.componentsByType = {}
    self.systemEntities = {}
    for _, system in ipairs(self.systems) do
        self.systemEntities[system] = {}
    end

    -- Reset debug info
    self:resetDebugInfo()
end

function EntityManager:destroy()
    self:clear()

    -- Clean up systems
    self.systems = {}
    self.systemsByName = {}
    self.systemEntities = {}

    -- Clean up callbacks
    self.onEntityCreated = {}
    self.onEntityDestroyed = {}
    self.onComponentAdded = {}
    self.onComponentRemoved = {}
end

return EntityManager