-- Move eligible resources towards the nearest eligible player. Only native
-- collisions collect them: never grant inventory, delete pickups or set prices.
local A = {}
function A.mapHeld(game, cfg)
    if not cfg.pauseCollect then return false end
    for i=0,game:GetNumPlayers()-1 do
        if Input.IsActionPressed(ButtonAction.ACTION_MAP, Isaac.GetPlayer(i).ControllerIndex) then return true end
    end
    return false
end
local heartMethods = {[1]='CanPickRedHearts', [2]='CanPickRedHearts',
    [3]='CanPickSoulHearts', [5]='CanPickRedHearts', [6]='CanPickBlackHearts',
    [8]='CanPickSoulHearts', [11]='CanPickBoneHearts', [12]='CanPickRottenHearts'}
function A.kind(item, cfg)
    if item.Price ~= 0 or item:IsShopItem() or item.OptionsPickupIndex ~= 0
        or item.Wait > 0 or item.Timeout >= 0 or item.FrameCount < 15
        or item:IsDead() or item.EntityCollisionClass == EntityCollisionClass.ENTCOLL_NONE then return end
    local v, s = item.Variant, item.SubType
    if cfg.collectCoins and v == PickupVariant.PICKUP_COIN and s >= 1 and s <= 5 then return 'coins' end
    if cfg.collectBombs and v == PickupVariant.PICKUP_BOMB and (s == 1 or s == 2) then return 'bombs' end
    if cfg.collectKeys and v == PickupVariant.PICKUP_KEY and (s == 1 or s == 3 or s == 4) then return 'keys' end
    if cfg.collectHearts and v == PickupVariant.PICKUP_HEART then
        return heartMethods[s]
    end
end
function A.canReceive(player, kind)
    if player:IsDead() or player:IsCoopGhost() or not player:AreControlsEnabled()
        or not player:CanPickupItem() or player:GetPlayerType() == PlayerType.PLAYER_CAIN_B then return false end
    if kind == 'coins' then
        local cap = player:HasCollectible(CollectibleType.COLLECTIBLE_DEEP_POCKETS) and 999 or 99
        return player:GetNumCoins() < cap
    elseif kind == 'bombs' then return player:GetNumBombs() < 99
    elseif kind == 'keys' then return player:GetNumKeys() < 99
    else return player[kind](player) end
end
function A.new(game, getConfig, core)
    local self = {moving={}}
    function self:release(key)
        local state = self.moving[key]
        if not state then return end
        -- Do not overwrite velocity changed by the engine or another mod.
        if state.item:Exists() and state.item.InitSeed == state.seed and state.item.Velocity.X == state.last.X
            and state.item.Velocity.Y == state.last.Y then state.item.Velocity = state.before end
        self.moving[key] = nil
    end
    function self:clear()
        for key in pairs(self.moving) do self:release(key) end
    end
    function self:update(item)
        local key = GetPtrHash(item)
        local cfg, room = getConfig(), game:GetRoom()
        local kind = cfg.autoCollect and core.safeCleanup(room) and A.kind(item, cfg)
        if not kind then self:release(key); return end
        if A.mapHeld(game, cfg) then self:clear(); return end
        local nearest, distance
        for i=0,game:GetNumPlayers()-1 do
            local player = Isaac.GetPlayer(i)
            -- Keep crafting materials in place for the whole local party.
            if player:GetPlayerType() == PlayerType.PLAYER_CAIN_B then self:release(key); return end
            if A.canReceive(player, kind) then
                local d = item.Position:DistanceSquared(player.Position)
                if (cfg.collectWholeRoom or d <= cfg.collectRadius^2) and (not distance or d < distance)
                    and room:CheckLine(item.Position, player.Position, 0, 0, false, false) then
                    nearest, distance = player, d
                end
            end
        end
        if not nearest then self:release(key); return end
        local delta = nearest.Position - item.Position
        local velocity = delta:Resized(math.min(6, math.sqrt(distance)))
        -- Keep the original velocity across repeated attraction updates. A
        -- recycled entity pointer must not inherit the previous item's state.
        local old = self.moving[key]
        self.moving[key] = {item=item, seed=item.InitSeed, before=old and old.seed == item.InitSeed
            and old.before or item.Velocity, last=velocity}
        item.Velocity = velocity
    end
    function self:prune()
        for key,state in pairs(self.moving) do
            if not state.item:Exists() then self.moving[key] = nil end
        end
    end
    return self
end
return A
