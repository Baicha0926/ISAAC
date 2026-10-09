local C = {}
C.defaults = {guard=true, cleanup=true, pills=true, showTrade=true,
    showGoldPill=true, hidden=true, holdFrames=9, hudScale=0.7,
    hudOffsetX=0, hudOffsetY=-50, autoCollect=true, collectCoins=true,
    collectBombs=true, collectKeys=true, collectHearts=false, collectRadius=120,
    reminders=true, mirror=true, pauseCollect=true, smartChests=true, chestRadius=80,
    manualRewind=false, deathRewind=false, rewindShift=true, rewindKey=1, rewindDelay=3,
    collectWholeRoom=false, chestWholeRoom=false, smartGoldChests=false, chestKeyReserve=2}
function C.config(saved)
    local c = {}
    for k,v in pairs(C.defaults) do
        c[k]=v
        if type(saved)=="table" and type(saved[k])==type(v) then c[k]=saved[k] end
    end
    local limits={holdFrames={9,60},hudScale={0.4,1.2},hudOffsetX={-160,160},hudOffsetY={-120,40},collectRadius={40,200},chestRadius={40,160},rewindKey={1,4},rewindDelay={1,10},chestKeyReserve={0,10}}
    for k,range in pairs(limits) do
        if c[k]~=c[k] then c[k]=C.defaults[k] end
        c[k]=math.max(range[1],math.min(range[2],c[k]))
        if k~="hudScale" then c[k]=math.floor(c[k]) end
    end
    return c
end
function C.preset(saved, name)
    local cfg=C.config(saved)
    if name~="lazy" and name~="light" then return cfg end
    cfg.autoCollect, cfg.smartChests, cfg.pauseCollect = true, true, true
    cfg.collectWholeRoom, cfg.chestWholeRoom, cfg.smartGoldChests = name=="lazy", name=="lazy", name=="lazy"
    if name=="lazy" then
        cfg.guard, cfg.cleanup, cfg.reminders, cfg.mirror = true, true, true, true
        cfg.chestKeyReserve=math.max(2,cfg.chestKeyReserve)
    end
    -- Preserve the user's blacklist, pill/highlight preferences, rewind choices,
    -- display layout and numeric ranges; profiles only change automation policy.
    return cfg
end
function C.softFireHP(hp)
    -- Entity HP is a native float32; a Lua number is float64.
    return hp>0 and math.abs(hp-0.1)<0.00001
end
function C.paid(price, shop, variant, subtype)
    return not (variant==100 and subtype==0) and (price~=0 or shop)
end
function C.contact(state, frame, frames)
    if not state or not state.last or frame<state.last or frame-state.last>1 then
        state={start=frame}
    end
    state.last=frame
    return state, frame-state.start>=frames
end
function C.healthCost(price)
    local costs={[-1]={2,0},[-2]={4,0},[-3]={0,6},[-4]={2,4},[-7]={0,2},[-8]={0,4},[-9]={2,2}}
    return costs[price]
end
function C.tradeStatus(price,coins,wait,canPick,ready)
    if price>0 and coins<price then return "金币不足：还差 "..(price-coins).."金币" end
    if wait and wait>0 then return "等待物品可拾取" end
    if canPick==false then return "暂时无法拾取：等待动画或松开丢弃键" end
    if ready then return "接触已满足，等待原版交易" end
end
local offsets = {
    [1] = {{-1,0},{0,-1},{1,0},{0,1}},
    [2] = {[1]={-1,0},[3]={1,0}},
    [3] = {[2]={0,-1},[4]={0,1}},
    [4] = {{-1,0},{0,-1},{1,0},{0,2},{-1,1},false,{1,1}},
    [5] = {[2]={0,-1},[4]={0,2}},
    [6] = {{-1,0},{0,-1},{2,0},{0,1},false,{1,-1},false,{1,1}},
    [7] = {[1]={-1,0},[3]={2,0}},
    [8] = {{-1,0},{0,-1},{2,0},{0,2},{-1,1},{1,-1},{2,1},{1,2}},
    [9] = {{-1,0},{-1,0},{1,0},{-1,2},{-2,1},{0,-1},{1,1},{0,2}},
    [10] = {{-1,0},{0,-1},{1,0},{0,2},{-1,1},{1,0},{2,1},{1,2}},
    [11] = {{-1,0},{0,-1},{2,0},{0,1},{0,1},{1,-1},{2,1},{1,2}},
    [12] = {{-1,0},{0,-1},{2,0},{0,2},{-1,1},{1,-1},{1,1},{1,1}},
}

function C.neighbor(index, shape, slot)
    local offset = offsets[shape] and offsets[shape][slot + 1]
    if not offset or type(index) ~= 'number' or index < 0 or index > 168 then return nil end
    local x, y = index % 13 + offset[1], math.floor(index / 13) + offset[2]
    if x < 0 or x > 12 or y < 0 or y > 12 then return nil end
    return y * 13 + x
end


function C.normalPoop(grid)
    return grid and grid:GetType()==GridEntityType.GRID_POOP and grid:GetVariant()==0 and grid.State<1000
end
function C.safeCleanup(room)
    return room:IsClear() and room:GetAliveEnemiesCount()==0 and not room:IsAmbushActive()
end
return C
