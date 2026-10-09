-- Native one-room rewind only. No fabricated inventory or save-file writes.
local R = {}
R.keys = {71,295,296,298} -- G, F6, F7, F9 (Keyboard enums)
R.names = {'G','F6','F7','F9'}
function R.shortcut(cfg)
    return (cfg.rewindShift and 'Shift+' or '')..R.names[cfg.rewindKey]
end
local function location(game)
    local level = game:GetLevel()
    local desc = level:GetCurrentRoomDesc()
    local floor = tostring(game:GetSeeds():GetStartSeed())..':'..level:GetDungeonPlacementSeed()
        ..':'..level:GetStage()..':'..level:GetStageType()
    return floor, tostring(desc.ListIndex)..':'..desc.SpawnSeed
end
function R.new(game, getConfig)
    local self = {started=false, ready=false, keyDown=true, cancelDown=true, cooldown=0,clock=0}
    function self:reset(started)
        self.started, self.ready = started == true, false
        self.pending, self.attempted, self.notice = nil, false, nil
        self.keyDown, self.cancelDown, self.cooldown = true, true, 0
        self.clock, self.lastTime = 0, nil
        self.floor, self.room = nil, nil
        if self.started then self.floor, self.room = location(game) end
    end
    function self:enter()
        if not self.started then return end
        local floor, room = location(game)
        -- The first room after starting/continuing or changing floors is not
        -- assumed to have a valid native checkpoint. A room transition arms it.
        self.ready = floor == self.floor and (self.ready or room ~= self.room)
        self.floor, self.room = floor, room
        self.pending, self.attempted, self.notice = nil, false, nil
    end
    function self:settingsChanged()
        self.pending, self.notice = nil, nil
        -- Suppress a shortcut held while editing the menu until released.
        self.keyDown, self.cancelDown = true, true
    end
    function self:allowed()
        if not self.started or not self.ready then return false end
        if game.Challenge ~= 0 or game:IsGreedMode() then return false end
        local level = game:GetLevel()
        -- Home includes the Dogma/Beast sequence; native rewind can softlock it.
        if level:GetStage() == LevelStage.STAGE8 then return false end
        local current, previous = level:GetCurrentRoomDesc(), level:GetLastRoomDesc()
        -- Reject off-grid rooms, missing/stale checkpoints and the same room.
        return current and previous and current.SafeGridIndex >= 0
            and previous.SafeGridIndex >= 0 and current.ListIndex ~= previous.ListIndex
            and game:GetRoom():GetFrameCount() >= 5
    end
    function self:party()
        local members, dead, lives = 0, 0, false
        for i=0,game:GetNumPlayers()-1 do
            local player = Isaac.GetPlayer(i)
            if not player:IsCoopGhost() then
                members = members+1
                if player:IsDead() then dead = dead+1 end
                if player:GetExtraLives() > 0 then lives = true end
            end
        end
        return members > 0 and dead == members, lives
    end
    function self:request(now)
        -- Latch before invoking the engine: new-room callbacks may be nested.
        self.pending, self.attempted, self.cooldown = nil, true, now+1000
        local ok = pcall(Isaac.ExecuteCommand, 'rewind')
        self.attempted = true -- Preserve the latch across nested new-room callbacks.
        if not ok then self.notice = {text='回溯请求失败，本次不再自动重试',untilTime=now+3000} end
        return true
    end
    function self:update(menuVisible)
        local cfg = getConfig()
        if not self.started or not (cfg.manualRewind or cfg.deathRewind) then
            self.pending = nil
            return
        end
        local rawTime = Isaac.GetTime()
        -- The OS millisecond counter may wrap or move backwards. Use a local
        -- elapsed clock, skipping gaps caused by focus loss or system suspend.
        local delta = self.lastTime and (rawTime-self.lastTime)%4294967296 or 0
        self.lastTime = rawTime
        if delta <= 250 then self.clock = self.clock+delta end
        local now = self.clock
        local down = Input.IsButtonPressed(R.keys[cfg.rewindKey],0)
        local cancel = Input.IsButtonPressed(297,0) -- F8 cancels this death only.
        local pressed, cancelled = down and not self.keyDown, cancel and not self.cancelDown
        self.keyDown, self.cancelDown = down, cancel
        if menuVisible then self.pending = nil return end
        local allDead, extraLives = self:party()
        if not allDead then self.pending, self.attempted = nil, false end
        if self.notice and now >= self.notice.untilTime then self.notice = nil end
        if not self:allowed() then self.pending = nil return end
        if cancelled and allDead then
            self.pending, self.attempted = nil, true
            self.notice = {text='已取消本次死亡回溯',untilTime=now+3000}
        end
        -- Live pause/cutscene inputs are ignored. Death screens can pause the
        -- simulation too, so the death timer uses real time in POST_RENDER.
        if pressed and cfg.manualRewind and not allDead and not game:IsPaused()
            and (not cfg.rewindShift or Input.IsButtonPressed(340,0)
                or Input.IsButtonPressed(344,0)) and now >= self.cooldown then
            return nil, self:request(now)
        end
        if not cfg.deathRewind or extraLives then self.pending = nil end
        if cfg.deathRewind and allDead and not extraLives and not self.attempted
            and now >= self.cooldown then
            if not self.pending then self.pending = {last=now,remaining=cfg.rewindDelay*1000} end
            local delta = now-self.pending.last
            self.pending.last = now
            -- A focus loss or system suspend must not expire an unseen timer.
            if delta >= 0 and delta <= 250 then self.pending.remaining = self.pending.remaining-delta end
            if self.pending.remaining <= 0 then return nil, self:request(now) end
            return '死亡回溯 '..string.format('%.1f',self.pending.remaining/1000)..'秒（F8取消）'
        end
        return self.notice and self.notice.text
    end
    return self
end
return R
