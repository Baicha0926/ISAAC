-- Ask the native game to open brown and opt-in gold chests with native loot.
local S = {}
function S.eligible(item,cfg)
    return (item.Variant == PickupVariant.PICKUP_CHEST
        or (cfg and cfg.smartGoldChests and item.Variant == PickupVariant.PICKUP_LOCKEDCHEST))
        and item.SubType == ChestSubType.CHEST_CLOSED
        and item:Exists() and not item:IsDead() and item.Price == 0 and not item:IsShopItem()
        and item.OptionsPickupIndex == 0 and item.Timeout < 0 and item.Wait <= 0
        and item.FrameCount >= 15 and item.EntityCollisionClass ~= EntityCollisionClass.ENTCOLL_NONE
        and item:GetSprite():IsPlaying('Idle')
end
function S.goldCost(player,cfg)
    -- Pay to Play changes the payment resource; leave those decisions manual.
    if player:HasCollectible(CollectibleType.COLLECTIBLE_PAY_TO_PLAY) then return end
    if player:HasGoldenKey() or player:HasTrinket(TrinketType.TRINKET_PAPER_CLIP) then return 0 end
    if player:GetNumKeys() > cfg.chestKeyReserve then return 1 end
end
function S.new(game, getConfig, core, mapHeld)
    local self = {attempts={},opening=false}
    function self:clear() self.attempts={} end
    function self:update(item)
        local cfg, room = getConfig(), game:GetRoom()
        local gold=item.Variant==PickupVariant.PICKUP_LOCKEDCHEST
        local enabled=(gold and cfg.smartGoldChests) or (not gold and cfg.smartChests)
        if self.opening or not enabled or not core.safeCleanup(room) or not S.eligible(item,cfg) then return end
        -- A clear challenge room may start its waves only after a chest opens.
        if room:GetType() == RoomType.ROOM_CHALLENGE then return end
        if mapHeld(game, cfg) then return end
        local nearest, distance, cost
        for i=0,game:GetNumPlayers()-1 do
            local player = Isaac.GetPlayer(i)
            -- Preserve the crafting decisions of the whole local party.
            if player:GetPlayerType() == PlayerType.PLAYER_CAIN_B then return end
            if not player:IsDead() and not player:IsCoopGhost() and player:AreControlsEnabled()
                and player:CanPickupItem() then
                local d = item.Position:DistanceSquared(player.Position)
                local payment=0
                if gold then payment=S.goldCost(player,cfg) end
                -- A free opener takes priority over a nearer opener spending keys.
                if payment and (cfg.chestWholeRoom or d <= cfg.chestRadius^2)
                    and (not nearest or payment<cost or (payment==cost and d<distance))
                    and room:CheckLine(item.Position, player.Position, 0, 0, false, false) then
                    nearest, distance, cost = player, d, payment
                end
            end
        end
        if not nearest then return end
        local key, frame = GetPtrHash(item), game:GetFrameCount()
        local state = self.attempts[key]
        if state and state.seed == item.InitSeed then
            if state.done or (frame >= state.frame and frame-state.frame < 15) then return end
        end
        -- Record before entering the engine; it can spawn pickups and callbacks.
        local attempt = {item=item,seed=item.InitSeed,frame=frame,done=true}
        self.attempts[key] = attempt
        local before=gold and nearest:GetNumKeys()
        self.opening=true
        local ok,result=pcall(function()
            local opened=item:TryOpenChest(nearest)==true
            -- TryOpenChest is an opening API, not a documented payment contract.
            -- Charge one key if a successful paid request did not debit one.
            -- Never deduct again after a native debit or for a failed request.
            if opened and gold and cost==1 and nearest:GetNumKeys()>=before then nearest:AddKeys(-1) end
            return opened
        end)
        attempt.done=ok and result==true
        self.opening=false
        if not ok then Isaac.DebugString('[Baicha QoL] chest request failed: '..tostring(result)) end
    end
    function self:prune()
        for key,state in pairs(self.attempts) do
            if not state.item:Exists() or state.item.InitSeed ~= state.seed
                or (state.item.Variant ~= PickupVariant.PICKUP_CHEST and state.item.Variant ~= PickupVariant.PICKUP_LOCKEDCHEST)
                or state.item.SubType ~= ChestSubType.CHEST_CLOSED then self.attempts[key]=nil end
        end
    end
    return self
end
return S
