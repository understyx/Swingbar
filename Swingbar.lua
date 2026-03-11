local _, ns = ...
local Swing = EdgyUI:NewModule("SwingBar", "AceEvent-3.0")

local BAR_POOL_KEY = "SwingBars"
local AUTO_SHOT_NAME = GetSpellInfo(75)

local NEXT_HIT_ABILITIES = { 
    [47450] = true,
    [845] = true,   -- Cleave (Rank 1)
    [2973] = true,  -- Raptor Strike (Rank 1)
}

local activeBars = { MH = nil, OH = nil, RANGED = nil }
local lastMHTime, lastMHSpeed = 0, 0
local lastOHTime, lastOHSpeed = 0, 0
local playerClass

function Swing:OnInitialize()
    _, playerClass = UnitClass("player")
end

function Swing:OnEnable()
    local db = EdgyUI.db.profile.autoAttack
    if not db or not db.enabled then 
        self:Disable()
        return 
    end

    if not self.frame then
        self.frame = ns:CreateDynamicContainer("EdgyUI_SwingBarContainer", UIParent, "VERTICAL", 2)
        self.frame:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
        ns:RegisterMovableFrame(self.frame, db, "Swingbar")
    end

    self.frame:Show()

    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("UNIT_SPELLCAST_START")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self:RegisterEvent("UNIT_SPELLCAST_STOP", "OnSpellCastStop")
    self:RegisterEvent("UNIT_SPELLCAST_FAILED", "OnSpellCastStop")
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", "OnSpellCastStop")


    self:RefreshLayout()
end

function Swing:OnDisable()
    if self.frame then 
        self.frame:Hide() 
    end
    ns:ReleaseFrames(BAR_POOL_KEY)
    wipe(activeBars)
end

function Swing:RefreshLayout()
    ns:ReleaseFrames(BAR_POOL_KEY)
    wipe(activeBars)

    local db = EdgyUI.db.profile.autoAttack
    if not db.enabled then return end

    if not self.frame then return end

    self.frame:SetSize(db.width, 60)
    self.frame:SetPoint(db.point, UIParent, db.point, db.x, db.y)

    local function SetupBar(id, label, color)
        local bar = ns:AcquireFrame(BAR_POOL_KEY, self.frame)
        bar:SetStatusBarColor(color.r, color.g, color.b)
        bar:SetStatusBarTexture(ns.getGlobalBarTexture())
        bar:SetSize(db.width, 12)
        bar.text:SetText(label)
        
        self.frame:AddFrame(bar)
        
        activeBars[id] = bar
    end

    if playerClass == "WARRIOR" then
        SetupBar("MH", "Main Hand", db.mhColor)
        SetupBar("OH", "Off Hand", db.ohColor)
        return
    end

    if GetInventoryItemLink("player", INVSLOT_MAINHAND) then 
        SetupBar("MH", "Main Hand", db.mhColor) 
    end
    
    if GetInventoryItemLink("player", INVSLOT_OFFHAND) then 
        local _, ohSpeed = UnitAttackSpeed("player")
        if ohSpeed and ohSpeed > 0 then 
            SetupBar("OH", "Off Hand", db.ohColor) 
        end 
    end
    
    if playerClass == "HUNTER" and GetInventoryItemLink("player", INVSLOT_RANGED) then
        SetupBar("RANGED", "Ranged", db.rangedColor)
    end
end

function Swing:StartSwing(id, speed)
    local bar = activeBars[id]
    if not bar or not speed or speed <= 0 then return end
    
    if bar.isAnimating then
        local now = GetTime()
        local remaining = (bar.startTime + bar.duration) - now
        -- If a swing is just about to finish (<0.1s), ignore the new start event 
        -- (common workaround for spammy combat logs)
        if remaining > 0.1 then 
            return 
        end
    end

    bar.startTime = GetTime()
    bar.duration = speed
    bar:SetValue(0)
    bar.isAnimating = true
end

function Swing:OnUpdate(elapsed)
    local now = GetTime()
    local mhSpeed, ohSpeed = UnitAttackSpeed("player")
    local rangedSpeed = UnitRangedDamage("player")

    for id, bar in pairs(activeBars) do
        if bar and bar.isAnimating then
            if bar.paused then
                -- While paused, shift the start time forward so the bar doesn't "jump" when unpaused
                bar.startTime = bar.startTime + (now - (bar.lastTick or now))
                bar.lastTick = now
            else
                bar.lastTick = now
                local currentSpeed = (id == "MH" and mhSpeed) or (id == "OH" and ohSpeed) or rangedSpeed
                
                -- Adjust dynamically if attack speed changes mid-swing (Haste procs)
                if currentSpeed and currentSpeed > 0 and currentSpeed ~= bar.duration then
                    local progress = (now - bar.startTime) / bar.duration
                    bar.duration = currentSpeed
                    bar.startTime = now - (progress * currentSpeed)
                end

                local timeDiff = now - bar.startTime
                local progress = timeDiff / bar.duration
                
                if progress >= 1 then
                    bar:SetValue(1)
                    bar.isAnimating = false
                else
                    bar:SetValue(progress)
                end
            end
        end
    end
end


function Swing:UNIT_SPELLCAST_START(event, unit, spellName)
    if spellName == "Slam" and unit == "player" then
        if activeBars.MH then activeBars.MH.paused = true end
        if activeBars.OH then activeBars.OH.paused = true end
    end
end


function Swing:UNIT_SPELLCAST_SUCCEEDED(event, unit, spellName)
    if unit == "player" and spellName == AUTO_SHOT_NAME then
            self:StartSwing("RANGED", (UnitRangedDamage("player")))
    end
end

function Swing:OnSpellCastStop(event, unit, spellName)
    if spellName == "Slam" and unit == "player" then
        if activeBars.MH then activeBars.MH.paused = false end
        if activeBars.OH then activeBars.OH.paused = false end
    end
end

function Swing:COMBAT_LOG_EVENT_UNFILTERED(event, ...)
    local _, subEvent, sourceGUID, _, _, _, _, _, spellId = ...
    if sourceGUID ~= UnitGUID("player") then return end

    local now = GetTime()
    local mhSpeed, ohSpeed = UnitAttackSpeed("player")
    ohSpeed = ohSpeed or 0

    if subEvent == "SWING_DAMAGE" or subEvent == "SWING_MISSED" then
        local lastMHT, lastMHS = lastMHTime or 0, lastMHSpeed or 0
        local lastOHT, lastOHS = lastOHTime or 0, lastOHSpeed or 0

        -- Determine if this was a Main Hand or Off Hand swing
        if lastMHS == 0 or (now >= lastMHT + lastMHS - 0.1) then
            self:StartSwing("MH", mhSpeed)
            lastMHTime, lastMHSpeed = now, mhSpeed
        elseif ohSpeed > 0 and (lastOHS == 0 or (now >= lastOHT + lastOHS - 0.1)) then
            self:StartSwing("OH", ohSpeed)
            lastOHTime, lastOHSpeed = now, ohSpeed
        end

    elseif subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_MISSED" then
        -- Reset swing timer on specific "Next Hit" abilities (Cleave, Raptor Strike, etc)
        if NEXT_HIT_ABILITIES[spellId] then
            self:StartSwing("MH", mhSpeed)
            lastMHTime, lastMHSpeed = now, mhSpeed
        end
    end
end