--!strict

export type Vector2 = {x: number, y: number}
export type Rectangle = {x: number, y: number, width: number, height: number}
export type Color = {r: number, g: number, b: number, a: number?}

export type EntityId = string
export type ComponentType = string

export type Entity = {
    id: EntityId,
    components: {[ComponentType]: any}, -- Components can be any specific component type
    active: boolean,
}

export type Component = {
    type: ComponentType,
    entity: EntityId?,
}

export type Transform = Component & {
    position: Vector2,
    rotation: number,
    scale: Vector2,
    zIndex: number,
}

export type Sprite = Component & {
    imageId: string,
    size: Vector2,
    offset: Vector2,
    color: Color3,
    transparency: number,
    flipX: boolean,
    flipY: boolean,
}

export type AnimationFrame = {
    x: number,
    y: number,
    width: number,
    height: number,
    duration: number,
}

export type Animation = {
    name: string,
    frames: {AnimationFrame},
    loop: boolean,
    speed: number,
}

export type AnimationController = Component & {
    spriteSheetId: string,
    animations: {[string]: Animation},
    currentAnimation: string?,
    currentFrame: number,
    frameTime: number,
    playing: boolean,
}

export type Hitbox = Component & {
    size: Vector2,
    offset: Vector2,
    isTrigger: boolean,
    layer: number,
    mask: number,
    debugDraw: boolean,
}

export type Physics = Component & {
    velocity: Vector2,
    acceleration: Vector2,
    mass: number,
    friction: number,
    restitution: number,
    isStatic: boolean,
}

export type CharacterState = "idle" | "walking" | "running" | "jumping" | "falling" | "attacking" | "hurt" | "dead"

export type Character = Component & {
    playerId: string,
    state: CharacterState,
    health: number,
    maxHealth: number,
    moveSpeed: number,
    jumpPower: number,
    facingDirection: "left" | "right",
    isGrounded: boolean,
    canMove: boolean,
    canJump: boolean,
}

export type Enemy = Component & {
    type: string,
    health: number,
    maxHealth: number,
    damage: number,
    moveSpeed: number,
    aggroRange: number,
}

export type AttackHitbox = Component & {
    owner: string,
    damage: number,
    knockback: Vector2,
    lifetime: number,
}

export type AI = Component & {
    behavior: string,
    target: string?,
    patrolPoints: {Vector2},
}

export type InputAction = "moveLeft" | "moveRight" | "moveUp" | "moveDown" | "jump" | "attack" | "interact" | "dash"

export type InputState = {
    [InputAction]: boolean | number,
}

export type PacketType = "playerJoin" | "playerLeave" | "playerInput" | "entityUpdate" | "entitySpawn" | "entityDespawn" | "worldState" | "action"

export type NetworkPacket = {
    type: PacketType,
    timestamp: number,
    playerId: string,
    data: any,
}

export type PlayerInput = {
    input: InputState,
    sequence: number,
    deltaTime: number,
}

export type EntityUpdate = {
    entityId: EntityId,
    position: Vector2,
    velocity: Vector2?,
    state: string?,
    health: number?,
}

export type WorldState = {
    entities: {[EntityId]: Entity},
    timestamp: number,
    sequence: number,
}

export type Camera = {
    position: Vector2,
    zoom: number,
    rotation: number,
    viewport: Rectangle,
    followTarget: EntityId?,
    smoothing: number,
    bounds: Rectangle?,
}

export type Layer = {
    name: string,
    zIndex: number,
    parallaxFactor: Vector2,
    visible: boolean,
    entities: {EntityId},
}

export type World = {
    entities: {[EntityId]: Entity},
    layers: {[string]: Layer},
    camera: Camera,
    gravity: Vector2,
    bounds: Rectangle,
}

return nil