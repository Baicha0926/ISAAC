-- 奶龙替换以撒 1.4.5 local. Stable native sprite identity prevents costume frame resets.
local mod = RegisterMod("NaiLong - Milk Frog Style", 1)
local json = require("json")
local ROOT = "gfx/baicha_nailong/"
local ATLAS = ROOT .. "milkfrog_isaac.png"
local BACK_ATLAS = ROOT .. "milkfrog_isaac_back.png"
local DATA_KEY = "BaichaNaiLongSkinV1"
local BASE_LAYERS = {1, 4, 12}
local WEAPONS = {
    CollectibleType.COLLECTIBLE_BRIMSTONE,
    CollectibleType.COLLECTIBLE_TECHNOLOGY,
    CollectibleType.COLLECTIBLE_TECHNOLOGY_2,
    CollectibleType.COLLECTIBLE_TECH_5,
    CollectibleType.COLLECTIBLE_TECH_X,
    CollectibleType.COLLECTIBLE_TECHNOLOGY_ZERO,
    CollectibleType.COLLECTIBLE_SPOON_BENDER,
    CollectibleType.COLLECTIBLE_SACRED_HEART,
    CollectibleType.COLLECTIBLE_GODHEAD,
}
local WING_ID = Isaac.GetCostumeIdByPath(ROOT .. "milkfrog_wings.anm2")
local HEAD_ID = Isaac.GetCostumeIdByPath(ROOT .. "milkfrog_head.anm2")
local BODY_ID = Isaac.GetCostumeIdByPath(ROOT .. "milkfrog_body.anm2")
local FLY_BODY_ID = Isaac.GetCostumeIdByPath(ROOT .. "milkfrog_body_flying.anm2")
local roomRevision = 0
local bossRoom, completedRooms, bossSerial = nil, {}, 0
local sfx = SFXManager()
local laughSounds = {}
for duration = 15, 150, 15 do
    laughSounds[duration] = Isaac.GetSoundIdByName("BaichaNaiLongBellyLaugh_" .. duration)
end
local soundOwner, soundID, soundUntil
local defaults = {weaponFaces=true, homingEyes=true, wings=true, celebration=true, movementFacing=true,
    laughSound=true, laughVolume=55, laughFrames=150, chargeFaces=true, idleAnimation=true}
local cfg, settingsRevision, gameStarted = {}, 0, false
local ensureMenu

local function stopLaughSound(owner)
    if owner and soundOwner ~= owner then return end
    if soundID and soundID > 0 then sfx:Stop(soundID) end
    soundOwner, soundID, soundUntil = nil, nil, nil
end

local function playLaughSound(state, frame)
    if not cfg.laughSound or cfg.laughVolume <= 0 then return end
    local id = laughSounds[cfg.laughFrames]
    if not id or id <= 0 then return end
    -- Co-op players share a sound channel. A second player must not stack or
    -- cut another player's laugh; a new victory by this owner may restart it.
    if soundOwner and soundOwner ~= state and frame < soundUntil then return end
    stopLaughSound()
    sfx:Play(id, cfg.laughVolume / 100, 0, false, 1)
    soundOwner, soundID, soundUntil = state, id, frame + cfg.laughFrames
end

local function normalizeSettings(input)
    local result = {}
    input = type(input) == "table" and input or {}
    for key, value in pairs(defaults) do
        if type(value) == "boolean" then
            result[key] = type(input[key]) == "boolean" and input[key] or value
            if input[key] == false then result[key] = false end
        else
            local n = input[key]
            if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then n = value end
            if key == "laughVolume" then
                result[key] = math.max(0, math.min(100, math.floor(n / 5 + 0.5) * 5))
            else result[key] = math.max(15, math.min(150, math.floor(n / 15 + 0.5) * 15)) end
        end
    end
    return result
end
cfg = normalizeSettings()

local function changedSettings()
    stopLaughSound()
    cfg = normalizeSettings(cfg)
    settingsRevision = settingsRevision + 1
    if gameStarted then mod:SaveData(json.encode(cfg)) end
end

local function loadSettings()
    local input
    if mod:HasData() then
        local ok, value = pcall(json.decode, mod:LoadData())
        if ok then input = value end
    end
    cfg = normalizeSettings(input)
    settingsRevision = settingsRevision + 1
end

-- One shared room event for all players. Never infer victory from a single
-- NPC death or an inter-wave pause; require stable native room completion.
local function resetBossRoom()
    local game = Game()
    local level = game:GetLevel()
    local desc = level:GetCurrentRoomDesc()
    local key = table.concat({level:GetStage(), level:GetStageType(),
        desc.ListIndex, desc.SafeGridIndex, desc.SpawnSeed}, ":")
    bossRoom = {key=key, seen=false, finished=completedRooms[key] == true}
end

local function sampleBossVictory()
    if not bossRoom then resetBossRoom() end
    local frame, room = Game():GetFrameCount(), Game():GetRoom()
    if bossRoom.sampleFrame == frame then return end
    bossRoom.sampleFrame = frame
    if bossRoom.finished then return end
    local kind, bosses = room:GetType(), room:GetAliveBossesCount()
    if kind == RoomType.ROOM_MINIBOSS then return end
    if bosses > 0 then bossRoom.seen = true end
    local complete = bossRoom.seen and room:IsClear() and bosses == 0
        and room:GetAliveEnemiesCount() == 0
    if kind == RoomType.ROOM_BOSSRUSH then
        complete = complete and room:IsAmbushDone() and not room:IsAmbushActive()
    end
    if not complete then bossRoom.clearFrame = nil; return end
    bossRoom.clearFrame = bossRoom.clearFrame or frame
    if frame - bossRoom.clearFrame >= 15 then
        bossRoom.finished, completedRooms[bossRoom.key] = true, true
        bossSerial = bossSerial + 1
    end
end

local function cancelCelebration(state)
    state.pendingVictory, state.laughUntil, state.laughStarted = nil, nil, nil
    state.chargeStarted, state.chargeKind, state.fireUntil = nil, nil, nil
    stopLaughSound(state)
end

local function chargeFace(player, state, frame, available)
    if not cfg.chargeFaces or not available or not player:CanShoot()
        or not player.ControlsEnabled or player.ControlsCooldown > 0 then
        state.chargeStarted, state.chargeKind, state.fireUntil = nil, nil, nil
        return nil
    end
    local weapon
    if player:HasWeaponType(WeaponType.WEAPON_BRIMSTONE) then weapon = WeaponType.WEAPON_BRIMSTONE
    elseif player:HasWeaponType(WeaponType.WEAPON_TECH_X) then weapon = WeaponType.WEAPON_TECH_X
    elseif player:HasWeaponType(WeaponType.WEAPON_TEARS) then weapon = WeaponType.WEAPON_TEARS end
    local chocolate = player:HasCollectible(CollectibleType.COLLECTIBLE_CHOCOLATE_MILK)
        or player:GetEffects():HasCollectibleEffect(CollectibleType.COLLECTIBLE_CHOCOLATE_MILK)
    if weapon ~= WeaponType.WEAPON_BRIMSTONE and weapon ~= WeaponType.WEAPON_TECH_X
        and not (weapon == WeaponType.WEAPON_TEARS and chocolate) then
        state.chargeStarted, state.chargeKind, state.fireUntil = nil, nil, nil
        return nil
    end
    if state.chargeKind ~= weapon then
        state.chargeStarted, state.fireUntil, state.chargeKind = nil, nil, weapon
    end
    if state.fireUntil and frame < state.fireUntil then return "fire" end
    local input = player:GetShootingInput()
    if input.X * input.X + input.Y * input.Y < 0.01 then
        state.chargeStarted = nil
        return nil
    end
    state.chargeStarted = state.chargeStarted or frame
    -- Vanilla has no general charge-progress getter. This fallback estimates
    -- cosmetic stages only and never changes native charge/attack timing.
    local multiplier = weapon == WeaponType.WEAPON_TECH_X and 2 or 3
    local target = math.max(6, (player.MaxFireDelay + 1) * multiplier)
    local ratio = (frame - state.chargeStarted) / target
    -- Optional REPENTOGON support, with no mandatory extension dependency.
    if type(player.GetWeapon) == "function" then
        local ok, value = pcall(function()
            local w = player:GetWeapon(1)
            if not w then return nil end
            local maximum = w:GetMaxCharge()
            if maximum > 0 then return w:GetCharge() / maximum end
        end)
        if ok and type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge then ratio = value end
    end
    return ratio >= 0.75 and "charge_2" or "charge_1"
end

local function activeWeapons(player)
    local effects, active, mask = player:GetEffects(), {}, 0
    for index, id in ipairs(WEAPONS) do
        if player:HasCollectible(id) or effects:HasCollectibleEffect(id) then
            active[#active + 1] = id
            mask = mask | (1 << (index - 1))
        end
    end
    return active, mask
end

local function removeWeaponCostumes(player, active, state)
    local config = Isaac.GetItemConfig()
    state.hiddenCostumes = state.hiddenCostumes or {}
    for _, id in ipairs(active) do
        local item = config:GetCollectible(id)
        if item then
            player:RemoveCostume(item)
            state.hiddenCostumes[id] = true
        end
    end
end

local function restoreWeaponCostumes(player, state)
    if not state or not state.hiddenCostumes then return end
    local config, effects = Isaac.GetItemConfig(), player:GetEffects()
    for id in pairs(state.hiddenCostumes) do
        -- Restore only appearances we hid and whose item/effect still exists.
        -- AddCostume does not grant items or reapply their gameplay effects.
        if player:HasCollectible(id) or effects:HasCollectibleEffect(id) then
            local item = config:GetCollectible(id)
            if item then player:AddCostume(item, false) end
        end
    end
    state.hiddenCostumes = nil
end

local function detachWings(player, state)
    if state and state.wings and WING_ID >= 0 then
        player:TryRemoveNullCostume(WING_ID)
        state.wings = false
    end
end

local function refreshWings(player, state)
    -- A rebuild may already have removed it; removing this ID is safe either way.
    -- Do not stack copies when inventory changes but native costumes stay intact.
    detachWings(player, state)
    player:AddNullCostume(WING_ID)
    state.wings = true
end

local function detachHead(player, state)
    if state and state.headCostume and HEAD_ID >= 0 then
        player:TryRemoveNullCostume(HEAD_ID)
        state.headCostume, state.headSheet = false, nil
    end
end

local function refreshHead(player, state, head, rebuild)
    if HEAD_ID < 0 then return false end
    local item = Isaac.GetItemConfig():GetNullItem(HEAD_ID)
    if not item then return false end
    local changed = false
    if rebuild or not state.headCostume then
        -- Only our costume is rebuilt. Its head/extra layers have native pose
        -- coordinates and outrank full-head item replacements. Hat/eye/back,
        -- held-item and other accessory layers remain native.
        detachHead(player, state)
        player:AddNullCostume(HEAD_ID)
        state.headCostume = true
        changed = true
    end
    if state.headSheet ~= head then
        -- This costume deliberately has ONE sheet: the native API ignores
        -- SpriteId and would corrupt costumes containing multiple sheets.
        player:ReplaceCostumeSprite(item, head, 0)
        state.headSheet = head
        changed = true
    end
    return changed
end

local function detachBody(player, state)
    if state and state.bodyCostume then
        local id = state.bodyCostumeId or BODY_ID
        if id >= 0 then player:TryRemoveNullCostume(id) end
        state.bodyCostume, state.bodySheet, state.bodyCostumeId = false, nil, nil
    end
end

local function refreshBody(player, state, sheet, rebuild)
    -- Native flying bodies occupy a separate visual costume selection. A
    -- ground-only body cannot reliably cover an item's flying body layout.
    -- Select by native flight even when decorative wings are turned off.
    local id = player.CanFly and FLY_BODY_ID or BODY_ID
    if id < 0 then return false end
    local item = Isaac.GetItemConfig():GetNullItem(id)
    if not item then return false end
    local changed = false
    if rebuild or not state.bodyCostume or state.bodyCostumeId ~= id then
        detachBody(player, state)
        player:AddNullCostume(id)
        state.bodyCostume, changed = true, true
        state.bodyCostumeId = id
    end
    if state.bodySheet ~= sheet then
        -- Native low-resolution costumes (e.g. Pluto) use incompatible crop
        -- rectangles. Own body coordinates keep every torso pixel together.
        player:ReplaceCostumeSprite(item, sheet, 0)
        state.bodySheet, changed = sheet, true
    end
    return changed
end

local function capturePose(sprite)
    local animation, overlay = sprite:GetAnimation(), sprite:GetOverlayAnimation()
    return {animation=animation, frame=sprite:GetFrame(),
        playing=sprite:IsPlaying(animation), overlay=overlay,
        overlayFrame=sprite:GetOverlayFrame(),
        overlayPlaying=overlay ~= "" and sprite:IsOverlayPlaying(overlay),
        flipX=sprite.FlipX, flipY=sprite.FlipY, rotation=sprite.Rotation,
        scaleX=sprite.Scale.X, scaleY=sprite.Scale.Y}
end

local function inputActive(input)
    return input.X * input.X + input.Y * input.Y >= 0.01
end

local function movementLook(player, state, pose, frame, available)
    if not available then state.idleStarted = nil; return nil, nil end
    if not cfg.movementFacing then state.lookDirection = nil end
    local movement, shooting = player:GetMovementInput(), player:GetShootingInput()
    -- Zero is a settled head, not an active shot. Treating it as firing
    -- prevents movement-facing and idle when the native timer rests at zero.
    local firing = inputActive(shooting) or player.HeadFrameDelay > 0
    local controls = player.ControlsEnabled and player.ControlsCooldown <= 0
    if controls and inputActive(movement) then
        if cfg.movementFacing then
            local x, y = math.abs(movement.X), math.abs(movement.Y)
            -- A small diagonal hysteresis keeps nearly equal axes from toggling
            -- cosmetic facing. No velocity, input or native head state is written.
            local vertical = state.lookDirection == "up" or state.lookDirection == "down"
            if not state.lookDirection then vertical = y > x
            elseif vertical then vertical = y * 1.15 >= x
            else vertical = y > x * 1.15 end
            state.lookDirection = vertical and (movement.Y < 0 and "up" or "down")
                or (movement.X < 0 and "left" or "right")
        end
        state.idleStarted = nil
    elseif controls and not firing and not inputActive(player.Velocity) then
        state.idleStarted = state.idleStarted or frame
    else state.idleStarted = nil end
    if firing then return nil, nil end
    local idle
    if cfg.idleAnimation and state.idleStarted and frame - state.idleStarted >= 18 then
        local elapsed = frame - state.idleStarted - 18
        idle = {phase=math.floor(elapsed / 30) % 2, blink=elapsed % 120 >= 108 and elapsed % 120 < 112}
    end
    local direction = state.lookDirection
    if not direction and idle then
        direction = pose.overlay:match("^Head(.*)$") or pose.animation:match("^Walk(.*)$") or "Down"
        direction = direction:lower()
    end
    -- Native HeadLeft mirrors the shared side crop. Compensate in the asset,
    -- preserving all overlay frames and gameplay head/weapon direction.
    if (direction == "left" or direction == "right") and pose.overlay == "HeadLeft" then
        direction = direction == "left" and "right" or "left"
    end
    return direction, idle
end

local function restorePose(sprite, pose)
    -- Cosmetic APIs can rebuild the sprite. Restore only what this update
    -- changed; never restart or pin the native animation on unchanged frames.
    if sprite:GetAnimation() ~= pose.animation or sprite:GetFrame() ~= pose.frame
        or sprite:IsPlaying(pose.animation) ~= pose.playing then
        if pose.playing then
            -- The one-argument overload changes the frame without stopping
            -- playback. The animation-name overload is for stopped poses.
            sprite:Play(pose.animation, false)
            sprite:SetFrame(pose.frame)
        else sprite:SetFrame(pose.animation, pose.frame) end
    end
    if pose.overlay ~= "" then
        if sprite:GetOverlayAnimation() ~= pose.overlay
            or sprite:GetOverlayFrame() ~= pose.overlayFrame
            or sprite:IsOverlayPlaying(pose.overlay) ~= pose.overlayPlaying then
            sprite:SetOverlayFrame(pose.overlay, pose.overlayFrame)
            if pose.overlayPlaying then sprite:PlayOverlay(pose.overlay, false) end
        end
    elseif sprite:GetOverlayAnimation() ~= "" then sprite:RemoveOverlay() end
    if sprite.FlipX ~= pose.flipX then sprite.FlipX = pose.flipX end
    if sprite.FlipY ~= pose.flipY then sprite.FlipY = pose.flipY end
    if sprite.Rotation ~= pose.rotation then sprite.Rotation = pose.rotation end
    if sprite.Scale.X ~= pose.scaleX or sprite.Scale.Y ~= pose.scaleY then
        sprite.Scale = Vector(pose.scaleX, pose.scaleY)
    end
end

local function updateSkin(_, player)
    local data = player:GetData()
    local state = data[DATA_KEY]
    if player:GetPlayerType() ~= PlayerType.PLAYER_ISAAC or player:IsCoopGhost() then
        if state then stopLaughSound(state) end
        detachWings(player, state)
        detachHead(player, state)
        detachBody(player, state)
        restoreWeaponCostumes(player, state)
        data[DATA_KEY] = nil
        return
    end
    state = state or {}
    data[DATA_KEY] = state
    sampleBossVictory()
    local settingsChanged = state.settingsRevision ~= settingsRevision
    local roomChanged = state.roomRevision ~= roomRevision
    if settingsChanged or roomChanged then
        cancelCelebration(state)
        state.idleStarted = nil
        state.lastBossSerial = bossSerial
        state.settingsRevision = settingsRevision
    end
    local frame = Game():GetFrameCount()
    local itemCount = player:GetCollectibleCount()
    if state.lastBossSerial ~= bossSerial then
        state.lastBossSerial = bossSerial
        if cfg.celebration then state.pendingVictory = true end
    end
    -- Some items suppress the usual Hit animation. Confirm actual damage
    -- from the native counter rather than treating cancelled damage as a hit.
    local damage = player:GetTotalDamageTaken()
    local hurt = state.damageTaken ~= nil and damage > state.damageTaken
    state.damageTaken = damage
    if hurt then cancelCelebration(state) end
    if player:GetEffects():HasCollectibleEffect(CollectibleType.COLLECTIBLE_MEGA_MUSH) then
        state.idleStarted = nil
        cancelCelebration(state)
        -- The native giant form has a different full-body crop layout, even
        -- though GetSprite may still report the normal player's filename.
        detachWings(player, state)
        detachHead(player, state)
        detachBody(player, state)
        state.suspended = true
        return
    end
    local sprite = player:GetSprite()
    if not sprite or not sprite:IsLoaded() then
        state.idleStarted = nil
        cancelCelebration(state)
        detachWings(player, state)
        detachHead(player, state)
        detachBody(player, state)
        state.suspended = true
        return
    end
    local filename = sprite:GetFilename():lower():gsub("\\", "/")
    if (filename ~= "001.000_player.anm2"
        and not filename:match("/001%.000_player%.anm2$")) or sprite:GetLayerCount() ~= 15 then
        state.idleStarted = nil
        cancelCelebration(state)
        detachWings(player, state)
        detachHead(player, state)
        detachBody(player, state)
        -- Temporary full-body animations retain their native layout.
        state.suspended = true
        return
    end
    local animation = sprite:GetAnimation()
    local pose = capturePose(sprite)
    local walking = animation:match("^Walk") ~= nil
    local dead, holding = player:IsDead(), player:IsHoldingItem()
    local controlsAvailable = player.ControlsEnabled and player.ControlsCooldown <= 0
    if dead or (not walking and not holding) then cancelCelebration(state) end
    if state.laughUntil and (not walking or holding or dead or not controlsAvailable) then
        cancelCelebration(state)
    end
    -- Holding an item delays the start; interruptions end an active laugh.
    if state.pendingVictory and walking and not holding and not dead and controlsAvailable then
        state.pendingVictory = nil
        state.laughUntil, state.laughStarted = frame + cfg.laughFrames, frame
        playLaughSound(state, frame)
    end
    local laughing = cfg.celebration and walking and not holding and not dead and controlsAvailable
        and state.laughUntil and frame < state.laughUntil
    if not laughing then stopLaughSound(state) end
    local face = chargeFace(player, state, frame, walking and not holding and not dead and not hurt)
    local active, mask = activeWeapons(player)
    local brim = cfg.weaponFaces and (mask & 1) ~= 0
    local tech = cfg.weaponFaces and (mask & 62) ~= 0
    local homing = cfg.homingEyes and (mask & 448) ~= 0
    local variant = brim and (tech and "techbrim" or "brim") or (tech and "tech" or nil)
    if homing then variant = variant and ("homing_" .. variant) or "homing" end
    local head = variant and (ROOT .. "milkfrog_" .. variant .. ".png") or ATLAS
    if laughing or face == "fire" then head = variant and (ROOT .. "milkfrog_" .. variant .. "_laugh.png")
        or (ROOT .. "milkfrog_laugh.png") end
    local body = animation == "WalkUp" and BACK_ATLAS or ATLAS
    local laughPhase
    if laughing then
        local direction = animation:sub(5):lower()
        if direction == "down" or direction == "right" or direction == "up" or direction == "left" then
            local started = state.laughStarted or (state.laughUntil - cfg.laughFrames)
            local phase = math.floor((frame - started) / 5) % 2
            laughPhase = phase
            body = ROOT .. "milkfrog_belly_" .. direction .. "_" .. phase .. ".png"
            -- Keep weapon/homing faces and native aiming. The base laugh sheet
            -- contains all aim directions; torso alone follows movement facing.
            if not variant and not face then head = body end
        end
    end
    if face and face ~= "fire" then
        head = ROOT .. "milkfrog_" .. (variant or "isaac") .. "_" .. face .. ".png"
    end
    local look, idle = movementLook(player, state, pose, frame,
        walking and not holding and not dead and not hurt)
    if laughing or face then idle = nil; state.idleStarted = nil end
    if look and not face then
        local blink = idle and idle.blink and not variant and look ~= "up"
        if laughing and not variant then
            -- Use the same approved pose/phase as the belly, not the older
            -- generic laugh head with a different outline and mouth anchor.
            head = ROOT .. "milkfrog_belly_look_" .. look .. "_" .. laughPhase .. ".png"
        else
            head = ROOT .. "milkfrog_" .. (variant or "isaac") .. (laughing and "_laugh" or "") .. "_look_" .. look
                .. (blink and "_blink" or "") .. ".png"
        end
    end
    -- Body costume uses dedicated back cells in its own animation, allowing
    -- a stable costume sheet while native front/back base layers still match.
    local costumeBody = laughing and body or ATLAS
    if idle then
        costumeBody = ROOT .. "milkfrog_idle_" .. idle.phase .. ".png"
        body = ROOT .. "milkfrog_idle_" .. (animation == "WalkUp" and "back_" or "") .. idle.phase .. ".png"
    end
    local desired = {[1] = body, [4] = head, [12] = head}
    local inventoryChanged = state.itemCount ~= itemCount
    -- GetSprite may return a new Lua userdata wrapper for the same native
    -- sprite. Comparing wrappers rebuilds costumes every tick and resets
    -- their independent walk/head animation clocks. Compare native identity.
    local spriteKey = GetPtrHash(sprite)
    local costumeChanged = inventoryChanged or state.mask ~= mask or state.spriteKey ~= spriteKey
        or state.filename ~= filename
        or state.suspended or settingsChanged or state.roomRevision ~= roomRevision
        or state.canFly ~= player.CanFly
    local flying = cfg.wings and player.CanFly and WING_ID >= 0
    -- Refresh on explicit lifecycle events or an actual style change. Do not
    -- use per-frame ReplaceSpritesheet probes to decide whether costumes need
    -- re-adding: native directional sheet changes must not restart our walk.
    local rebuild = costumeChanged or state.skinDirty
    local changed = false
    if rebuild then removeWeaponCostumes(player, active, state) end
    local attachmentChanged = refreshHead(player, state, head, rebuild)
    local bodyChanged = refreshBody(player, state, costumeBody, rebuild)
    attachmentChanged = attachmentChanged or bodyChanged
    if flying and (not state.wings or rebuild) then
        refreshWings(player, state); attachmentChanged = true
    elseif not flying then
        attachmentChanged = attachmentChanged or state.wings
        detachWings(player, state)
    end
    for _, layer in ipairs(BASE_LAYERS) do
        if rebuild or attachmentChanged or not state.sheets
            or state.sheets[layer] ~= desired[layer] then
            -- Always load after a requested replacement, including older Lua
            -- runtimes with no return value. Unchanged frames make no call.
            sprite:ReplaceSpritesheet(layer, desired[layer])
            changed = true
        end
    end
    if changed then
        sprite:LoadGraphics()
        restorePose(sprite, pose)
    end
    state.skinDirty = false
    state.spriteKey, state.filename = spriteKey, filename
    state.itemCount, state.mask, state.sheets = itemCount, mask, desired
    state.suspended = false
    state.canFly = player.CanFly
    state.roomRevision = roomRevision
end

mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, updateSkin)
-- Pills and item/effect updates can replace native skin without changing the
-- collectible count. Mark an explicit recovery rather than probing each tick.
mod:AddCallback(ModCallbacks.MC_EVALUATE_CACHE, function(_, player)
    local state = player:GetData()[DATA_KEY]
    if state then state.skinDirty = true end
end)

-- Recover costume-only clearing when entering a room, rather than repeatedly
-- removing a perfectly intact head while the player is standing still.
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    roomRevision = roomRevision + 1
    stopLaughSound()
    resetBossRoom()
end)
-- A very fast boss kill can precede the first player update. Death only arms
-- observation; it never completes the fight on its own.
mod:AddCallback(ModCallbacks.MC_POST_NPC_DEATH, function(_, npc)
    if not bossRoom then resetBossRoom() end
    if npc:IsBoss() and Game():GetRoom():GetType() ~= RoomType.ROOM_MINIBOSS
        and not bossRoom.finished then bossRoom.seen = true end
end)
local function observeShot(_, entity)
    local source = entity.SpawnerEntity or entity.Parent
    local player = source and source:ToPlayer()
    if not player or player:GetPlayerType() ~= PlayerType.PLAYER_ISAAC then return end
    local state = player:GetData()[DATA_KEY]
    if state and state.chargeKind then
        local frame = Game():GetFrameCount()
        state.fireUntil, state.chargeStarted = frame + 6, frame
    end
end
mod:AddCallback(ModCallbacks.MC_POST_FIRE_TEAR, observeShot)
mod:AddCallback(ModCallbacks.MC_POST_LASER_INIT, observeShot)
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    stopLaughSound()
    gameStarted = true
    completedRooms, bossSerial = {}, 0
    resetBossRoom()
    loadSettings()
    ensureMenu()
    local game = Game()
    for index = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(index)
        detachWings(player, player:GetData()[DATA_KEY])
        detachHead(player, player:GetData()[DATA_KEY])
        detachBody(player, player:GetData()[DATA_KEY])
        restoreWeaponCostumes(player, player:GetData()[DATA_KEY])
        player:GetData()[DATA_KEY] = nil
        updateSkin(mod, player)
    end
end)

local registeredMenu
ensureMenu = function()
    local menu = ModConfigMenu
    if not menu or not menu.AddSetting or not menu.OptionType or registeredMenu == menu then return end
    registeredMenu = menu
    local category = "NaiLong"
    if menu.GetCategoryIDByName and menu.RemoveCategory and menu.GetCategoryIDByName(category) then
        menu.RemoveCategory(category)
    end
    for _, entry in ipairs({{"weaponFaces", "武器表情 / Weapon faces"},
        {"homingEyes", "追踪爱心眼 / Homing eyes"}, {"wings", "飞行翅膀 / Wings"},
        {"movementFacing", "头部跟随移动 / Movement facing"},
        {"idleAnimation", "动态待机 / Idle animation"},
        {"chargeFaces", "蓄力表情 / Charging faces"}, {"celebration", "击败 Boss 大笑 / Boss victory"}, {"laughSound", "大笑音效 / Laugh sound"}}) do
        local key, label = entry[1], entry[2]
        menu.AddSetting(category, "外观 / Look", {
            Type=menu.OptionType.BOOLEAN, Default=defaults[key],
            CurrentSetting=function() return cfg[key] end,
            Display=function() return label .. ": " .. (cfg[key] and "ON" or "OFF") end,
            OnChange=function(value) cfg[key]=value; changedSettings() end,
            Info={"只控制奶龙外观，不改变道具能力。", "Cosmetic only; native abilities are unchanged."},
        })
    end
    menu.AddSetting(category, "庆祝 / Laugh", {
        Type=menu.OptionType.NUMBER, Minimum=0, Maximum=100, ModifyBy=5, Default=55,
        CurrentSetting=function() return cfg.laughVolume end,
        Display=function() return "笑声音量 / Laugh volume: " .. cfg.laughVolume .. "%" end,
        OnChange=function(value) cfg.laughVolume=value; changedSettings() end,
        Info={"只调整本模组笑声；仍受游戏音效总音量控制。", "Only this laugh's volume; native SFX volume still applies."},
    })
    menu.AddSetting(category, "庆祝 / Laugh", {
        Type=menu.OptionType.NUMBER, Minimum=15, Maximum=150, ModifyBy=15, Default=150,
        CurrentSetting=function() return cfg.laughFrames end,
        Display=function() return "大笑时长 / Duration: " .. string.format("%.1fs", cfg.laughFrames / 30) end,
        OnChange=function(value) cfg.laughFrames=value; changedSettings() end,
        Info={"0.5–5 秒，按游戏帧计时。", "Duration in game frames; pause does not consume it."},
    })
    menu.AddSetting(category, "设置 / Settings", {
        Type=menu.OptionType.BOOLEAN, Default=false,
        CurrentSetting=function() return false end,
        Display=function() return "恢复默认设置 / Reset preferences" end,
        OnChange=function(value)
            if value == true then cfg = normalizeSettings(); changedSettings() end
        end,
        Info={"选择开启以恢复奶龙默认外观和音效设置。", "Select ON to reset this skin's preferences only."},
    })

end
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function() ensureMenu(); sampleBossVictory() end)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function() stopLaughSound(); gameStarted = false end)

-- Persist only this mod's preferences. No stats, HP, inventory, attacks, controls or HUD changes.
