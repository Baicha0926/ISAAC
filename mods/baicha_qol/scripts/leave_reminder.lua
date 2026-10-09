-- Only remember pickups actually observed on this floor. No map spoilers.
local R = {}
local chestVariants = {[50]=true,[51]=true,[52]=true,[53]=true,[54]=true,
    [55]=true,[56]=true,[57]=true,[58]=true,[60]=true}
local resources = {[10]=true,[20]=true,[30]=true,[40]=true,[69]=true,[70]=true,[90]=true,[300]=true,[350]=true}
function R.kind(item)
    if not item:Exists() or item:IsDead() or item:IsShopItem() or item.Price ~= 0
        or item.Timeout >= 0 or item:GetSprite():IsPlaying('Collect') then return end
    if item.Variant == PickupVariant.PICKUP_COLLECTIBLE and item.SubType > 0 then return 'items' end
    if chestVariants[item.Variant] and item.SubType == ChestSubType.CHEST_CLOSED then return 'chests' end
    -- Troll bombs and special bombs are hazards, not forgotten supplies.
    if item.Variant == PickupVariant.PICKUP_BOMB and item.SubType ~= 1 and item.SubType ~= 2
        and item.SubType ~= 4 then return end
    if resources[item.Variant] then return 'resources' end
end
local function identity(game)
    local level = game:GetLevel()
    return tostring(game:GetSeeds():GetStartSeed())..':'..level:GetDungeonPlacementSeed()
        ..':'..level:GetStage()..':'..level:GetStageType()
end
local function roomKey(game)
    local desc = game:GetLevel():GetCurrentRoomDesc()
    return tostring(desc.ListIndex)..':'..desc.SpawnSeed
end
function R.new(game, getConfig, core)
    local self = {rooms={}, pickups={}, exits={}, due=0}
    function self:reset(saved)
        self.id, self.rooms = identity(game), {}
        if type(saved) == 'table' and saved.id == self.id and type(saved.rooms) == 'table' then
            for key, counts in pairs(saved.rooms) do
                if type(key) == 'string' and type(counts) == 'table' then
                    local clean = {}
                    for _,kind in ipairs({'items','chests','resources'}) do
                        local n = counts[kind]
                        clean[kind] = type(n) == 'number' and n == n and math.max(0, math.min(1000, math.floor(n))) or 0
                    end
                    self.rooms[key] = clean
                end
            end
        end
        self:enter()
    end
    function self:observe(item)
        if getConfig().reminders then self.pickups[GetPtrHash(item)] = {item=item,seed=item.InitSeed} end
    end
    function self:enter()
        self.pickups, self.exits, self.due = {}, {}, 0
        self.key = roomKey(game)
        if not getConfig().reminders then return end
        for _,item in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP,-1,-1,false,false)) do self:observe(item) end
    end
    function self:snapshot()
        if not getConfig().reminders or not self.key then return end
        local counts = {items=0,chests=0,resources=0}
        for key,state in pairs(self.pickups) do
            local item = state.item
            if not item:Exists() or item.InitSeed ~= state.seed then self.pickups[key] = nil
            else
                local kind = R.kind(item)
                if kind then counts[kind] = counts[kind]+1 end
            end
        end
        self.rooms[self.key] = counts
    end
    function self:update()
        if not getConfig().reminders then return end
        if self.id ~= identity(game) then self:reset() end
        self:snapshot()
        local frame = game:GetFrameCount()
        if frame < self.due and frame >= self.due-15 then return end
        self.due, self.exits = frame+15, {}
        local room = game:GetRoom()
        if not core.safeCleanup(room) then return end
        for index=0,room:GetGridSize()-1 do
            local grid = room:GetGridEntity(index)
            if grid and grid:GetType() == GridEntityType.GRID_TRAPDOOR then
                self.exits[#self.exits+1] = grid.Position
            end
        end
        for _,effect in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT,EffectVariant.HEAVEN_LIGHT_DOOR,-1,false,false)) do
            self.exits[#self.exits+1] = effect.Position
        end
    end
    function self:line()
        if not getConfig().reminders or not core.safeCleanup(game:GetRoom()) then return end
        local near = false
        for i=0,game:GetNumPlayers()-1 do
            local player = Isaac.GetPlayer(i)
            for _,pos in ipairs(self.exits) do
                if player.Position:DistanceSquared(pos) <= 80^2 then near = true end
            end
        end
        if not near then return end
        self:snapshot()
        local total = {items=0,chests=0,resources=0,rooms=0}
        for _,counts in pairs(self.rooms) do
            if counts.items+counts.chests+counts.resources > 0 then
                total.rooms = total.rooms+1
                for _,kind in ipairs({'items','chests','resources'}) do total[kind] = total[kind]+counts[kind] end
            end
        end
        if total.rooms == 0 then return end
        local parts = {}
        for _,entry in ipairs({{'items','道具'},{'chests','宝箱'},{'resources','资源'}}) do
            if total[entry[1]] > 0 then parts[#parts+1] = total[entry[1]]..entry[2] end
        end
        return '离层前：'..table.concat(parts,' / ')..'（'..total.rooms..'房间）'
    end
    function self:export()
        return {id=self.id, rooms=self.rooms}
    end
    return self
end
return R
