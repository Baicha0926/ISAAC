-- Restored from Baicha QoL 1.1.0 refreshMarkers: only actual entrances.
local H = {}
local function hiddenType(kind)
    return kind == RoomType.ROOM_SECRET or kind == RoomType.ROOM_SUPERSECRET
        or kind == RoomType.ROOM_ULTRASECRET
end
local function revealed(door)
    return door and (door:IsOpen() or door:IsBusted())
end

function H.new(game, getConfig, core)
    local self = {markers = {}, game = game, getConfig = getConfig, tick = 0}
    local glow = Sprite()
    glow:Load('gfx/baicha_qol_door_glow.anm2', true)
    glow:Play('Idle', true)
    function self:clear() self.markers = {}; self.tick = 0 end
    function self:refresh()
        self.markers = {}
        if not getConfig().hidden then return end
        local room, level = game:GetRoom(), game:GetLevel()
        local desc = level:GetCurrentRoomDesc()
        for slot = 0, 7 do
            if room:IsDoorSlotAllowed(slot) then
                local door = room:GetDoor(slot)
                local actual = door and hiddenType(door.TargetRoomType)
                -- Recover real adjacent secret rooms if the native door is not ready.
                -- The old ultraRoute guesses and crawlspace markers are deliberately removed.
                if not door and desc then
                    local index = core.neighbor(desc.SafeGridIndex, room:GetRoomShape(), slot)
                    local adjacent = index and level:GetRoomByIdx(index, -1)
                    actual = adjacent and adjacent.Data and hiddenType(adjacent.Data.Type)
                end
                if actual and not revealed(door) then
                    local pos = door and door.Position or room:GetDoorSlotPosition(slot)
                    if pos then self.markers[#self.markers + 1] = {slot = slot, position = pos} end
                end
            end
        end
    end
    function self:update()
        if not getConfig().hidden then self:clear(); return end
        self.tick = self.tick + 1
        if self.tick % 15 == 0 then self:refresh() end
    end
    function self:render()
        if not getConfig().hidden then return end
        local room = game:GetRoom()
        glow.Color = Color(0.2, 1, 0.35, 0.88, 0, 0, 0)
        for _, marker in ipairs(self.markers) do
            if not revealed(room:GetDoor(marker.slot)) then
                glow.Rotation = (marker.slot % 4 == 0 or marker.slot % 4 == 2) and 90 or 0
                -- Keep native door coordinates. The old 16px floor inset is removed.
                glow:Render(Isaac.WorldToScreen(marker.position), Vector(0,0), Vector(0,0))
            end
        end
    end
    return self
end
return H
