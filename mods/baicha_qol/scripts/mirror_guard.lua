-- Repair only native Mirror World entrances; never reload rooms or move players.
local M = {}
function M.new(game, getConfig)
    local self = {}
    function self:update()
        if not getConfig().mirror then return end
        local room, level = game:GetRoom(), game:GetLevel()
        local desc = level:GetCurrentRoomDesc()
        for slot=0,DoorSlot.NUM_DOOR_SLOTS-1 do
            local door = room:GetDoor(slot)
            local nativeMirror = door and (door.TargetRoomIndex == GridRooms.ROOM_MIRROR_IDX
                or (desc.Data and desc.Data.Name == 'Mirror Room' and door.OpenAnimation == 'Break'))
            if nativeMirror and door:IsBusted() then
                door.Busted = false
                door:Close(true)
                door:SetLocked(true)
                local sprite = door:GetSprite()
                if door.LockedAnimation ~= '' and sprite:HasAnimation(door.LockedAnimation) then
                    sprite:Play(door.LockedAnimation, true)
                end
                level:SetStateFlag(LevelStateFlag.STATE_MIRROR_BROKEN, false)
            end
        end
    end
    return self
end
return M
