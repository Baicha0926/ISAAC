local mod=RegisterMod("Baicha QoL",1)
local C=include("scripts.baicha_qol_core")
local json=require("json")
local game=Game()
local edition=REPENTANCE_PLUS and "Repentance+" or "Repentance"
local cfg=C.config()
local profileBackup
local exiting=false
local guards,softPoops,softFires={},{},{}
local identifiedColors,goldPills={},{}
local cleanupDue,cleanupActive=0,false
local font=Font()
font:Load("font/baicha_qol.fnt")
local reminders, savedReminder
local function save()
    local data={}
    for key,value in pairs(cfg) do data[key]=value end
    data.reminderState=reminders and reminders:export() or savedReminder
    data.profileBackup=profileBackup
    mod:SaveData(json.encode(data))
end
local function load()
    if mod:HasData() then
        local ok,data=pcall(json.decode,mod:LoadData())
        cfg=C.config(ok and data or nil)
        savedReminder=ok and type(data)=="table" and data.reminderState or nil
        profileBackup=ok and type(data)=="table" and type(data.profileBackup)=="table" and C.config(data.profileBackup) or nil
    end
end
load()
local HiddenDoors=include("scripts.hidden_doors")
local hiddenDoors=HiddenDoors.new(game,function() return cfg end,C)
local AutoCollect=include("scripts.auto_collect")
local autoCollect=AutoCollect.new(game,function() return cfg end,C)
local SmartChests=include("scripts.smart_chests")
local smartChests=SmartChests.new(game,function() return cfg end,C,AutoCollect.mapHeld)
local LeaveReminder=include("scripts.leave_reminder")
reminders=LeaveReminder.new(game,function() return cfg end,C)
local MirrorGuard=include("scripts.mirror_guard")
local mirrorGuard=MirrorGuard.new(game,function() return cfg end)
local Rewind=include("scripts.rewind")
local rewind=Rewind.new(game,function() return cfg end)
local function text(s,pos,col,scale)
    scale=scale or 0.8
    font:DrawStringScaledUTF8(s,pos.X-font:GetStringWidthUTF8(s)*scale/2,pos.Y,scale,scale,
        KColor(col[1],col[2],col[3],col[4] or 1),0,false)
end
local function paused()
    return game:IsPaused() or (ModConfigMenu and ModConfigMenu.IsVisible)
end
local function playerKey(p) return GetPtrHash(p) end
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE,function(_,item)
    reminders:observe(item)
    if paused() then autoCollect:clear() return end
    autoCollect:update(item)
    smartChests:update(item)
end)
local function pickupKey(p) return tostring(GetPtrHash(p))..":"..p.InitSeed..":"..p.Variant..":"..p.SubType..":"..p.Price end
local function protected(p)
    return C.paid(p.Price,p:IsShopItem(),p.Variant,p.SubType)
end
local function receipt(p)
    return {coins=p:GetNumCoins(),max=p:GetMaxHearts(),soul=p:GetSoulHearts(),
        hearts=p:GetHearts(),items=p:GetCollectibleCount(),bone=p:GetBoneHearts()}
end
local function changed(before,p)
    local after=receipt(p)
    for k,v in pairs(before) do if after[k]~=v then return true end end
    return false
end
local function settlePending(s,p,frame)
    local pending=s.pending
    if pending and frame>pending.frame then
        local item=pending.item
        if not item:Exists() or item.SubType~=pending.subtype or item.Price~=pending.price
            or (item.Touched and not pending.touched) or changed(pending.receipt,p) then
            -- Each purchase needs its own contact interval, including adjacent items.
            s.contacts={}
        end
        s.pending=nil
    end
end
local function updateGuard()
    if not cfg.guard or paused() then guards={} return end
    local frame=game:GetFrameCount()
    for i=0,game:GetNumPlayers()-1 do
        local p=Isaac.GetPlayer(i)
        local key=playerKey(p)
        local s=guards[key]
        if s then
            settlePending(s,p,frame)
            for target,contact in pairs(s.contacts) do
                if frame-contact.last>1 or frame<contact.last or not contact.item:Exists()
                    or pickupKey(contact.item)~=target or not protected(contact.item) then
                    s.contacts[target]=nil
                end
            end
        end
    end
end
mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION,function(_,item,collider)
    local p=collider:ToPlayer()
    if not p or not cfg.guard or not protected(item) then return end
    if paused() then return true end
    local frame=game:GetFrameCount()
    local key=playerKey(p)
    local s=guards[key] or {contacts={}}
    settlePending(s,p,frame)
    local target=pickupKey(item)
    local contact,ready=C.contact(s.contacts[target],frame,cfg.holdFrames)
    contact.item=item
    s.contacts[target]=contact
    guards[key]=s
    -- Count actual engine collisions, never mere proximity or key presses.
    -- Ignore the physical response while waiting: a push-out can separate the
    -- player and pickup and reset otherwise continuous contact every frame.
    if not ready or s.pending then return true end
    s.pending={frame=frame,item=item,subtype=item.SubType,price=item.Price,touched=item.Touched,receipt=receipt(p)}
    -- The native game still handles affordability, health costs, discounts and OptionsPickupIndex.
end)
local function half(n) return string.format("%g",n/2) end
local function priceLine(item,p)
    local price=item.Price
    if price>0 then
        if p:GetNumCoins()<price then return "标价 "..price.."金币，当前 "..p:GetNumCoins().."金币" end
        return price.."金币，交易后 "..(p:GetNumCoins()-price).."金币"
    end
    if price==PickupPrice.PRICE_FREE or price==0 then return "免费交易" end
    if price==PickupPrice.PRICE_SPIKES then return "尖刺交易：会受伤" end
    if price==PickupPrice.PRICE_SOUL then return "消耗你的灵魂饰品" end
    local cost=C.healthCost(price)
    if not cost then return "特殊价格，以游戏实际扣除为准" end
    local red,soul=cost[1],cost[2]
    local label=half(red).."红心容器 + "..half(soul).."魂心"
    -- Bone hearts and unusual characters have native substitution rules: don't claim an exact result.
    if p:GetMaxHearts()<red or p:GetSoulHearts()<soul then
        return label.."，当前血量低于标价；特殊规则由游戏判定"
    end
    if p:GetBoneHearts()>0 then
        return label.."，特殊血量以实际扣除为准"
    end
    return label.."，预估剩余 "..half(math.min(p:GetHearts(),p:GetMaxHearts()-red))
        .."红心 / "..half(p:GetSoulHearts()-soul).."魂心"
end
local function identifyColor(color)
    if cfg.pills and color~=0 and not identifiedColors[color] then
        game:GetItemPool():IdentifyPill(color)
        identifiedColors[color]=true
    end
end
local function identify()
    for color=1,PillColor.PILL_GOLD do
        identifyColor(color)
        identifyColor(color | PillColor.PILL_GIANT_FLAG)
    end
end
local function trackPill(_,item)
    identifyColor(item.SubType)
    local key=GetPtrHash(item)
    if (item.SubType & PillColor.PILL_COLOR_MASK)==PillColor.PILL_GOLD then
        goldPills[key]=item
    else goldPills[key]=nil end
end
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE,trackPill,PickupVariant.PICKUP_PILL)
if ModCallbacks.MC_POST_PICKUP_INIT then
    mod:AddCallback(ModCallbacks.MC_POST_PICKUP_INIT,trackPill,PickupVariant.PICKUP_PILL)
end
local function resetRoom()
    autoCollect:clear()
    smartChests:clear()
    guards,softPoops,softFires,goldPills={},{},{},{}
    cleanupDue,cleanupActive=0,false
    for _,item in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP,PickupVariant.PICKUP_PILL,-1,false,false)) do
        trackPill(nil,item)
    end
    identify()
    hiddenDoors:refresh()
end
local function restoreCleanup(room)
    for index,s in pairs(softPoops) do
        local g=room:GetGridEntity(index)
        if C.normalPoop(g) and g.State==750 then g.State=s.state end
    end
    for _,s in pairs(softFires) do
        if s.fire:Exists() and s.fire.Variant==0 and C.softFireHP(s.fire.HitPoints) then s.fire.HitPoints=s.hp end
    end
    softPoops,softFires={},{}
end
local function cleanup()
    local room=game:GetRoom()
    if not cfg.cleanup or not C.safeCleanup(room) then
        if next(softPoops) or next(softFires) then restoreCleanup(room) end
        cleanupActive=false
        return
    end
    local frame=game:GetFrameCount()
    if cleanupActive and frame<cleanupDue and frame>=cleanupDue-15 then return end
    cleanupActive=true
    -- Clear transitions are immediate. A bounded fallback also finds grid
    -- obstacles spawned by other mods, for which there is no base API event.
    cleanupDue=frame+15
    for index=0,room:GetGridSize()-1 do
        local g=room:GetGridEntity(index)
        if C.normalPoop(g) and g.State<750 then
            if not softPoops[index] then softPoops[index]={grid=g,state=g.State} end
            g.State=750
        end
    end
    for _,fire in ipairs(Isaac.FindByType(EntityType.ENTITY_FIREPLACE,0,-1,false,false)) do
        if fire.HitPoints>0.1 and not C.softFireHP(fire.HitPoints) and not fire:IsDead() then
            local k=GetPtrHash(fire)
            if not softFires[k] then softFires[k]={fire=fire,hp=fire.HitPoints} end
            fire.HitPoints=0.1
        end
    end
end
if ModCallbacks.MC_POST_NPC_INIT then
    mod:AddCallback(ModCallbacks.MC_POST_NPC_INIT,function() cleanupDue=0 end,EntityType.ENTITY_FIREPLACE)
end
local ensureMenu
mod:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
    ensureMenu()
    if paused() then guards={} autoCollect:clear() return end
    updateGuard()
    cleanup()
    hiddenDoors:update()
    autoCollect:prune()
    smartChests:prune()
    if AutoCollect.mapHeld(game,cfg) then autoCollect:clear() end
    reminders:update()
    mirrorGuard:update()
end)
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM,function()
    resetRoom()
    rewind:enter()
    reminders:enter()
end)
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,function(_,continued)
    exiting=false
    rewind:reset(true)
    identifiedColors={}
    resetRoom()
    reminders:reset(continued and savedReminder or nil)
    savedReminder=nil
    ensureMenu()
end)
mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL,function()
    rewind:reset(true)
    identifiedColors={}
    resetRoom()
    reminders:reset()
end)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT,function() exiting=true rewind:reset(false) hiddenDoors:clear() autoCollect:clear() smartChests:clear() reminders:snapshot() save() end)
if ModCallbacks.MC_PRE_MOD_UNLOAD then
    mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD,function(_,unloading)
        if unloading~=mod or exiting then return end
        rewind:reset(false)
        if next(softPoops) or next(softFires) then restoreCleanup(game:GetRoom()) end
        guards={}
        autoCollect:clear()
        smartChests:clear()
        hiddenDoors:clear()
        -- SaveData is unsafe here during native shutdown. Configuration is
        -- already saved on setting changes and in MC_PRE_GAME_EXIT.
    end)
end
mod:AddCallback(ModCallbacks.MC_POST_RENDER,function()
    if exiting then return end
    local rewindLine,requested=rewind:update(ModConfigMenu and ModConfigMenu.IsVisible)
    if rewindLine then text(rewindLine,Vector(Isaac.GetScreenWidth()/2,Isaac.GetScreenHeight()-35),{1,0.85,0.4},cfg.hudScale) end
    if requested then return end
    if paused() then guards={} autoCollect:clear() return end
    hiddenDoors:render()
    local reminderLine=reminders:line()
    if reminderLine then
        local pos=Isaac.WorldToScreen(Isaac.GetPlayer(0).Position)+Vector(0,-80)
        local width=font:GetStringWidthUTF8(reminderLine)
        local scale=math.min(cfg.hudScale,(Isaac.GetScreenWidth()-16)/math.max(1,width))
        local halfWidth=width*scale/2
        pos=Vector(math.max(halfWidth+8,math.min(Isaac.GetScreenWidth()-halfWidth-8,pos.X)),
            math.max(8,math.min(Isaac.GetScreenHeight()-24,pos.Y)))
        text(reminderLine,pos,{1,0.85,0.4},scale)
    end
    if cfg.guard and cfg.showTrade then
        for i=0,game:GetNumPlayers()-1 do
            local p=Isaac.GetPlayer(i)
            local s=guards[playerKey(p)]
            local contact
            for target,c in pairs(s and s.contacts or {}) do
                if c.item:Exists() and game:GetFrameCount()-c.last<=1 and game:GetFrameCount()>=c.last
                    and pickupKey(c.item)==target
                    and (not contact or c.start<contact.start) then contact=c end
            end
            if contact then
                local pos=Isaac.WorldToScreen(contact.item.Position)+Vector(cfg.hudOffsetX,cfg.hudOffsetY)
                local progress=math.min(100,math.floor((game:GetFrameCount()-contact.start)/cfg.holdFrames*100))
                local label="持续接触 "..string.format("%.1f",cfg.holdFrames/30).."秒后交易 "..progress.."%"
                local canPick
                if contact.item.Variant==PickupVariant.PICKUP_COLLECTIBLE then canPick=p:CanPickupItem() end
                local status=C.tradeStatus(contact.item.Price,p:GetNumCoins(),contact.item.Wait,canPick,progress>=100)
                text(status or label,pos,status and {1,0.7,0.4} or {1,0.9,0.55},cfg.hudScale)
                text(priceLine(contact.item,p),pos+Vector(0,math.ceil(23*cfg.hudScale)),{1,1,1},cfg.hudScale)
            end
        end
    end
    if cfg.pills and cfg.showGoldPill then
        for key,e in pairs(goldPills) do
            if not e:Exists() or (e.SubType & PillColor.PILL_COLOR_MASK)~=PillColor.PILL_GOLD then
                goldPills[key]=nil
            else
                text("金药丸：随机效果",Isaac.WorldToScreen(e.Position)+Vector(0,-25),{1,0.85,0.25},cfg.hudScale)
            end
        end
    end
end)
local function settingsChanged(key)
    if key and (key:find("Rewind") or key:find("rewind")) then rewind:settingsChanged() end
    autoCollect:clear()
    if key=="smartChests" or key=="chestRadius" or key=="smartGoldChests"
        or key=="chestWholeRoom" or key=="chestKeyReserve" or key=="preset" then smartChests:clear() end
    guards={}
    hiddenDoors:refresh()
    cleanupDue=0
    identifiedColors={}
    identify()
    if not cfg.cleanup and (next(softPoops) or next(softFires)) then restoreCleanup(game:GetRoom()) end
    if key=="reminders" or key=="preset" then reminders:reset() end
    if key=="preset" then rewind:settingsChanged() end
    save()
end
local function applyPreset(name)
    if name=="restore" then
        if not profileBackup then return end
        cfg,profileBackup=C.config(profileBackup),nil
    else
        if not profileBackup then profileBackup=C.config(cfg) end
        cfg=C.preset(cfg,name)
    end
    settingsChanged("preset")
end
-- The console is optional; normal configuration is available in Mod Config Menu.
mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD,function(_,cmd,params)
    if cmd~="bq" then return end
    local key,value=params:match("^(%a+)%s+(%a+)$")
    if type(cfg[key])=="boolean" and (value=="on" or value=="off") then
        cfg[key]=value=="on" settingsChanged(key)
        Isaac.ConsoleOutput("Baicha QoL: "..key.."="..tostring(cfg[key]).."\n")
    else Isaac.ConsoleOutput("bq guard|cleanup|pills|hidden|showTrade|showGoldPill|autoCollect|smartChests|reminders|mirror|pauseCollect|collectCoins|collectBombs|collectKeys|collectHearts|manualRewind|deathRewind|rewindShift|collectWholeRoom|chestWholeRoom|smartGoldChests on|off\n") end
end)
local registeredMenu
ensureMenu=function()
    local menu=ModConfigMenu
    if not menu or not menu.AddSetting or not menu.OptionType or registeredMenu==menu then return end
    registeredMenu=menu
    local category="懒人整合包（自用）"
    if menu.RemoveCategory and menu.GetCategoryIDByName then
        for _,name in ipairs({category,"白茶体验包"}) do
            if menu.GetCategoryIDByName(name) then menu.RemoveCategory(name) end
        end
    end
    local names={guard="交易防误触",cleanup="清房后一击清理",pills="识别所有药丸"}
    for _,key in ipairs({"guard","cleanup","pills"}) do
        local k=key
        menu.AddSetting(category,"独立开关",{
            Type=ModConfigMenu.OptionType.BOOLEAN,
            CurrentSetting=function() return cfg[k] end,
            Display=function() return names[k].."："..(cfg[k] and "开" or "关") end,
            Default=C.defaults[k],
            OnChange=function(v) cfg[k]=v settingsChanged(k) end,
            Info={"开关立即生效。已经识别的药丸不会重新变为未知。"}
        })
    end
    menu.AddSetting(category,"交易设置",{
        Type=menu.OptionType.NUMBER,Minimum=9,Maximum=60,ModifyBy=3,Default=9,
        CurrentSetting=function() return cfg.holdFrames end,
        Display=function() return "交易接触时间："..string.format("%.1f",cfg.holdFrames/30).."秒" end,
        OnChange=function(v) cfg.holdFrames=C.config({holdFrames=v}).holdFrames settingsChanged() end,
        Info={"持续接触同一付费物品后自动交易，离开会重新计时。"}
    })
    for _,entry in ipairs({{"showTrade","显示交易提示"},{"showGoldPill","显示金药丸提示"}}) do
        local k,label=entry[1],entry[2]
        menu.AddSetting(category,"显示",{
            Type=menu.OptionType.BOOLEAN,Default=C.defaults[k],
            CurrentSetting=function() return cfg[k] end,
            Display=function() return label.."："..(cfg[k] and "开" or "关") end,
            OnChange=function(v) cfg[k]=v save() end,
            Info={"只改变文字显示，不改变交易和药丸效果。"}
        })
    end
    for _,entry in ipairs({{"hudScale","提示字号",0.4,1.2,0.1},
        {"hudOffsetX","交易提示横向偏移",-160,160,10},{"hudOffsetY","交易提示纵向偏移",-120,40,10}}) do
        local k,label,minimum,maximum,step=table.unpack(entry)
        menu.AddSetting(category,"显示",{
            Type=menu.OptionType.NUMBER,Minimum=minimum,Maximum=maximum,ModifyBy=step,Default=C.defaults[k],
            CurrentSetting=function() return cfg[k] end,
            Display=function() return label.."："..string.format("%g",cfg[k]) end,
            OnChange=function(v) cfg[k]=C.config({[k]=v})[k] save() end,
            Info={"提示位置以正在接触的物品为基准。按菜单重置键恢复默认。"}
        })
    end
    menu.AddSetting(category,"独立开关",{
        Type=menu.OptionType.BOOLEAN,Default=true,
        CurrentSetting=function() return cfg.hidden end,
        Display=function() return "隐藏门高亮："..(cfg.hidden and "开" or "关") end,
        OnChange=function(v) cfg.hidden=v hiddenDoors:refresh() save() end,
        Info={"自动高亮真实隐藏入口；不需要其他隐藏门提示模组。",
            "只显示门位，不显示候选通路或爬梯。开门仍需要炸弹或红钥匙。"}
    })
    for _,entry in ipairs({{"autoCollect","清房自动拾取"},{"collectCoins","吸取金币"},
        {"collectBombs","吸取炸弹"},{"collectKeys","吸取钥匙"},{"collectHearts","吸取心类"}}) do
        local k,label=entry[1],entry[2]
        menu.AddSetting(category,k=="autoCollect" and "独立开关" or "拾取黑名单",{
            Type=menu.OptionType.BOOLEAN,Default=C.defaults[k],
            CurrentSetting=function() return cfg[k] end,
            Display=function() return label.."："..(cfg[k] and "开" or "关") end,
            OnChange=function(v) cfg[k]=v settingsChanged(k) end,
            Info={"清房后吸取附近可拾取的免费资源，关闭分类即可加入黑名单。",
                "跳过付费、选择组、限时掉落、特殊资源及里该隐；心类默认关闭。",
                "不会穿过障碍或沟壑，最终拾取由原版处理。"}
        })
    end
    menu.AddSetting(category,"自动拾取",{
        Type=menu.OptionType.NUMBER,Minimum=40,Maximum=200,ModifyBy=20,Default=120,
        CurrentSetting=function() return cfg.collectRadius end,
        Display=function() return "吸取范围："..cfg.collectRadius end,
        OnChange=function(v) cfg.collectRadius=C.config({collectRadius=v}).collectRadius settingsChanged() end,
        Info={"仅吸取这个距离内的资源；默认120，不移动角色。"}
    })
    for _,entry in ipairs({{"reminders","离层遗漏提醒",
        "靠近楼层出口时提示已记录房间的免费道具、未开宝箱和资源；不阻止离层。"},
        {"mirror","镜子保护","修复雨层/污水层镜世界入口；不重载房间，不移动角色。"},
        {"pauseCollect","地图键暂停吸取/开箱","按住原版地图键临时停止整队吸取和智能开箱，松开恢复；仍可手动操作。"}}) do
        local key,label,info=table.unpack(entry)
        menu.AddSetting(category,"独立开关",{
            Type=menu.OptionType.BOOLEAN,Default=C.defaults[key],
            CurrentSetting=function() return cfg[key] end,
            Display=function() return label.."："..(cfg[key] and "开" or "关") end,
            OnChange=function(v) cfg[key]=v settingsChanged(key) end,
            Info={info,"此开关只控制这一项功能，配置自动保存。"}
        })
    end
    menu.AddSetting(category,"独立开关",{
        Type=menu.OptionType.BOOLEAN,Default=C.defaults.smartChests,
        CurrentSetting=function() return cfg.smartChests end,
        Display=function() return "智能开箱："..(cfg.smartChests and "开" or "关") end,
        OnChange=function(v) cfg.smartChests=v settingsChanged("smartChests") end,
        Info={"安全清房后自动打开附近普通免费宝箱；原版生成掉落，不消耗钥匙或炸弹。",
            "跳过挑战房、付费、选择组、限时、金箱、石箱、尖刺箱、伪装箱及其他特殊箱。",
            "有里该隐时整队停止开箱；可按住地图键暂停，不依赖自动拾取开关。"}
    })
    menu.AddSetting(category,"智能开箱",{
        Type=menu.OptionType.NUMBER,Minimum=40,Maximum=160,ModifyBy=20,Default=C.defaults.chestRadius,
        CurrentSetting=function() return cfg.chestRadius end,
        Display=function() return "开箱范围："..cfg.chestRadius end,
        OnChange=function(v) cfg.chestRadius=C.config({chestRadius=v}).chestRadius settingsChanged("chestRadius") end,
        Info={"默认80，只打开可直达的附近普通宝箱；不穿过障碍或沟壑。"}
    })
    for _,entry in ipairs({{"manualRewind","手动回溯"},{"deathRewind","死亡自动回溯"}}) do
        local key,label=table.unpack(entry)
        menu.AddSetting(category,"独立开关",{
            Type=menu.OptionType.BOOLEAN,Default=C.defaults[key],
            CurrentSetting=function() return cfg[key] end,
            Display=function() return label.."："..(cfg[key] and "开" or "关") end,
            OnChange=function(v) cfg[key]=v settingsChanged(key) end,
            Info={"原版单房间回溯；默认关闭，避免与其他回溯模组重复触发。",
                "本局走到下一房间后可用；跳过挑战、贪婪、Home及地图外房间。",
                "死亡倒计时可按F8取消；有额外生命或合作队友存活时不自动回溯。"}
        })
    end
    menu.AddSetting(category,"回溯辅助",{
        Type=menu.OptionType.NUMBER,Minimum=1,Maximum=4,ModifyBy=1,Default=C.defaults.rewindKey,
        CurrentSetting=function() return cfg.rewindKey end,
        Display=function() return "手动回溯按键："..Rewind.shortcut(cfg) end,
        OnChange=function(v) cfg.rewindKey=C.config({rewindKey=v}).rewindKey settingsChanged("rewindKey") end,
        Info={"可选G、F6、F7、F9；默认Shift+G。F8用于取消本次死亡倒计时。",
            "请选择与其他模组不同的快捷键；长按不会连续回溯。"}
    })
    menu.AddSetting(category,"回溯辅助",{
        Type=menu.OptionType.BOOLEAN,Default=C.defaults.rewindShift,
        CurrentSetting=function() return cfg.rewindShift end,
        Display=function() return "手动回溯需要Shift："..(cfg.rewindShift and "开" or "关") end,
        OnChange=function(v) cfg.rewindShift=v settingsChanged("rewindShift") end,
        Info={"默认开启，左右Shift均可；关闭后仅按所选按键即可回溯。"}
    })
    menu.AddSetting(category,"回溯辅助",{
        Type=menu.OptionType.NUMBER,Minimum=1,Maximum=10,ModifyBy=1,Default=C.defaults.rewindDelay,
        CurrentSetting=function() return cfg.rewindDelay end,
        Display=function() return "死亡回溯等待："..cfg.rewindDelay.."秒" end,
        OnChange=function(v) cfg.rewindDelay=C.config({rewindDelay=v}).rewindDelay settingsChanged("rewindDelay") end,
        Info={"默认3秒；复活后取消，F8取消本次回溯。仅最后一名非幽灵队友死亡才倒计时。",
            "打开模组菜单会清除倒计时；关闭菜单后重新计时。"}
    })
    for _,entry in ipairs({{"collectWholeRoom","全房间资源吸取",
        "清房后吸取本房间可直达的资源，仍遵守黑名单、容量和地图键暂停。"},
        {"chestWholeRoom","全房间自动开箱","清房后处理本房间可直达的箱子，普通箱与金箱开关分别控制。"},
        {"smartGoldChests","智能金箱","清房后打开标准金箱；默认保留两把钥匙，可在智能开箱页调整。"}}) do
        local key,label,info=table.unpack(entry)
        menu.AddSetting(category,"独立开关",{
            Type=menu.OptionType.BOOLEAN,Default=C.defaults[key],
            CurrentSetting=function() return cfg[key] end,
            Display=function() return label.."："..(cfg[key] and "开" or "关") end,
            OnChange=function(v) cfg[key]=v settingsChanged(key) end,
            Info={info,"新功能默认关闭；一键懒人模式可以同时开启，原有设置会保留。",
                "不穿过沟壑或障碍，不移动角色；挑战房、付费和选择组宝箱仍跳过。"}
        })
    end
    menu.AddSetting(category,"智能开箱",{
        Type=menu.OptionType.NUMBER,Minimum=0,Maximum=10,ModifyBy=1,Default=C.defaults.chestKeyReserve,
        CurrentSetting=function() return cfg.chestKeyReserve end,
        Display=function() return "金箱保留钥匙："..cfg.chestKeyReserve end,
        OnChange=function(v) cfg.chestKeyReserve=C.config({chestKeyReserve=v}).chestKeyReserve settingsChanged("chestKeyReserve") end,
        Info={"只有钥匙多于保留数时才消耗一把；优先让有金钥匙或曲别针的队友免费开箱。",
            "跳过金钱万能的付款规则；巨型、永恒、石箱、尖刺、红箱等仍手动处理。"}
    })
    for _,entry in ipairs({{"lazy","一键启用懒人模式"},{"light","一键切换轻度辅助"},{"restore","恢复切换前的自定义配置"}}) do
        local name,label=table.unpack(entry)
        menu.AddSetting(category,"懒人预设",{
            Type=menu.OptionType.BOOLEAN,Default=false,
            CurrentSetting=function() return false end,
            Display=function() return label..(name=="restore" and not profileBackup and "（暂无备份）" or "") end,
            OnChange=function(v) if v then applyPreset(name) end end,
            Info={"按确定或向右应用一次；不是需要保持开启的开关。",
                "懒人模式：全房间收资源、开普通箱与金箱，至少保留两把钥匙。",
                "轻度辅助：附近吸取和普通箱，关闭全房间模式及智能金箱。",
                "黑名单、回溯、文字布局和范围设置保留；首次切换前配置自动备份并跨重启保存。"}
        })
    end
end
ensureMenu()
Isaac.DebugString("[Baicha QoL] Loaded 1.9.0 / "..edition)
