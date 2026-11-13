-- AllodsPartyHUD / experimental community addon v1.9.15
-- Implemented against the Lua/XDB patterns in ControlChecker, TetraMeter and ADSC.
-- The numeric ally shield display uses GetHealthInfo().additionalPercents,
-- as in Universe. This is a percentage indicator, not verified absorption in HP.

-- Embedded codec: keep profile export/import in the same Lua chunk as Main.
-- Avoid relying on whether the client loads additional ScriptFileRefs.
local APH_CodeExchange = (function()
-- AllodsPartyHUD text profile exchange APH1.
-- Self-contained, deterministic, non-executable format: typed tree + Base64 + Adler-32.
-- Never execute text pasted by the player (no loadstring or eval).
local APH_CodeExchange = {}
local BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local char = string.char
local function b64encode(data)
    local out = {}
    for i=1,#data,3 do
        local a,b,c=data:byte(i,i+2)
        b=b or 0; c=c or 0
        local n=a*65536+b*256+c
        local x=math.floor(n/262144)%64
        local y=math.floor(n/4096)%64
        local z=math.floor(n/64)%64
        local w=n%64
        out[#out+1]=BASE64:sub(x+1,x+1)
        out[#out+1]=BASE64:sub(y+1,y+1)
        out[#out+1]=(i+1<=#data) and BASE64:sub(z+1,z+1) or '='
        out[#out+1]=(i+2<=#data) and BASE64:sub(w+1,w+1) or '='
    end
    return table.concat(out)
end
local INV={}
for i=1,#BASE64 do INV[BASE64:sub(i,i)]=i-1 end
local function b64decode(s)
    if #s%4~=0 or #s==0 or s:find('[^%w%+/%=]') then return nil,'Неверный Base64' end
    local out={}
    for i=1,#s,4 do
        local a,b,c,d=s:sub(i,i+3):match('(.)(.)(.)(.)')
        if not INV[a] or not INV[b] then return nil,'Неверный Base64' end
        local pad=(c=='=' and 2 or d=='=' and 1 or 0)
        if pad>0 and i+3~=#s then return nil,'Ошибка заполнения Base64' end
        if c=='=' and d~='=' then return nil,'Ошибка заполнения Base64' end
        if c~='=' and not INV[c] then return nil,'Неверный Base64' end
        if d~='=' and not INV[d] then return nil,'Неверный Base64' end
        local n=INV[a]*262144+INV[b]*4096+(INV[c] or 0)*64+(INV[d] or 0)
        out[#out+1]=char(math.floor(n/65536)%256)
        if pad<2 then out[#out+1]=char(math.floor(n/256)%256) end
        if pad<1 then out[#out+1]=char(n%256) end
    end
    return table.concat(out)
end
local function checksum(s)
    local a,b=1,0
    for i=1,#s do
        a=(a+s:byte(i))%65521
        b=(b+a)%65521
    end
    return string.format('%04X%04X',b,a)
end
local MAX_RAW=90000
local function encodeNode(value,out,depth)
    if depth>7 then error('Слишком глубокая структура') end
    local ty=type(value)
    if ty=='string' then
        if #value>8192 then error('Слишком длинная строка') end
        out[#out+1]='S'..#value..':'..value
    elseif ty=='boolean' then
        out[#out+1]=value and 'T' or 'F'
    elseif ty=='number' then
        if value~=value or math.abs(value)>1000000000 then error('Неверное число') end
        out[#out+1]='N'..tostring(value)..';'
    elseif ty=='table' then
        local keys={}
        for k,v in pairs(value) do
            if type(k)~='string' then error('Неверный ключ профиля') end
            keys[#keys+1]=k
        end
        table.sort(keys)
        if #keys>2000 then error('Слишком много записей') end
        out[#out+1]='M'..#keys..':'
        for _,k in ipairs(keys) do
            encodeNode(k,out,depth+1)
            encodeNode(value[k],out,depth+1)
        end
    else
        error('Тип данных не поддерживается')
    end
end
local function readNode(raw,state,depth)
    if depth>7 then error('Глубина данных превышена') end
    state.count=state.count+1
    if state.count>9000 then error('Слишком много элементов') end
    local pos=state.pos
    local tag=raw:sub(pos,pos)
    state.pos=pos+1
    if tag=='T' then return true end
    if tag=='F' then return false end
    if tag=='S' or tag=='M' then
        local start=state.pos
        local e=raw:find(':',start,true)
        if not e or e-start>8 then error('Неверная длина') end
        local size=tonumber(raw:sub(start,e-1))
        if not size or size<0 or size~=math.floor(size) then error('Неверная длина') end
        state.pos=e+1
        if tag=='S' then
            if size>8192 or state.pos+size-1>#raw then error('Повреждена строка') end
            local s=raw:sub(state.pos,state.pos+size-1)
            state.pos=state.pos+size
            return s
        end
        if size>2000 then error('Слишком большая таблица') end
        local t={}
        for i=1,size do
            local key=readNode(raw,state,depth+1)
            if type(key)~='string' or t[key]~=nil then error('Неверный ключ') end
            t[key]=readNode(raw,state,depth+1)
        end
        return t
    end
    if tag=='N' then
        local e=raw:find(';',state.pos,true)
        if not e or e-state.pos>28 then error('Неверное число') end
        local number=tonumber(raw:sub(state.pos,e-1))
        if not number or number~=number or math.abs(number)>1000000000 then error('Неверное число') end
        state.pos=e+1
        return number
    end
    error('Неизвестный тип данных')
end
function APH_CodeExchange.Encode(scope,data)
    if scope~='all' and scope~='effects' and scope~='cooldowns' then return nil,'Неизвестный раздел' end
    local chunks={}
    local ok,err=pcall(encodeNode,{scope=scope,data=data},chunks,0)
    if not ok then return nil,tostring(err) end
    local raw=table.concat(chunks)
    if #raw>MAX_RAW then return nil,'Профиль слишком большой' end
    return 'APH1:'..b64encode(raw)..':'..checksum(raw)
end
function APH_CodeExchange.Decode(code)
    if type(code)~='string' then return nil,'Пустой код' end
    code=code:gsub('%s','')
    if #code>130000 then return nil,'Код слишком длинный' end
    local payload,sum=code:match('^APH1:([A-Za-z0-9+/=]+):(%x%x%x%x%x%x%x%x)$')
    if not payload then return nil,'Нужен код PartyHUD формата APH1' end
    local raw,err=b64decode(payload)
    if not raw then return nil,err end
    if #raw>MAX_RAW then return nil,'Слишком большой профиль' end
    if checksum(raw)~=sum:upper() then return nil,'Код повреждён (контрольная сумма)' end
    local state={pos=1,count=0}
    local ok,result=pcall(readNode,raw,state,0)
    if not ok then return nil,'Не удалось прочитать: '..tostring(result) end
    if state.pos~=#raw+1 or type(result)~='table' then return nil,'Лишние данные' end
    if result.scope~='all' and result.scope~='effects' and result.scope~='cooldowns' then return nil,'Неизвестный раздел' end
    if type(result.data)~='table' then return nil,'Нет настроек' end
    return result
end
return APH_CodeExchange
end)()

local HUD = {
    blinkPhase = true, flashTicks = 0, fastTimerRunning = false, flashSelectedPage = nil, flashSelectedName = nil,
    rows = {}, roster = {}, byId = {}, personalSubscribed = {}, active = {}, casts = {}, castSequence = 0, buffOrder = {}, buffTimerCache = {}, buffSequence = 0, effectTextureCache = {}, tick = 0, clockMs = 0,
    targeterRows = {}, targeterEntries = {}, targetersChecked = 0, enemyAttacks = {}, viewMode = "preview",
    markTargetId = nil, markWidget = nil, markIcon = nil, markControl3D = nil, markTextures = {}, markPulseTick = 0, markConfigSignature = nil, markError = nil,
    markInfo = nil, markLastAttemptTick = -100, markRetryTick = 0, markAttachFailures = 0, markRetryTarget = nil, markSelectedCategory = "enemy",
    page = "General", effectScope = "ally", listPage = 0, overviewPage = 1, widgets = {}, MAX_MEMBERS = 6, MAX_CAST_ICONS = 5, MAX_BUFF_ICONS = 10
}

local DEFAULT = {
    showGroup = true, showTargeters = true, targeterMode = "attacks", showCooldowns = true,
    showTargetMark = true, targetMarkStyle = "classic", targetMarkColorMode = "custom",
    targetMarkColor = "#FFE533", targetMarkSize = 100, targetMarkOffsetX = 0, targetMarkOffsetY = 0, targetMarkPulse = false,
    targetMarkProfiles = {}, showEnemyRoster = true, showTargetSelector = true, viewerDefaultsV197 = false, rosterMode = "enemy", overviewV199 = false, overviewClickTarget = false, overviewPageSize = 12, overviewWidth = 318, overviewRowHeight = 36, overviewRowGap = 1, overviewShowClass = true, overviewShowHpPercent = true, dragUnlocked = false, unifiedMarkV1912 = false, cooldownPosition = "bottom", cooldownEntryMode = "auto",
    hudStyleVersion = 0,
    frameWidth = 310, rowHeight = 65, rowSpacing = 0, iconSize = 20, buffPosition = "right", buffIconSize = 22, buffIconCount = 6,
    showClass = true, showHpPercent = true, colorMode = "single",
    hpColor = "#FA8655", shieldColor = "#409BF4", frameColor = "#E7CFB3",
    alertColor = "#090909", alertControls = true, alertDispellable = true, alertBuffs = {},
    trackedBuffs = {}, trackedDebuffs = {}, enemyTrackedBuffs = {}, enemyTrackedDebuffs = {}, effectCatalog = {}, effectAddKind = "buff",
    -- Each tracked effect has its own screen side (left/right).
    buffSides = {}, debuffSides = {}, enemyBuffSides = {}, enemyDebuffSides = {},
    -- Per-effect visual highlights; keys are exact buff/debuff names.
    buffFlashRules = {}, debuffFlashRules = {}, enemyBuffFlashRules = {}, enemyDebuffFlashRules = {}, flashPeriod = 0.5,
    defenses = {
        ["Древесная кора"] = true, ["Крепкая броня"] = true,
        ["Преодоление"] = true, ["Праведный Дух"] = true,
        ["Благословение Покровителя"] = true
    },
    shields = { ["Акустический барьер"] = true, ["Силовое поле"] = true },
    cooldowns = {} -- whitelist: ["Buff or spell name"] = "auto" OR duration in seconds
}
local tabs = { "Effects", "Alerts", "Cooldowns", "General", "Share", "TargetMark", "Overview" }
local tabText = { Effects="ЭФФЕКТЫ", Buffs="БАФЫ", Debuffs="ДЕБАФЫ", Alerts="ТРЕВОГИ", Defenses="ЗАЩИТЫ", Shields="ЩИТЫ", Cooldowns="ОТКАТЫ", General="ОБЩЕЕ", Share="ОБМЕН", TargetMark="МЕТКА", Overview="ОБЗОР" }
local dataText = { Buffs="trackedBuffs", Debuffs="trackedDebuffs", Alerts="alertBuffs", Defenses="defenses", Shields="shields", Cooldowns="cooldowns" }
local COLORS = {
    window = { r=.075,g=.09,b=.13,a=.96 }, line = { r=.18,g=.23,b=.30,a=.90 },
    row = { r=.10,g=.13,b=.19,a=.94 }, rowAlt={r=.13,g=.17,b=.23,a=.94},
    text={r=1,g=1,b=1,a=1},
    hidden={r=.13,g=.18,b=.24,a=.85}, warn={r=.95,g=.72,b=.20,a=.95}
}
local PALETTES = {
    {"#30BC59","зелёный"}, {"#409BF4","голубой"}, {"#CF4C61","красный"},
    {"#D6A439","золотой"}, {"#945AD5","фиолетовый"}, {"#E17A36","оранжевый"},
    {"#E2E7EB","белый"}, {"#5DC8C0","бирюзовый"}
}
local CLASS_HEX = {
    -- Colors follow the class palette in the inspected Universe addon.
    WARRIOR="#8F774B", PALADIN="#CFDC9B", MAGE="#7E9FFF", DRUID="#FF763C",
    PSIONIC="#DD7BF5", STALKER="#96CC56", PRIEST="#FFCF7B",
    NECROMANCER="#D0454B", BARD="#33E6E6", ENGINEER="#7F80B2",
    WARLOCK="#7D65DB"
}
-- A muted class palette for the overview, closer to Allods' native raid frames.
-- The more vivid CLASS_HEX palette remains intact for the party UI.
local OVERVIEW_CLASS_HEX = {
    WARRIOR="#796443", PALADIN="#85846A", MAGE="#59658B", DRUID="#92523D",
    PSIONIC="#7B528F", STALKER="#607B43", PRIEST="#A07949",
    NECROMANCER="#8F3547", BARD="#447F80", ENGINEER="#62617E",
    WARLOCK="#65508E"
}
local function color(hex)
    local r,g,b = tostring(hex or ""):match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return {r=.4,g=.4,b=.4,a=1} end
    return {r=tonumber(r,16)/255,g=tonumber(g,16)/255,b=tonumber(b,16)/255,a=1}
end
local function colorDark(hex)
    local v=color(hex)
    return {r=.065+v.r*.36,g=.065+v.g*.32,b=.080+v.b*.32,a=.94}
end
local function normalizedHex(v)
    v=tostring(v or ""):gsub("%s", ""):upper():gsub("^#", "")
    if #v~=6 or not v:match("^%x+$") then return nil end
    return "#"..v
end
local function nextPalette(hex)
    for i,p in ipairs(PALETTES) do
        if p[1]==hex then return PALETTES[i%#PALETTES+1][1] end
    end
    return PALETTES[1][1]
end
local function colorTitle(hex)
    for _,p in ipairs(PALETTES) do if p[1]==hex then return p[2] end end
    return hex
end

-- Standalone class icon textures licensed MIT (resources from Universe/OLDodin).
local classTexNames={
 WARRIOR="WarriorIcon", PALADIN="PaladinIcon", MAGE="MageIcon",
 DRUID="DruidIcon", PSIONIC="PsionicIcon", STALKER="StalkerIcon",
 PRIEST="PriestIcon", NECROMANCER="NecromancerIcon", BARD="BardIcon",
 ENGINEER="EngineerIcon", WARLOCK="WarlockIcon", UNKNOWN="UnknownIcon"
}
local classTextures={}
-- BuffAnnounce uses a widget directly attached to the selected unit, with
-- autoResizeX=true, a center bind point and an initial position at the avatar.
-- Retain compact per-style dimensions; do NOT scale the surrounding HUD.
-- Match the source BuffAnnounce 3D geometry per style instead of forcing
-- all textures into square metre bounds (the latter separated the arrows).
-- v1.9.13: BuffAnnounce's runtime 3D-marker approach.
-- Fixed 2x2-metre world bounds; animate the widget's VIRTUAL size, not the
-- object-bound geometry. Previous 0 x 4.96 m bounds made arrows diverge.
-- A single marker style applies to all selected unit types.
local MARK_STYLES={
    classic={label="Classic",texture="ClassicTarget",front="ClassicTargetHighlight",
        startVirtual=150,finishVirtual=120,resizeSpeed=500,rotateSpeed=7000,height=-1},
    triple={label="Triple Arrows",texture="TripleArrowsM",front="Empty",
        startVirtual=190,finishVirtual=190,resizeSpeed=0,rotateSpeed=0,height=0},
    pvp={label="PvP Crosshair",texture="TMEnemy",front="Empty",
        startVirtual=190,finishVirtual=170,resizeSpeed=800,rotateSpeed=10000,height=-1}
}

local function initializeMarkTextures()
    local ok,provider=pcall(common.GetAddonRelatedTextureGroup,"mark")
    if not ok or not provider then return end
    for _,style in pairs(MARK_STYLES) do
        for _,textureName in ipairs({style.texture,style.front}) do
            if textureName and not HUD.markTextures[textureName] then
                local good,texture=pcall(function() return provider:GetTexture(textureName) end)
                if good and texture then HUD.markTextures[textureName]=texture end
            end
        end
    end
end
local function initializeClassTextures()
    local ok,provider=pcall(common.GetAddonRelatedTextureGroup,"class")
    if not ok or not provider then return end
    for cls,key in pairs(classTexNames) do
        local good,value=pcall(function() return provider:GetTexture(key) end)
        if good then classTextures[cls]=value end
    end
end

local function getCfg()
    local stored = userMods.GetGlobalConfigSection(common.GetAddonName()) or {}
    local c = {}
    for k,v in pairs(DEFAULT) do
        if type(v) == 'table' then
            c[k] = {}
            for n, val in pairs(v) do c[k][n] = val end
            if type(stored[k]) == 'table' then
                -- User-set lists replace defaults; empty lists are intentionally allowed.
                c[k] = stored[k]
            end
        else
            if stored[k] == nil then c[k] = v else c[k] = stored[k] end
        end
    end
    return c
end
local settings = getCfg()
local ROSTER_MODES = {"enemy", "ally", "mob", "spectator"}
local ROSTER_MODE_LABELS = {
    enemy = "Враждебные персонажи",
    ally = "Дружественные персонажи",
    mob = "Мобы",
    spectator = "Спектатор"
}
local ROSTER_MODE_TITLES = {
    enemy = "ВРАЖДЕБНЫЕ",
    ally = "ДРУЖЕСТВЕННЫЕ",
    mob = "МОБЫ",
    spectator = "СПЕКТАТОР"
}
if not ROSTER_MODE_LABELS[settings.rosterMode] then settings.rosterMode="enemy" end
if type(settings.showTargetSelector)~="boolean" then settings.showTargetSelector=true end
-- Migration from the selected-target filter: independent visible-unit overview.
if settings.overviewV199~=true then
    settings.showEnemyRoster=true
    settings.overviewClickTarget=false -- NEVER change target on list click by default.
    settings.overviewPageSize=12
    settings.overviewV199=true
end
if type(settings.overviewShowClass)~="boolean" then settings.overviewShowClass=true end
if type(settings.showHpPercent)~="boolean" then settings.showHpPercent=true end
if type(settings.overviewShowHpPercent)~="boolean" then settings.overviewShowHpPercent=true end
if type(settings.dragUnlocked)~="boolean" then settings.dragUnlocked=false end
if type(settings.overviewClickTarget)~="boolean" then settings.overviewClickTarget=false end
settings.overviewPageSize=math.max(3,math.min(16,math.floor(tonumber(settings.overviewPageSize) or 12)))
settings.overviewWidth=math.max(220,math.min(720,math.floor(tonumber(settings.overviewWidth) or 318)))
settings.overviewRowHeight=math.max(24,math.min(80,math.floor(tonumber(settings.overviewRowHeight) or 36)))
settings.overviewRowGap=math.max(0,math.min(25,math.floor(tonumber(settings.overviewRowGap) or 1)))
-- The game discloses another player's target only when that player is selected.
-- Default to recently observed incoming attacks, which work independently of selection.
if settings.targeterMode~="attacks" and settings.targeterMode~="targets" then
    settings.targeterMode="attacks"
end
if settings.colorMode~="single" and settings.colorMode~="class" then settings.colorMode="class" end
settings.hpColor=normalizedHex(settings.hpColor) or DEFAULT.hpColor
settings.shieldColor=normalizedHex(settings.shieldColor) or DEFAULT.shieldColor
settings.frameColor=normalizedHex(settings.frameColor) or DEFAULT.frameColor
settings.alertColor=normalizedHex(settings.alertColor) or DEFAULT.alertColor
if not MARK_STYLES[settings.targetMarkStyle] then settings.targetMarkStyle="classic" end
if settings.targetMarkColorMode~="class" then settings.targetMarkColorMode="custom" end
settings.targetMarkColor=normalizedHex(settings.targetMarkColor) or DEFAULT.targetMarkColor
settings.targetMarkSize=math.max(50,math.min(300,tonumber(settings.targetMarkSize) or 100))
settings.targetMarkOffsetX=math.max(-60,math.min(60,tonumber(settings.targetMarkOffsetX) or 0))
settings.targetMarkOffsetY=math.max(-30,math.min(80,tonumber(settings.targetMarkOffsetY) or 0))
-- BuffAnnounce-style independent preferences by selected target type.
-- "enemy" = hostile PLAYER, "ally" = friendly PLAYER (including avatar),
-- "mob" = any non-player unit. The unit frame is independent of the 3D marker.
local MARK_CATEGORIES={"enemy","ally","mob"}
local MARK_CATEGORY_LABEL={enemy="ВРАГИ",ally="СОЮЗНИКИ",mob="МОБЫ"}
if type(settings.targetMarkProfiles)~="table" then settings.targetMarkProfiles={} end
for _,kind in ipairs(MARK_CATEGORIES) do
    local profile=settings.targetMarkProfiles[kind]
    if type(profile)~="table" then profile={} end
    if type(profile.enabled)~="boolean" then profile.enabled=true end
    if type(profile.showFrame)~="boolean" then profile.showFrame=true end
    if not MARK_STYLES[profile.style] then profile.style=settings.targetMarkStyle end
    profile.colorMode=profile.colorMode=="class" and "class" or (profile.colorMode=="custom" and "custom" or settings.targetMarkColorMode)
    profile.color=normalizedHex(profile.color) or settings.targetMarkColor
    profile.size=math.max(50,math.min(300,tonumber(profile.size) or settings.targetMarkSize))
    profile.offsetX=math.max(-60,math.min(60,tonumber(profile.offsetX) or settings.targetMarkOffsetX))
    profile.offsetY=math.max(-30,math.min(80,tonumber(profile.offsetY) or settings.targetMarkOffsetY))
    if type(profile.pulse)~="boolean" then profile.pulse=settings.targetMarkPulse end
    settings.targetMarkProfiles[kind]=profile
end
if not settings.viewerDefaultsV197 then
    -- In older releases ally/mob target frames were OFF by default.
    -- The new always-on selector is meant to show any selected category.
    for _,kind in ipairs(MARK_CATEGORIES) do
        settings.targetMarkProfiles[kind].showFrame=true
    end
    settings.viewerDefaultsV197=true
end
-- Upgrade once: keep the former enemy profile as the common marker appearance.
-- All classes of targets (friendly players, hostile players, NPCs) now use it.
if not settings.unifiedMarkV1912 then
    local old=settings.targetMarkProfiles.enemy
    settings.targetMarkProfiles.universal={}
    for k,v in pairs(old or {}) do settings.targetMarkProfiles.universal[k]=v end
    settings.targetMarkProfiles.universal.enabled=true
    settings.unifiedMarkV1912=true
end
local function selectedMarkProfile()
    if type(settings.targetMarkProfiles.universal)~="table" then
        local old=settings.targetMarkProfiles.enemy or {}
        local common={}
        for k,v in pairs(old) do common[k]=v end
        common.enabled=true
        settings.targetMarkProfiles.universal=common
    end
    return settings.targetMarkProfiles.universal
end
local renderEnemyRoster -- category-based inspect panel (enemy / friendly / mobs / spectator)
local renderTargetModeSelector -- always-on category selector above selected-target bar
-- Forward declarations: earlier rendering closures must refer to LOCAL functions.
-- Without these, an active target could cause "attempt to call global ... (a nil value)"
-- in the EVENT_SECOND_TIMER handler.
local classifyTargetKind
local inPreviewMode

local function clampNum(v,lo,hi,fallback)
    v=tonumber(v) or fallback
    return math.max(lo, math.min(hi, math.floor(v+0.5)))
end
-- Only migrate values that match v0.3 defaults; preserve manually customized sizes/colours.
-- A new layout deliberately removes the large window chrome, emulating compact Universe frames.
if tonumber(settings.hudStyleVersion or 0) < 4 then
    if settings.frameWidth == 430 then settings.frameWidth = DEFAULT.frameWidth end
    if settings.rowHeight == 72 then settings.rowHeight = DEFAULT.rowHeight end
    if settings.iconSize == 20 then settings.iconSize = DEFAULT.iconSize end
    if settings.hpColor == "#30BC59" then settings.hpColor = DEFAULT.hpColor end
    if settings.frameColor == "#87552B" then settings.frameColor = DEFAULT.frameColor end
    if settings.showClass == true then settings.showClass = false end
    settings.hudStyleVersion = 4
end
settings.frameWidth=clampNum(settings.frameWidth,240,720,DEFAULT.frameWidth)
settings.rowHeight=clampNum(settings.rowHeight,58,120,DEFAULT.rowHeight)
-- Independent distance between adjacent player frames (0 means flush).
settings.rowSpacing=clampNum(settings.rowSpacing,0,60,DEFAULT.rowSpacing)
settings.iconSize=clampNum(settings.iconSize,12,64,DEFAULT.iconSize)
if settings.buffPosition~="left" and settings.buffPosition~="right" then settings.buffPosition="right" end
if tonumber(settings.hudStyleVersion or 0)<5 then
    settings.showClass=true -- explicit v0.5 request: class IMAGE on the left
    if settings.iconSize == 17 then settings.iconSize=20 end
    settings.hudStyleVersion=5
end
-- v0.6: effects are left-aligned by default; cooldowns remain user-selectable.
if tonumber(settings.hudStyleVersion or 0)<6 then
    settings.buffPosition="left"
    settings.hudStyleVersion=6
end
if settings.cooldownPosition~="left" and settings.cooldownPosition~="bottom" then
    settings.cooldownPosition="bottom"
end
if settings.cooldownEntryMode~="auto" and settings.cooldownEntryMode~="manual" then
    settings.cooldownEntryMode="auto"
end
settings.buffIconSize=clampNum(settings.buffIconSize,12,72,DEFAULT.buffIconSize)
settings.buffIconCount=clampNum(settings.buffIconCount,1,10,DEFAULT.buffIconCount)
-- v0.7 migrates the previous left-to-right presentation into RTL once.
if tonumber(settings.hudStyleVersion or 0)<7 then
    settings.buffPosition="right"
    settings.hudStyleVersion=7
end
-- v0.8: preserve user-selected buff side and size; remove automatic defense presets.
-- Defenses formerly lived in a dedicated tab; tracked positive effects now use Buffs.
if tonumber(settings.hudStyleVersion or 0)<8 then
    settings.defenses={}
    settings.shields={}
    settings.hudStyleVersion=8
end
-- v0.9: visual icon size never changes the actual player bar width or height.
if tonumber(settings.hudStyleVersion or 0)<9 then
    settings.hudStyleVersion=9
end
if tonumber(settings.hudStyleVersion or 0)<10 then
    settings.hudStyleVersion=10
end
-- v1.3: migrate the old one-for-all side into individual effect placements.
-- The legacy key is kept only long enough to read v1.2 settings.
if type(settings.buffSides)~="table" then settings.buffSides={} end
if type(settings.debuffSides)~="table" then settings.debuffSides={} end
if tonumber(settings.hudStyleVersion or 0)<11 then
    local previousSide=settings.buffPosition=="left" and "left" or "right"
    for name,enabled in pairs(settings.trackedBuffs or {}) do
        if enabled and settings.buffSides[name]==nil then settings.buffSides[name]=previousSide end
    end
    for name,enabled in pairs(settings.trackedDebuffs or {}) do
        if enabled and settings.debuffSides[name]==nil then settings.debuffSides[name]=previousSide end
    end
    settings.hudStyleVersion=11
end
-- Discard stale/invalid placements and give newly tracked effects a default.
for _,entry in ipairs({{"trackedBuffs","buffSides"},{"trackedDebuffs","debuffSides"}}) do
    local tracked,sides=settings[entry[1]],settings[entry[2]]
    for name in pairs(sides) do
        if not tracked[name] then sides[name]=nil end
    end
    for name,enabled in pairs(tracked) do
        if enabled and sides[name]~="left" and sides[name]~="right" then sides[name]="right" end
    end
end
settings.buffPosition=nil -- no longer a global option
settings.effectAddKind=(settings.effectAddKind=="debuff") and "debuff" or "buff"
if type(settings.buffFlashRules)~="table" then settings.buffFlashRules={} end
if type(settings.debuffFlashRules)~="table" then settings.debuffFlashRules={} end
-- One-phase duration in seconds, 0.1 ... 1.0 with 100 ms granularity.
local function normalizeFlashPeriod(v)
    v=tonumber(v) or DEFAULT.flashPeriod
    return math.max(0.1,math.min(1.0,math.floor(v*10+0.5)/10))
end
settings.flashPeriod=normalizeFlashPeriod(settings.flashPeriod)
for _,key in ipairs({"buffFlashRules","debuffFlashRules","enemyBuffFlashRules","enemyDebuffFlashRules"}) do
    for name,rule in pairs(settings[key]) do
        if type(rule)~="table" then
            settings[key][name]=nil
        else
            rule.enabled=rule.enabled==true
            rule.frameBlink=rule.frameBlink==true
            rule.color=normalizedHex(rule.color) or ((key=="debuffFlashRules" or key=="enemyDebuffFlashRules") and "#FF3860" or "#FFD43B")
        end
    end
end
if type(settings.alertBuffs)~="table" then settings.alertBuffs={} end
if type(settings.alertControls)~="boolean" then settings.alertControls=true end
if type(settings.alertDispellable)~="boolean" then settings.alertDispellable=true end
-- Previous v0.5 overrides were numbers. They stay as manually specified seconds.
for name, value in pairs(settings.cooldowns or {}) do
    if value==true then settings.cooldowns[name]="auto" end
end

-- Persist the name catalog independently of audience selection. An effect can
-- have both audience checkboxes cleared and still stay editable in the list.
if type(settings.effectCatalog)~="table" then settings.effectCatalog={} end
for _,listKey in ipairs({"trackedBuffs","trackedDebuffs","enemyTrackedBuffs","enemyTrackedDebuffs"}) do
    for name,enabled in pairs(settings[listKey] or {}) do
        if enabled then settings.effectCatalog[name]=true end
    end
end
-- Friendly and hostile units have independent tracked effects, sides and colours.
-- Legacy trackedBuffs/trackedDebuffs remain the FRIENDLY configuration.
local function scopedEffectKey(page,scope)
    local foe=(scope=="enemy")
    if page=="Buffs" then return foe and "enemyTrackedBuffs" or "trackedBuffs" end
    if page=="Debuffs" then return foe and "enemyTrackedDebuffs" or "trackedDebuffs" end
end
local function effectSideKeyForPage(page,scope)
    local foe=((scope or HUD.effectScope)=="enemy")
    if page=="Buffs" then return foe and "enemyBuffSides" or "buffSides" end
    if page=="Debuffs" then return foe and "enemyDebuffSides" or "debuffSides" end
end
local function effectSide(effect,scope)
    if not effect or not effect.name then return "right" end
    local key=effectSideKeyForPage(effect.kind=="debuff" and "Debuffs" or "Buffs",scope or "ally")
    return settings[key][effect.name]=="left" and "left" or "right"
end
local function flashKeyForPage(page,scope)
    local foe=((scope or HUD.effectScope)=="enemy")
    if page=="Buffs" then return foe and "enemyBuffFlashRules" or "buffFlashRules" end
    if page=="Debuffs" then return foe and "enemyDebuffFlashRules" or "debuffFlashRules" end
end
local function getFlashRule(page,name,create,scope)
    local key=flashKeyForPage(page,scope)
    if not key or not name then return nil end
    local rule=settings[key][name]
    if not rule and create then
        rule={enabled=false,frameBlink=false,color=(page=="Debuffs" and "#FF3860" or "#FFD43B")}
        settings[key][name]=rule
    end
    return rule
end
local function getEffectFlashRule(effect,scope)
    if not effect or not effect.name then return nil end
    local page=effect.kind=="debuff" and "Debuffs" or "Buffs"
    local rule=getFlashRule(page,effect.name,false,scope or "ally")
    return (rule and (rule.enabled or rule.frameBlink)) and rule or nil
end

local function saveCfg()
    -- Do not overwrite DnD:* placement keys stored in the same config section.
    local stored = userMods.GetGlobalConfigSection(common.GetAddonName()) or {}
    for k,v in pairs(settings) do stored[k] = v end
    stored.buffPosition=nil -- legacy global side was replaced in v1.3
    -- Retired in v1.9.3: one marker toggle for every selected unit.
    stored.showTargetMarkEnemies=nil
    stored.showTargetMarkAllies=nil
    userMods.SetGlobalConfigSection(common.GetAddonName(), stored)
end
-- Only known user options are exported; screen-specific DnD coordinates are excluded.
local SHARE_EFFECT_KEYS={effectCatalog=true,trackedBuffs=true,trackedDebuffs=true,buffSides=true,debuffSides=true,
    buffFlashRules=true,debuffFlashRules=true,enemyTrackedBuffs=true,enemyTrackedDebuffs=true,enemyBuffSides=true,enemyDebuffSides=true,enemyBuffFlashRules=true,enemyDebuffFlashRules=true,alertBuffs=true,alertControls=true,
    alertDispellable=true,alertColor=true,flashPeriod=true}
local SHARE_COOLDOWN_KEYS={cooldowns=true,showCooldowns=true,cooldownPosition=true,cooldownEntryMode=true}
local SHARE_GENERAL_KEYS={showGroup=true,showTargeters=true,targeterMode=true,frameWidth=true,rowHeight=true,rowSpacing=true,
    iconSize=true,buffIconSize=true,buffIconCount=true,showClass=true,showHpPercent=true,
    colorMode=true,hpColor=true,shieldColor=true,frameColor=true,
    showTargetMark=true,targetMarkProfiles=true,showEnemyRoster=true,showTargetSelector=true,rosterMode=true,overviewClickTarget=true,overviewPageSize=true,overviewWidth=true,overviewRowHeight=true,overviewRowGap=true,overviewShowClass=true,overviewShowHpPercent=true,overviewV199=true,
    targetMarkStyle=true,targetMarkColorMode=true,targetMarkColor=true,
    targetMarkSize=true,targetMarkOffsetX=true,targetMarkOffsetY=true,targetMarkPulse=true}
local SHARE_LIST_KEYS={effectCatalog=true,trackedBuffs=true,trackedDebuffs=true,alertBuffs=true,cooldowns=true,
    buffSides=true,debuffSides=true,buffFlashRules=true,debuffFlashRules=true,enemyTrackedBuffs=true,enemyTrackedDebuffs=true,enemyBuffSides=true,enemyDebuffSides=true,enemyBuffFlashRules=true,enemyDebuffFlashRules=true}
local SHARE_FIELDS={}
for k in pairs(SHARE_EFFECT_KEYS) do SHARE_FIELDS[k]=true end
for k in pairs(SHARE_COOLDOWN_KEYS) do SHARE_FIELDS[k]=true end
for k in pairs(SHARE_GENERAL_KEYS) do SHARE_FIELDS[k]=true end
local function shareAllowed(scope,key)
    return (scope=="all" and SHARE_FIELDS[key]) or
        (scope=="effects" and SHARE_EFFECT_KEYS[key]) or
        (scope=="cooldowns" and SHARE_COOLDOWN_KEYS[key])
end
local function shareLabel(scope)
    return ({all="ВСЁ",effects="БАФЫ / ДЕБАФЫ",cooldowns="ОТКАТЫ"})[scope] or "?"
end
local function copyTree(value)
    if type(value)~="table" then return value end
    local result={}
    for k,v in pairs(value) do result[k]=copyTree(v) end
    return result
end
local function exportSnapshot(scope)
    local result={}
    for key in pairs(SHARE_FIELDS) do
        if shareAllowed(scope,key) then result[key]=copyTree(settings[key]) end
    end
    return result
end
local function validShareValue(key,v)
    local original=DEFAULT[key]
    if type(original)~="table" then
        if type(v)~=type(original) then return false end
        if key=="rosterMode" then return ROSTER_MODE_LABELS[v]~=nil end
        if type(v)=="number" then return v>=0 and v<100000 end
        if type(v)=="string" then return #v<=40 end
        return true
    end
    if type(v)~="table" then return false end
    if key=="targetMarkProfiles" then
        for _,kind in ipairs(MARK_CATEGORIES) do
            local profile=v[kind]
            if type(profile)~="table" then return false end
            for _,field in ipairs({"enabled","showFrame","style","colorMode","color","size","offsetX","offsetY","pulse"}) do
                if profile[field]==nil then return false end
            end
        end
    end
    local count=0
    for name,entry in pairs(v) do
        count=count+1
        if count>600 or type(name)~="string" or #name==0 or #name>240 then return false end
        if key=="targetMarkProfiles" then
            if name~="enemy" and name~="ally" and name~="mob" and name~="universal" then return false end
            if type(entry)~="table" then return false end
            for field,value in pairs(entry) do
                if field=="enabled" or field=="showFrame" or field=="pulse" then
                    if type(value)~="boolean" then return false end
                elseif field=="style" then
                    if not MARK_STYLES[value] then return false end
                elseif field=="colorMode" then
                    if value~="custom" and value~="class" then return false end
                elseif field=="color" then
                    if not normalizedHex(value) then return false end
                elseif field=="size" then
                    if type(value)~="number" or value<50 or value>300 then return false end
                elseif field=="offsetX" then
                    if type(value)~="number" or value < -60 or value>60 then return false end
                elseif field=="offsetY" then
                    if type(value)~="number" or value < -30 or value>80 then return false end
                else return false end
            end
        elseif key=="cooldowns" then
            if not (entry=="auto" or (type(entry)=="number" and entry>0 and entry<100000)) then return false end
        elseif key=="buffSides" or key=="debuffSides" or key=="enemyBuffSides" or key=="enemyDebuffSides" then
            if entry~="left" and entry~="right" then return false end
        elseif key=="buffFlashRules" or key=="debuffFlashRules" or key=="enemyBuffFlashRules" or key=="enemyDebuffFlashRules" then
            if type(entry)~="table" or type(entry.enabled)~="boolean" or not normalizedHex(entry.color) then return false end
            if entry.frameBlink~=nil and type(entry.frameBlink)~="boolean" then return false end
            for k in pairs(entry) do if k~="enabled" and k~="color" and k~="frameBlink" then return false end end
        elseif type(entry)~="boolean" then
            return false
        end
    end
    return true
end
local function verifyShareData(packet)
    if type(packet)~="table" or type(packet.data)~="table" then return nil,"Не найдены данные" end
    local count=0
    for key,v in pairs(packet.data) do
        if not SHARE_FIELDS[key] or not shareAllowed(packet.scope,key) then
            return nil,"Неизвестное поле: "..tostring(key)
        end
        if not validShareValue(key,v) then return nil,"Недопустимое поле: "..tostring(key) end
        count=count+1
    end
    if count==0 then return nil,"Профиль пуст" end
    return true
end
local function profileCount(data)
    local a,b,c=0,0,0
    for _ in pairs(data.trackedBuffs or {}) do a=a+1 end
    for _ in pairs(data.trackedDebuffs or {}) do b=b+1 end
    for _ in pairs(data.cooldowns or {}) do c=c+1 end
    return "Бафы: "..a.."; дебафы: "..b.."; КД: "..c
end
local function applySharedData(packet,mode)
    if mode=="replace" then
        for key,v in pairs(packet.data) do settings[key]=copyTree(v) end
    else
        -- Merge inserts missing named effects/CDs but preserves local colours and sizes.
        for key,v in pairs(packet.data) do
            if SHARE_LIST_KEYS[key] then
                if type(settings[key])~="table" then settings[key]={} end
                for name,rule in pairs(v) do
                    if settings[key][name]==nil then settings[key][name]=copyTree(rule) end
                end
            end
        end
    end
    -- Old APH1 profiles do not contain effectCatalog. Rebuild it from all
    -- four legacy effect tables so imported effects remain editable.
    if type(settings.effectCatalog)~="table" then settings.effectCatalog={} end
    if mode=="replace" and packet.data.effectCatalog==nil and
       (packet.scope=="all" or packet.scope=="effects") then
        settings.effectCatalog={}
    end
    for _,key in ipairs({"trackedBuffs","trackedDebuffs","enemyTrackedBuffs","enemyTrackedDebuffs"}) do
        for name,on in pairs(settings[key] or {}) do
            if on then settings.effectCatalog[name]=true end
        end
    end
    settings.frameWidth=clampNum(settings.frameWidth,240,720,DEFAULT.frameWidth)
    settings.rowHeight=clampNum(settings.rowHeight,58,120,DEFAULT.rowHeight)
    settings.rowSpacing=clampNum(settings.rowSpacing,0,60,DEFAULT.rowSpacing)
    settings.iconSize=clampNum(settings.iconSize,12,64,DEFAULT.iconSize)
    settings.buffIconSize=clampNum(settings.buffIconSize,12,72,DEFAULT.buffIconSize)
    settings.buffIconCount=clampNum(settings.buffIconCount,1,10,DEFAULT.buffIconCount)
    settings.flashPeriod=normalizeFlashPeriod(settings.flashPeriod)
    settings.overviewWidth=clampNum(settings.overviewWidth,220,720,318)
    settings.overviewRowHeight=clampNum(settings.overviewRowHeight,24,80,36)
    settings.overviewRowGap=clampNum(settings.overviewRowGap,0,25,1)
    if not ROSTER_MODE_LABELS[settings.rosterMode] then settings.rosterMode="enemy" end
    for _,key in ipairs({"hpColor","shieldColor","frameColor","alertColor"}) do
        settings[key]=normalizedHex(settings[key]) or DEFAULT[key]
    end
    if settings.colorMode~="single" and settings.colorMode~="class" then settings.colorMode=DEFAULT.colorMode end
    if settings.cooldownPosition~="left" and settings.cooldownPosition~="bottom" then settings.cooldownPosition=DEFAULT.cooldownPosition end
    if settings.cooldownEntryMode~="auto" and settings.cooldownEntryMode~="manual" then settings.cooldownEntryMode="auto" end
    for _,kind in ipairs(MARK_CATEGORIES) do
        local profile=settings.targetMarkProfiles[kind]
        if type(profile)~="table" then
            settings.targetMarkProfiles[kind]={enabled=true,showFrame=(kind=="enemy"),style="classic",colorMode="custom",color="#FFE533",size=100,offsetX=0,offsetY=0,pulse=false}
        end
    end
    if type(settings.targetMarkProfiles.universal)~="table" then
        settings.targetMarkProfiles.universal=copyTree(settings.targetMarkProfiles.enemy)
        settings.targetMarkProfiles.universal.enabled=true
    end
    for _,key in ipairs({"buffSides","debuffSides","enemyBuffSides","enemyDebuffSides"}) do
        if type(settings[key])~="table" then settings[key]={} end
        local tracked=settings[(key=="buffSides" and "trackedBuffs") or (key=="enemyBuffSides" and "enemyTrackedBuffs") or (key=="enemyDebuffSides" and "enemyTrackedDebuffs") or "trackedDebuffs"]
        for name in pairs(settings[key]) do if not tracked[name] then settings[key][name]=nil end end
        for name in pairs(tracked) do if settings[key][name]==nil then settings[key][name]="right" end end
    end
    saveCfg()
end
HUD.shareExportScope="all"
HUD.shareImportMode="merge"
HUD.shareValidated=nil
HUD.shareValidatedText=nil
HUD.shareStatus="Сначала сформируй код или вставь код для импорта."
local function currentShareCode()
    local w=HUD.widgets.shareImportBox
    if not w then return "" end
    local ok, raw=pcall(function() return w:GetText() end)
    if not ok then return "" end
    local valid, ascii=pcall(userMods.FromWString,raw)
    if not valid then return "" end
    return tostring(ascii or ""):gsub("%s","")
end
local function checkSharedCode()
    HUD.shareValidated=nil
    HUD.shareValidatedText=nil
    local code=currentShareCode()
    if code=="" then return nil,"Вставь код APH1" end
    local packet,err=APH_CodeExchange.Decode(code)
    if not packet then return nil,err end
    local ok,reason=verifyShareData(packet)
    if not ok then return nil,reason end
    HUD.shareValidated=packet
    HUD.shareValidatedText=code
    return packet
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end
local function str(v)
    if v == nil then return "" end
    local ok, txt = pcall(userMods.FromWString, v)
    if ok and txt then return tostring(txt) end
    return tostring(v)
end
local function ws(t)
    if type(t) == "string" then return userMods.ToWString(t) end
    return t
end
local function clean(t)
    t = str(t)
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end
local function short(t, limit)
    t=str(t)
    if #t > limit * 2 then return string.sub(t,1,limit * 2).."..." end
    return t
end
local function setTxt(w,t)
    if w and w:IsValid() then w:SetVal("value", ws(tostring(t or ""))) end
end
local function setBtn(w,t)
    if w and w:IsValid() then w:SetVal("button_label", ws(t)) end
end
local function pos(w,x,y,width,height)
    local p = w:GetPlacementPlain()
    p.alignX = WIDGET_ALIGN_LOW; p.alignY = WIDGET_ALIGN_LOW
    p.posX = x or 0; p.highPosX = x or 0
    p.posY = y or 0; p.highPosY = y or 0
    if width then p.sizeX = width end
    if height then p.sizeY = height end
    w:SetPlacementPlain(p)
end
local function make(parent, tpl, name, x,y,w,h)
    local base = mainForm:GetChildChecked(tpl, true)
    if not base then return nil end
    local child = parent:CreateChildByDesc(base:GetWidgetDesc())
    child:SetName(name)
    pos(child,x,y,w,h)
    child:Show(true)
    return child
end
local function panel(parent,name,x,y,w,h,color,template)
    local p=make(parent,template or "PnlSolidNC",name,x,y,w,h)
    if p and color then p:SetBackgroundColor(color) end
    return p
end
local function label(parent,name,text,x,y,w,h)
    local t=make(parent,"TM_TxtL",name,x,y,w,h or 20)
    setTxt(t,text)
    return t
end
local function button(parent,name,text,x,y,w,h)
    local b=make(parent,"BtnBrown",name,x,y,w,h)
    setBtn(b,text)
    return b
end
local function numberShort(n)
    if type(n)~="number" then return "?" end
    if n >= 1000000 then return string.format("%.1fM",n/1000000) end
    if n >= 1000 then return string.format("%.0fk",n/1000) end
    return tostring(math.floor(n))
end

local function roster()
    local out={}
    local r = safeCall(raid.IsExist)
    local g = safeCall(group.IsExist)
    if r then
        local groups = safeCall(raid.GetMembers) or {}
        for _,members in ipairs(groups) do
            for _,m in ipairs(members) do
                if m and m.name then table.insert(out,m) end
            end
        end
    elseif g then
        local members = safeCall(group.GetMembers) or {}
        for _,m in ipairs(members) do
            if m and m.name then table.insert(out,m) end
        end
    end
    if #out==0 then
        local id=safeCall(avatar.GetId)
        if id then
            table.insert(out,{ id=id, name=safeCall(object.GetName,id) or "Вы",
                className=safeCall(avatar.GetClass) or "UNKNOWN" })
        end
    end
    return out
end
local function syncRoster()
    local fresh = roster()
    local new, known={},{ }
    for i=1,math.min(#fresh,HUD.MAX_MEMBERS) do
        local m=fresh[i]
        if m and m.id then
            local name=clean(m.name)
            local classInfo = (unit and unit.GetClass) and safeCall(unit.GetClass,m.id) or nil
            local cls = str((classInfo and classInfo.className) or m.className or "UNKNOWN")
            local member={id=m.id,name=name,className=cls}
            new[#new+1]=member; known[m.id]=member
        end
    end
    HUD.roster=new; HUD.byId=known
    for id in pairs(HUD.buffOrder) do
        if not known[id] then
            HUD.buffOrder[id]=nil
            HUD.buffTimerCache[id]=nil
        end
    end
    -- Personal events only for current party: health/buff updates arrive without 1s polling.
    local events={"EVENT_OBJECT_HEALTH_CHANGED","EVENT_OBJECT_BUFF_ADDED",
        "EVENT_OBJECT_BUFF_REMOVED","EVENT_OBJECT_BUFF_CHANGED"}
    if common.EnablePersonalEvent and common.DisablePersonalEvent then
        for id in pairs(HUD.personalSubscribed) do
            if not known[id] then
                for _,eventName in ipairs(events) do
                    pcall(common.DisablePersonalEvent,eventName,id)
                end
                HUD.personalSubscribed[id]=nil
            end
        end
        for id in pairs(known) do
            if not HUD.personalSubscribed[id] then
                for _,eventName in ipairs(events) do
                    pcall(common.EnablePersonalEvent,eventName,id)
                end
                HUD.personalSubscribed[id]=true
            end
        end
    end
end
local function getEffects(id)
    local found={}
    if not id or not safeCall(object.IsExist,id) then return found end
    local order=HUD.buffOrder[id] or {}
    HUD.buffOrder[id]=order
    local cache=HUD.buffTimerCache[id] or {}
    HUD.buffTimerCache[id]=cache
    local seen, seenIds={},{}
    local function push(buffId,b)
        if not (b and b.name) then return end
        local name=clean(b.name)
        if name=="" then return end
        if not order[name] then
            HUD.buffSequence=HUD.buffSequence+1
            order[name]=HUD.buffSequence
        end
        seen[name]=true
        if b.texture then HUD.effectTextureCache[name]=b.texture end
        if buffId then seenIds[buffId]=true end
        -- Universe uses remainingMs/durationMs plus GetBuffDynamicInfo for live remaining time.
        local dynamic= safeCall(object.GetBuffDynamicInfo,buffId)
        local rawMs=tonumber(dynamic and dynamic.remainingMs)
        if not rawMs then rawMs=tonumber(b.remainingMs) end
        local durationMs=tonumber(b.durationMs)
        local remainingMs
        if rawMs and rawMs>0 and (not durationMs or durationMs>0) then
            local previous=cache[buffId]
            local delta=previous and math.max(0,HUD.clockMs-(previous.atMs or 0)) or 0
            if previous and delta>0 and rawMs>=previous.rawMs-25 then
                -- Some clients return an unchanged snapshot; interpolate its expiry
                -- using the 100ms UI clock instead of waiting for the next second.
                remainingMs=math.max(0,previous.remainingMs-delta)
            else
                remainingMs=rawMs
            end
            cache[buffId]={rawMs=rawMs,remainingMs=remainingMs,atMs=HUD.clockMs}
        elseif rawMs then
            remainingMs=math.max(0,rawMs)
            cache[buffId]=nil
        end
        found[name]={name=name,positive=b.isPositive,texture=b.texture,
            stacks=b.stackCount or 1,buffId=buffId,producer=b.producer,
            groups=type(b.groups)=="table" and b.groups or {},
            remainingMs=remainingMs,durationMs=durationMs,order=order[name]}
    end
    local infos=safeCall(object.GetBuffsInfo,id,true,true)
    if type(infos)=="table" then
        for buffId,b in pairs(infos) do push(buffId,b) end
    else
        for _,buffId in pairs(safeCall(object.GetBuffs,id) or {}) do
            push(buffId,safeCall(object.GetBuffInfo,buffId))
        end
    end
    for name in pairs(order) do if not seen[name] then order[name]=nil end end
    for buffId in pairs(cache) do if not seenIds[buffId] then cache[buffId]=nil end end
    return found
end
-- Universe checks these specific buff groups for dispellable effects and controls.
local function hasAlertEffect(effects)
    for name,b in pairs(effects or {}) do
        if settings.alertBuffs[name] then return true end
        local g=b.groups or {}
        if not b.positive then
            if settings.alertControls and (g.controls or g.stuns or g.Disarms or
                g.fears or g.sleep or g.sleeps) then return true end
            if settings.alertDispellable and (g.magics or g.stackablemagics) then
                return true
            end
        end
    end
    return false
end
-- Buff/debuff timer: keep the original whole seconds/minutes display.
-- During the *last* second show tenths: 1s -> 0.9 -> 0.8 -> ... 0.1.
-- The clock ticks every 100 ms; this is not true millisecond accuracy.
local function formatEffectTime(ms,iconSize)
    ms=tonumber(ms)
    if not ms or ms<=0 then return nil end
    if ms<1000 then
        local tenths=math.max(1,math.floor(ms/100))
        return string.format("0.%d",tenths)
    end
    local seconds=math.ceil(ms/1000)
    if seconds>=3600 then return tostring(math.ceil(seconds/3600)).."ч" end
    if seconds>=60 then return tostring(math.ceil(seconds/60)).."м" end
    return tostring(seconds).."с"
end
-- v1.9.9: the dropdown belongs to the INDEPENDENT visible-unit roster,
-- never to the selected target bar. No target selection occurs here.
renderTargetModeSelector=function()
    local frame=HUD.enemyRosterFrame
    local popup=HUD.targetModeMenu
    if not frame then return end
    local visible=(settings.showEnemyRoster==true)
    if not visible then
        if popup then popup:Show(false) end
        return
    end
    local mode=settings.rosterMode or "enemy"
    if HUD.overviewModeButton then
        setBtn(HUD.overviewModeButton,HUD.targetModeMenuOpen and "^" or "v")
    end
    if popup then
        local ok,rect=pcall(function() return frame:GetPlacementPlain() end)
        if ok and rect then
            local x=tonumber(rect.posX) or 0
            local y=tonumber(rect.posY) or 0
            pos(popup,x+4,y+28,settings.overviewWidth-14,140)
        end
        popup:Show(HUD.targetModeMenuOpen==true)
        for _,kind in ipairs(ROSTER_MODES) do
            local btn=HUD.targetModeButtons and HUD.targetModeButtons[kind]
            if btn then
                setBtn(btn,(mode==kind and "[+] " or "    ")..ROSTER_MODE_LABELS[kind])
            end
        end
    end
end

-- v1.9.10: The redundant selected-target panel has been removed entirely.
-- Do not draw a separate frame for the currently selected target. The 3D world
-- marker still follows avatar.GetTarget(), and the visible-unit OVERVIEW
-- remains a separate, category-filtered list with no automatic target change.

-- v1.9.9: Overview is based on the entire list of visible units, never on
-- avatar.GetTarget(). Changing filters cannot replace or select the target.
renderEnemyRoster=function()
    local frame=HUD.enemyRosterFrame
    if not frame then return end
    local shown=(settings.showEnemyRoster==true)
    frame:Show(shown)
    if not shown then
        HUD.targetModeMenuOpen=false
        if HUD.targetModeMenu then HUD.targetModeMenu:Show(false) end
        return
    end
    local mode=settings.rosterMode or "enemy"
    local preview=inPreviewMode()
    local entries={}
    if preview then
        local classes={"WARRIOR","MAGE","PRIEST","STALKER","BARD","ENGINEER"}
        for i=1,12 do
            local prefix=(mode=="mob" and "Моб " or mode=="ally" and "Союзник "
                or mode=="spectator" and "Игрок " or "Противник ")
            entries[i]={name=prefix..i,className=mode=="mob" and "UNKNOWN" or classes[(i-1)%#classes+1],
                hostile=(mode=="enemy" or mode=="mob"),hp=math.max(15,100-i*6),shield=i%3==0 and 28 or 0,preview=true}
        end
    else
        local seen={}
        local visibleUnits=safeCall(avatar.GetUnitList)
        if type(visibleUnits)=="table" then
            for _,id in pairs(visibleUnits) do
                if id and not seen[id] and safeCall(object.IsExist,id) then
                    seen[id]=true
                    local isPlayer=safeCall(unit.IsPlayer,id)==true
                    local hostile=safeCall(object.IsEnemy,id)==true
                    local isUnit=isPlayer or safeCall(object.IsUnit,id)==true
                    local include=(mode=="enemy" and isPlayer and hostile)
                        or (mode=="ally" and isPlayer and not hostile and id~=safeCall(avatar.GetId))
                        or (mode=="mob" and isUnit and not isPlayer)
                        or (mode=="spectator" and isPlayer)
                    if include then
                        local classInfo=safeCall(unit.GetClass,id)
                        local cls=type(classInfo)=="table" and classInfo.className or classInfo
                        entries[#entries+1]={id=id,name=clean(safeCall(object.GetName,id)),hostile=hostile,
                            className=tostring(str(cls or "UNKNOWN")):upper()}
                    end
                end
            end
        end
        -- Stable alphabetical order; no reordering when the avatar changes target.
        table.sort(entries,function(a,b)
            if (a.name or "")~=(b.name or "") then return (a.name or "")<(b.name or "") end
            return tostring(a.id)<tostring(b.id)
        end)
    end
    local size=settings.overviewPageSize or 12
    local totalPages=math.max(1,math.ceil(#entries/size))
    HUD.overviewPage=math.min(math.max(HUD.overviewPage or 1,1),totalPages)
    local startIndex=(HUD.overviewPage-1)*size+1
    local visibleCount=math.min(size,math.max(0,#entries-startIndex+1))
    local W=settings.overviewWidth
    local rowH=settings.overviewRowHeight
    local rowGap=settings.overviewRowGap
    local step=rowH+rowGap
    local height=31+visibleCount*step+(totalPages>1 and 25 or 0)
    local ok,rect=pcall(function() return frame:GetPlacementPlain() end)
    if ok and rect and (rect.sizeY~=height or rect.sizeX~=W) then
        rect.sizeX=W;rect.sizeY=height
        frame:SetPlacementPlain(rect)
    end
    pos(HUD.enemyRosterHeader,3,2,W-6,26)
    pos(HUD.enemyRosterTitle,7,3,math.max(40,W-67),21)
    pos(HUD.overviewModeButton,W-51,1,40,24)
    pos(HUD.enemyRosterEmpty,8,34,W-16,1)
    HUD.enemyRosterIDs={}
    setTxt(HUD.enemyRosterTitle,tostring(#entries))
    if HUD.overviewPageText then
        setTxt(HUD.overviewPageText,tostring(HUD.overviewPage).."/"..tostring(totalPages))
        HUD.overviewPageText:Show(totalPages>1)
    end
    if HUD.overviewPrev then
        pos(HUD.overviewPrev,4,height-25,37,23)
        HUD.overviewPrev:Show(totalPages>1)
    end
    if HUD.overviewNext then
        pos(HUD.overviewNext,W-51,height-25,45,23)
        HUD.overviewNext:Show(totalPages>1)
    end
    if HUD.overviewPageText then pos(HUD.overviewPageText,math.floor((W-65)/2),height-25,65,23) end
    HUD.enemyRosterEmpty:Show(false)
    local selectedTarget=safeCall(avatar.GetTarget)
    for i,row in ipairs(HUD.enemyRosterRows) do
        local e=i<=size and entries[startIndex+i-1] or nil
        local visible=e~=nil
        local contentW=W-9
        local classOn=settings.overviewShowClass~=false
        local classIndent=classOn and 30 or 4
        local barW=math.max(28,contentW-classIndent)
        local barH=rowH
        pos(row.bg,4,30+(i-1)*step,contentW,rowH)
        pos(row.class,3,math.max(1,math.floor((rowH-24)/2)),24,24)
        pos(row.shieldBg,classIndent,0,barW,5)
        pos(row.hpBg,classIndent,0,barW,barH)
        pos(row.name,classIndent+6,0,math.max(30,barW-65),barH)
        pos(row.hpText,classIndent+barW-62,0,58,math.min(21,barH))
        pos(row.click,0,0,contentW,rowH)
        local outline=row.targetOutline
        if outline then
            local highlight=visible and e.id~=nil and e.id==selectedTarget
            pos(outline.Top,0,0,contentW,2)
            pos(outline.Bottom,0,math.max(0,rowH-2),contentW,2)
            pos(outline.Left,0,0,2,rowH)
            pos(outline.Right,math.max(0,contentW-2),0,2,rowH)
            for _,edge in pairs(outline) do edge:Show(highlight) end
        end
        if not visible then row.frameFlashColor=nil end
        row.bg:Show(visible)
        row.click:Show(visible and settings.overviewClickTarget==true)
        if visible then
            HUD.enemyRosterIDs[i]=e.id
            local info=e.id and safeCall(object.GetHealthInfo,e.id)
            local hp=e.preview and e.hp or (type(info)=="table" and tonumber(info.valuePercents))
            local shield=e.preview and e.shield or (type(info)=="table" and tonumber(info.additionalPercents))
            local knownHp=type(hp)=="number"
            hp=knownHp and math.max(0,math.min(100,hp)) or 0
            shield=type(shield)=="number" and math.max(0,math.min(100,shield)) or 0
            -- A shield uses only the thin top strip. Without shield the
            -- coloured HP bar occupies the full height, edge to edge.
            local hpOffset=(shield>0) and 5 or 0
            local hpHeight=rowH-hpOffset
            pos(row.hpBg,classIndent,hpOffset,barW,hpHeight)
            pos(row.name,classIndent+6,hpOffset,math.max(30,barW-65),hpHeight)
            pos(row.hpText,classIndent+barW-62,hpOffset,58,math.min(21,hpHeight))
            setTxt(row.name,short(e.name~="" and e.name or "Цель",20))
            setTxt(row.hpText,knownHp and (tostring(math.floor(hp+.5)).."%") or "—")
            row.hpText:Show(settings.overviewShowHpPercent==true)
            local fillW=math.floor(barW*hp/100)
            pos(row.hpFill,0,0,fillW,hpHeight)
            pos(row.hpHighlight,0,0,fillW,1)
            pos(row.hpShade,0,math.max(1,hpHeight-5),fillW,5)
            pos(row.shieldFill,0,0,math.floor(barW*shield/100),5)
            row.shieldBg:Show(shield>0)
            row.shieldText:Show(false)
            local cls=tostring(e.className or "UNKNOWN"):upper()
            local classHex=OVERVIEW_CLASS_HEX[cls] or settings.frameColor
            -- Match the party-style class-coloured HP strips in the user's
            -- reference, rather than a uniform orange rectangle for everyone.
            row.baseColor={r=0,g=0,b=0,a=0}
            row.baseHpColor=color(classHex)
            row.frameFlashColor=nil
            row.bg:SetBackgroundColor(row.baseColor)
            -- Only unfilled HP is dark; a 100% bar occupies the entire strip.
            row.hpBg:SetBackgroundColor({r=.042,g=.046,b=.053,a=.94})
            row.hpFill:SetBackgroundColor(row.baseHpColor)
            local tex=classTextures[cls] or classTextures.UNKNOWN
            local loaded=tex and pcall(function() row.class:SetBackgroundTexture(tex) end)
            row.class:Show(classOn and loaded==true)
            local buffList={}
            if e.preview then
                -- Preview displays the configured effect scope as well, so the
                -- full-frame flash setting can be tested before entering PvP.
                local previewScope=((e.hostile==true or mode=="mob") and "enemy") or "ally"
                for _,definition in ipairs({{"Buffs","buff"},{"Debuffs","debuff"}}) do
                    for name,enabled in pairs(settings[scopedEffectKey(definition[1],previewScope)] or {}) do
                        if enabled then buffList[#buffList+1]={name=name,kind=definition[2]} end
                    end
                end
            end
            if e.id then
                local good,effects=pcall(getEffects,e.id)
                if good and type(effects)=="table" then
                    local scope=((e.hostile==true or mode=="mob") and "enemy") or "ally"
                    for name,b in pairs(effects) do
                        local positive=(b.positive==true)
                        local page=positive and "Buffs" or "Debuffs"
                        local listKey=scopedEffectKey(page,scope)
                        if settings[listKey][name] then
                            buffList[#buffList+1]={name=name,kind=positive and "buff" or "debuff",texture=b.texture,
                                order=b.order,remainingMs=b.remainingMs}
                        end
                    end
                    table.sort(buffList,function(a,b) return (a.order or 0)<(b.order or 0) end)
                end
            end
            for _,b in ipairs(buffList) do
                local scope=(e.hostile==true or mode=="mob") and "enemy" or "ally"
                local rule=getEffectFlashRule(b,scope)
                if rule and rule.frameBlink then row.frameFlashColor=rule.color;break end
            end
            if row.frameFlashColor and HUD.blinkPhase then
                row.bg:SetBackgroundColor(color(row.frameFlashColor))
                row.hpFill:SetBackgroundColor(color(row.frameFlashColor))
            end
            -- Keep effect art at the bottom-right, above the HP strip. More
            -- than one effect can be shown and each has its own expiry time.
            local iconSize=math.max(17,math.min(29,rowH-5))
            local maxVisible=math.min(#row.effects,settings.buffIconCount or 6)
            for k,slot in ipairs(row.effects) do
                local b=(k<=maxVisible) and buffList[k] or nil
                local artwork=b and (b.texture or HUD.effectTextureCache[b.name])
                local loaded=artwork and pcall(function() slot.icon:SetBackgroundTexture(artwork) end)
                local showIcon=(loaded==true)
                local iconX=classIndent+barW-2-iconSize-(k-1)*(iconSize+2)
                local iconY=rowH-iconSize
                pos(slot.icon,iconX,iconY,iconSize,iconSize)
                local timerH=math.max(10,math.min(13,math.floor(iconSize*.45)))
                pos(slot.timerBg,iconX,iconY+iconSize-timerH,iconSize,timerH)
                pos(slot.timer,iconX,iconY+iconSize-timerH,iconSize,timerH)
                slot.icon:Show(showIcon)
                slot.icon:SetBackgroundColor({r=1,g=1,b=1,a=1})
                local time=b and b.remainingMs and formatEffectTime(b.remainingMs,iconSize) or ""
                slot.expiresAtMs=(showIcon and b.remainingMs and b.remainingMs>0) and (HUD.clockMs+b.remainingMs) or nil
                slot.lastTimerText=time
                setTxt(slot.timer,time)
                slot.timerBg:Show(showIcon and time~="")
                slot.timer:Show(showIcon and time~="")
            end
        end
    end
    if renderTargetModeSelector then renderTargetModeSelector() end
end

local function matching(effects,listed,positive)
    local out={}
    for n,enabled in pairs(listed or {}) do
        local b=effects[n]
        if enabled and b and (positive==nil or b.positive==positive) then
            out[#out+1]=n
        end
    end
    table.sort(out)
    return out
end
local function compact(list,maxItems)
    maxItems=maxItems or 2
    local out={}
    for i=1,math.min(#list,maxItems) do out[#out+1]=short(list[i],18) end
    if #list>maxItems then out[#out+1]="+"..(#list-maxItems) end
    return table.concat(out," | ")
end
local CLASS_NAMES = {
    WARRIOR="Воин", PALADIN="Храмовник", MAGE="Волшебник", DRUID="Язычник",
    PSIONIC="Мистик", STALKER="Разведчик", PRIEST="Жрец",
    NECROMANCER="Некромант", BARD="Бард", ENGINEER="Инженер", WARLOCK="Демонолог"
}
local PREVIEW = {
    {name="Вы", className="WARRIOR", hpPct=92, shieldPct=68, cd={42,18,7}},
    {name="Союзник 2", className="PRIEST", hpPct=100, shieldPct=34, cd={12,28}},
    {name="Союзник 3", className="MAGE", hpPct=61, shieldPct=80, cd={56,21,8}},
    {name="Союзник 4", className="STALKER", hpPct=76, shieldPct=0, cd={15,43}},
    {name="Союзник 5", className="PALADIN", hpPct=48, shieldPct=26, cd={42,19,8}},
    {name="Союзник 6", className="ENGINEER", hpPct=83, shieldPct=12, cd={30,9}}
}
-- The user can switch between a preview roster and live party in the settings header.
-- Outside settings, the party HUD always returns to live mode.
inPreviewMode=function()
    return HUD.settingsFrame and HUD.settingsFrame:IsVisibleEx() and HUD.viewMode~="party"
end

-- Enemy-target panel (visible player enemies whose target is confirmed by the client).
-- Historical client APIs do not always expose OTHER players' targets: this is a
-- lower bound and cannot claim to know all opponents aiming at the avatar.
local TARGETER_COLUMNS=7
local TARGETER_MAX=35
local function scanTargeters()
    local result={}
    local me=safeCall(avatar.GetId)
    if not me then return result,0,0 end
    local visible=safeCall(avatar.GetUnitList)
    if type(visible)~='table' then return result,0,0 end
    local seen={}
    local checked=0
    local enemyPlayers=0
    for _,id in pairs(visible) do
        if id and id~=me and not seen[id] then
            seen[id]=true
            local exists=safeCall(object.IsExist,id)
            if exists and safeCall(unit.IsPlayer,id) and safeCall(object.IsEnemy,id) then
                enemyPlayers=enemyPlayers+1
                -- GetTarget has limited visibility on some game versions.
                local target=safeCall(unit.GetTarget,id)
                if target==nil then target=safeCall(unit.GetPrimaryTarget,id) end
                if target~=nil then checked=checked+1 end
                if target==me then
                    local cl=safeCall(unit.GetClass,id)
                    local className=type(cl)=='table' and cl.className or 'UNKNOWN'
                    result[#result+1]={id=id, className=str(className):upper()}
                end
            end
        end
    end
    table.sort(result,function(a,b)
        if a.className~=b.className then return a.className<b.className end
        return tostring(a.id)<tostring(b.id)
    end)
    return result,checked,enemyPlayers
end

-- The combat log lets us see WHO HURT US without selecting the attacker.
-- This is NOT equivalent to knowing who is currently targeting us.
-- Only player enemies that actually damaged the avatar are counted.
local ATTACK_WINDOW_MS=6000
local function onIncomingPlayerAttack(e)
    if type(e)~="table" then return end
    local me=safeCall(avatar.GetId)
    local source=e.source
    if not me or e.target~=me or not source or source==me then return end
    if not safeCall(object.IsExist,source) then return end
    if not safeCall(unit.IsPlayer,source) or not safeCall(object.IsEnemy,source) then return end
    local cl=safeCall(unit.GetClass,source)
    local cls=(type(cl)=="table" and cl.className or "UNKNOWN")
    HUD.enemyAttacks[source]={className=str(cls):upper(),lastMs=HUD.clockMs}
end
local function scanRecentAttackers()
    local now=HUD.clockMs
    local entries={}
    for id,record in pairs(HUD.enemyAttacks) do
        if now-(record.lastMs or 0)>=ATTACK_WINDOW_MS or not safeCall(object.IsExist,id) then
            HUD.enemyAttacks[id]=nil
        else
            entries[#entries+1]={id=id,className=record.className or "UNKNOWN"}
        end
    end
    table.sort(entries,function(a,b)
        if a.className~=b.className then return a.className<b.className end
        return tostring(a.id)<tostring(b.id)
    end)
    return entries
end

-- Each confirmed enemy has one class icon, with no player names. The
-- header always contains the TOTAL number, even when icons are capped.
-- Empty state is deliberately not described as proof that nobody targets us:
-- some client builds do not expose foreign players' targets at all.
local TARGETER_ABBR={
    WARRIOR="В",PALADIN="Х",MAGE="М",DRUID="Я",PSIONIC="Мс",
    STALKER="Р",PRIEST="Ж",NECROMANCER="Н",BARD="Б",
    ENGINEER="И",WARLOCK="Д"
}
local function renderTargeters()
    local frame=HUD.targetersFrame
    if not frame then return end
    local show=settings.showTargeters~=false
    frame:Show(show)
    if not show then return end
    local preview=inPreviewMode()
    local entries,checked,visible
    if preview then
        entries={
            {className='WARRIOR'},
            {className='MAGE'},
            {className='PRIEST'},
        }
        checked=3;visible=3
    elseif settings.targeterMode=="attacks" then
        entries=scanRecentAttackers()
        checked=#entries;visible=#entries
    else
        entries,checked,visible=scanTargeters()
    end
    HUD.targeterEntries=entries
    HUD.targetersChecked=checked
    local count=#entries
    local n=math.min(TARGETER_MAX,count)
    local rows=math.ceil(n/TARGETER_COLUMNS)
    local h=count==0 and 60 or (33+rows*33+5)
    local placement=frame:GetPlacementPlain()
    if placement.sizeX~=248 or placement.sizeY~=h then
        placement.sizeX=248;placement.sizeY=h
        frame:SetPlacementPlain(placement)
    end
    pos(HUD.targetersInner,2,27,244,h-29)
    local title = preview and ("ПРОСМОТР: "..count)
        or (settings.targeterMode=="attacks" and ("АТАКОВАЛИ (6с): "..count)
        or ("ЦЕЛЯТСЯ (выбр.): "..count))
    setTxt(HUD.targetersTitle,title)
    if count==0 then
        local hint = settings.targeterMode=="attacks" and "За последние 6с атак нет"
            or "Цели остальных врагов недоступны"
        setTxt(HUD.targetersFoot,hint)
        pos(HUD.targetersFoot,7,31,234,22)
        HUD.targetersFoot:Show(true)
    else
        HUD.targetersFoot:Show(false)
    end
    for i,slot in ipairs(HUD.targeterRows) do
        local entry=entries[i]
        local shown=(entry~=nil)
        slot.bg:Show(shown)
        slot.icon:Show(shown)
        slot.label:Show(false)
        if shown then
            local cls=entry.className or 'UNKNOWN'
            local x=9+((i-1)%TARGETER_COLUMNS)*34
            local y=31+math.floor((i-1)/TARGETER_COLUMNS)*33
            pos(slot.bg,x,y,29,29)
            pos(slot.icon,x+2,y+2,25,25)
            pos(slot.label,x+2,y+2,25,25)
            slot.bg:SetBackgroundColor(colorDark(CLASS_HEX[cls] or '#657387'))
            local texture=classTextures[cls] or classTextures.UNKNOWN
            local success=false
            if texture then
                success=pcall(function() slot.icon:SetBackgroundTexture(texture) end)
            end
            -- A small class abbreviation is shown only as a fallback when
            -- the client rejects a resource texture.
            if not success then
                slot.icon:Show(false)
                setTxt(slot.label,TARGETER_ABBR[cls] or '?')
                slot.label:Show(true)
            end
        end
    end
end


-- Selected-target marker: world-attached, not a fixed 2D overlay.
-- Uses the same public 3D attachment API as the supplied BuffAnnounce/Navodchik sources.
-- Failures are isolated so the rest of the party HUD stays functional.
classifyTargetKind=function(id)
    if not id then return nil end
    -- IsPlayer may return nil for unloaded entities; don't guess an enemy-player list.
    local player=(id==safeCall(avatar.GetId)) or (safeCall(unit.IsPlayer,id)==true)
    if not player then return "mob" end
    return safeCall(object.IsEnemy,id)==true and "enemy" or "ally"
end
local function markProfileFor(id)
    return selectedMarkProfile()
end

local function markColor(targetId)
    local prof=markProfileFor(targetId) or selectedMarkProfile()
    if prof.colorMode=="class" and targetId then
        local classInfo=safeCall(unit.GetClass,targetId)
        local cls=type(classInfo)=="table" and classInfo.className or classInfo
        cls=tostring(str(cls)):upper()
        return color(CLASS_HEX[cls] or prof.color)
    end
    return color(prof.color)
end
local function removeTargetMark()
    if HUD.markWidget then
        -- BuffAnnounce stops both effects before detaching the 3D widget.
        pcall(function() HUD.markWidget:FinishRotationEffect() end)
        pcall(function() HUD.markWidget:FinishResizeEffect() end)
        if HUD.markTargetId then
            pcall(object.DetachWidget3D,HUD.markTargetId,HUD.markWidget)
        end
        if HUD.markControl3D then
            pcall(function() HUD.markControl3D:RemoveWidget3D(HUD.markWidget) end)
        end
        pcall(function() HUD.markWidget:DestroyWidget() end)
    end
    HUD.markWidget=nil
    HUD.markIcon=nil
    HUD.markTargetId=nil
    HUD.markConfigSignature=nil
end
local function getMarkControl()
    if HUD.markControl3D then return HUD.markControl3D end
    local ok,c=pcall(function()
        return stateMainForm:GetChildChecked("MainAddonMainForm",false):GetChildChecked("MainScreenControl3D",false)
    end)
    if ok and c then HUD.markControl3D=c;return c end
    HUD.markError="3D-контрол игры недоступен"
    return nil
end
-- A 3D attach can fail without raising a Lua error when a remote player
-- has no loaded visual yet. The client reports that through EVENT_CANNOT_ATTACH_WIDGET_3D.
-- Seed AddWidget3D from the LOCAL avatar position (as Navodchik/BuffAnnounce
-- do), then bind the widget to the selected target's live visual object.
local function refreshTargetMark()
    if not settings.showTargetMark then
        removeTargetMark()
        HUD.markInfo="Метка выключена в настройках"
        return
    end
    local id=safeCall(avatar.GetTarget)
    if not id then
        removeTargetMark()
        HUD.markInfo="Цель не выбрана"
        return
    end
    local isPlayer=safeCall(unit.IsPlayer,id)==true
    if not safeCall(object.IsExist,id) then
        removeTargetMark()
        HUD.markInfo="Цель отсутствует в загруженных объектах (object.IsExist=false)"
        return
    end
    if not isPlayer and not safeCall(object.IsUnit,id) then
        removeTargetMark()
        HUD.markInfo="Выбранный объект не определён как игровое существо"
        return
    end
    if HUD.markRetryTarget~=id then
        HUD.markRetryTarget=id
        HUD.markRetryTick=0
        HUD.markAttachFailures=0
        HUD.markInfo=nil
        HUD.markError=nil
    end
    local category=classifyTargetKind(id)
    local prof=markProfileFor(id)
    if not prof then removeTargetMark();return end
    local enemy=safeCall(object.IsEnemy,id)==true
    local style=MARK_STYLES[prof.style] or MARK_STYLES.classic
    local texture=HUD.markTextures[style.texture]
    if not texture then
        HUD.markError="Не загружена текстура метки: "..style.texture
        removeTargetMark();return
    end
    local signature=table.concat({prof.style,prof.colorMode,
        prof.color,tostring(prof.size),tostring(prof.offsetX),
        tostring(prof.offsetY),tostring(prof.pulse)},"|")
    if HUD.markWidget and HUD.markTargetId==id and signature==HUD.markConfigSignature then return end
    if HUD.markRetryTick>HUD.tick then return end
    removeTargetMark()
    local ctl=getMarkControl()
    if not ctl then return end
    -- A target player can be selectable before GetPos(target) is available.
    -- Avatar's own position is enough for the INITIAL position of a 3D widget.
    local ownId=safeCall(avatar.GetId)
    local point=ownId and safeCall(object.GetPos,ownId)
    if not point then point=safeCall(object.GetPos,id) end
    if not point then
        HUD.markError="Нет стартовой 3D-позиции (себя и цели)"
        return
    end
    local ok,err=pcall(function()
        local template=mainForm:GetChildChecked("PnlSolidNC",true)
        if not template then error("Нет шаблона PnlSolidNC") end
        local container=mainForm:CreateWidgetByDesc(template:GetWidgetDesc())
        if not container then error("Не удалось создать 3D-виджет") end
        HUD.markWidget=container
        container:SetName("hud_WorldTargetMarker")
        local scale=prof.size/100
        local startSize=math.floor(style.startVirtual*scale+.5)
        local finishSize=math.floor(style.finishVirtual*scale+.5)
        -- Use the same root widget, foreground texture, blend and virtual-size
        -- effects as BuffAnnounce's eventAvatarTargetChanged().
        local placement=container:GetPlacementPlain()
        placement.posX=prof.offsetX
        placement.posY=0
        placement.sizeX=startSize
        placement.sizeY=startSize
        container:SetPlacementPlain(placement)
        container:SetTransparentInput(true)
        HUD.markIcon=container
        container:SetBackgroundTexture(texture)
        local tint=markColor(id)
        container:SetBackgroundColor(tint)
        local front=style.front and HUD.markTextures[style.front]
        if front then
            pcall(function() container:SetForegroundTexture(front) end)
            pcall(function() container:SetForegroundColor(tint) end)
            if style.front=="ClassicTargetHighlight" and BLEND_EFFECT_HIGHLIGHT then
                pcall(function() container:SetForegroundBlendEffect(BLEND_EFFECT_HIGHLIGHT) end)
            elseif BLEND_EFFECT_ALPHABLND then
                pcall(function() container:SetForegroundBlendEffect(BLEND_EFFECT_ALPHABLND) end)
            end
        end
        if prof.pulse and style.resizeSpeed>0 then
            local finish={posX=prof.offsetX,posY=0,sizeX=finishSize,sizeY=finishSize}
            pcall(function()
                container:PlayResizeEffectSequence({
                    {placement,finish,style.resizeSpeed,EA_SYMMETRIC_FLASH},cycled=true
                })
            end)
        end
        if prof.pulse and style.rotateSpeed>0 then
            pcall(function()
                container:PlayRotationEffectSequence({
                    {0,-2*math.pi,style.rotateSpeed,EA_MONOTONOUS_INCREASE},cycled=true
                })
            end)
        end
        -- The world dimensions must remain 2x2m; only the virtual widget
        -- scale changes. This fixes the massive, widely separated arrows.
        local added=ctl:AddWidget3D(container,{sizeX=2,sizeY=2},point,true,false,
            1000,WIDGET_3D_BIND_POINT_CENTER,1,1)
        if added==false then error("AddWidget3D отклонил метку") end
        HUD.markTargetId=id
        HUD.markLastAttemptTick=HUD.tick
        local attached=object.AttachWidget3D(id,ctl,container,
            (style.height or 0)+(prof.offsetY/10))
        if attached==false then error("AttachWidget3D отклонил метку") end
        container:Show(true)
        HUD.markConfigSignature=signature
        local targetName=str(safeCall(object.GetName,id))
        HUD.markInfo=(isPlayer and "Игрок" or "Существо")..
            (enemy and " / враг" or " / союзник")..
            (targetName~="" and (" / "..targetName) or "")..
            ": 3D-привязка запрошена"
        HUD.markError=nil
    end)
    if not ok then
        HUD.markError="Ошибка 3D: "..tostring(err)
        removeTargetMark()
        HUD.markRetryTick=HUD.tick+2
    end
end
-- This event reports only an OBJECT ID, not which addon's widget failed.
-- Consider it only immediately after our attach attempt for that same target.
local function onTargetMarkAttachFailed(e)
    local id=e and e.objectId
    if not id or id~=HUD.markTargetId or not HUD.markWidget then return end
    if HUD.tick-HUD.markLastAttemptTick>2 then return end
    HUD.markAttachFailures=HUD.markAttachFailures+1
    HUD.markError="Клиент отклонил 3D-метку на цели; попытка "..tostring(HUD.markAttachFailures)
    HUD.markInfo=nil
    removeTargetMark()
    HUD.markRetryTick=HUD.tick+(HUD.markAttachFailures<=3 and 1 or 5)
    if HUD.widgets.markStatus then
        setTxt(HUD.widgets.markStatus,"Статус: "..HUD.markError)
    end
end
local function onTargetMarkChanged()
    HUD.markRetryTick=0
    HUD.markAttachFailures=0
    HUD.markRetryTarget=nil
    refreshTargetMark()
end
local function pulseTargetMark()
    if not HUD.markIcon then return end
    local c=markColor(HUD.markTargetId)
    local prof=markProfileFor(HUD.markTargetId)
    if prof and prof.pulse then
        HUD.markPulseTick=(HUD.markPulseTick+1)%10
        c.a=(HUD.markPulseTick<5) and .60 or 1
    end
    pcall(function() HUD.markIcon:SetBackgroundColor(c) end)
end

local function clampPct(v)
    if type(v)~="number" then return nil end
    return math.max(0,math.min(100,v))
end
local function displayPct(v)
    return v and (tostring(math.floor(v+0.5)).."%") or "—"
end
-- v0.9: the health/shield bar is strictly fixed by the two frame size
-- controls. Large buff and cooldown icons are an independent overlay.
local function effectiveFrameWidth()
    return settings.frameWidth
end
local function rowMetrics()
    -- rowHeight controls the compact member bar + its baseline spacing.
    -- Neither buffIconSize nor iconSize changes shield/HP height.
    local frameH=math.max(43,settings.rowHeight-18)
    local shieldH=math.max(10,math.min(15,math.floor(frameH*.24)))
    local hpY=shieldH+4
    local hpH=math.max(20,frameH-hpY-3)
    local cdY=frameH+3
    local cdLeft=settings.cooldownPosition=="left" and settings.showCooldowns
    local sideW=cdLeft and (HUD.MAX_CAST_ICONS*(settings.iconSize+3)+10) or 0
    -- Adjustable gap measured AFTER all visible elements of the row.
    -- With cooldowns on the left (or disabled), 0 px makes the bars touch.
    -- Cooldowns beneath the bar need their own height, even at 0 px gap.
    -- Never enlarge the health/shield bars to fit cooldown icons.
    local cooldownBelow=settings.showCooldowns and not cdLeft
    local usedHeight=frameH+(cooldownBelow and (3+settings.iconSize) or 0)
    local stride=usedHeight+settings.rowSpacing
    return stride,shieldH,hpH,hpY,cdY,sideW,frameH
end
local function layoutRow(row)
    local W=effectiveFrameWidth()
    local H,shieldH,hpH,hpY,cdY,sideW,frameH=rowMetrics()
    local classW=settings.showClass and 27 or 0
    local barX=classW+3
    local barW=W-barX-4
    local cdSize=settings.iconSize -- never auto-shrink with bar width
    row.barX,row.barW,row.hpY,row.hpH=barX,barW,hpY,hpH
    row.shieldH,row.cdY,row.cdSize=shieldH,cdY,cdSize
    local rootX=sideW+2
    local rowY=26+(row.idx-1)*H
    pos(row.root,rootX,rowY,W,frameH)
    pos(row.inside,2,2,W-4,frameH-4)
    pos(row.accent,0,0,2,frameH)
    pos(row.classBg,3,shieldH+3,math.max(1,classW-4),math.min(38,hpH))
    pos(row.class,5,shieldH+6,math.max(1,classW-8),math.min(30,math.max(18,hpH-6)))
    row.classBg:Show(settings.showClass)
    row.class:Show(settings.showClass)
    pos(row.shieldBg,barX,3,barW,shieldH)
    pos(row.shieldFill,0,0,0,shieldH)
    pos(row.shieldTxt,barX,1,barW,shieldH+4)
    pos(row.hpBg,barX,hpY,barW,hpH)
    pos(row.hpFill,0,0,0,hpH)
    -- The name and HP percentage stay put; selected buffs may cover them.
    pos(row.name,barX+6,hpY+1,math.max(65,barW-10),hpH-2)
    pos(row.hpTxt,barX,hpY+1,barW,hpH-2)
    row.buffSlots=math.min(settings.buffIconCount,HUD.MAX_BUFF_ICONS)
    -- Geometry of buff icons is assigned during updateRow, because each
    -- selected effect may now be anchored to a different edge.
    for k,v in ipairs(row.buffIcons) do
        if k>row.buffSlots then
            v.back:Show(false);v.icon:Show(false);v.timeBg:Show(false);v.txt:Show(false)
            v.flashTint:Show(false);v.flashTop:Show(false);v.flashBottom:Show(false)
            v.flashLeft:Show(false);v.flashRight:Show(false)
        end
    end
    -- CD icons similarly keep their requested size; the member bar does not
    -- expand to accommodate their dimensions.
    local cdStep=cdSize+3
    if sideW==0 and HUD.MAX_CAST_ICONS>1 then
        cdStep=math.max(8,math.min(cdStep,
            math.floor(math.max(8,barW-cdSize-6)/(HUD.MAX_CAST_ICONS-1))))
    end
    for k,v in ipairs(row.cds) do
        local x,y
        if sideW>0 then
            x=rootX-8-k*(cdSize+3)
            y=rowY+math.max(2,math.floor((frameH-cdSize)/2))
        else
            x=rootX+barX+barW-4-cdSize-(k-1)*cdStep
            y=rowY+cdY
        end
        pos(v.back,x,y,cdSize,cdSize)
        pos(v.icon,x+1,y+1,math.max(8,cdSize-2),math.max(8,cdSize-2))
        pos(v.txt,x,y,cdSize,cdSize)
    end
    if row.target then pos(row.target,0,0,W,frameH) end
end
-- Place one icon independently of all other icons. Both edges fill inward:
-- LEFT side fills left->right, RIGHT side fills right->left. Size never
-- changes the parent HP/shield bars, and selected effects may cover names.
local function placeEffectIcon(row,v,index,side,countOnSide)
    local buffSize=settings.buffIconSize
    local span=math.max(8,row.barW-buffSize-8)
    local buffStep=buffSize+2
    if countOnSide>1 then
        buffStep=math.max(8,math.min(buffStep,math.floor(span/(countOnSide-1))))
    end
    local x
    if side=="left" then
        x=row.barX+4+(index-1)*buffStep
    else
        x=row.barX+row.barW-4-buffSize-(index-1)*buffStep
    end
    local y=math.max(1,row.hpY+row.hpH-buffSize-1)
    pos(v.back,x,y,buffSize,buffSize)
    pos(v.icon,x,y,buffSize,buffSize)
    local timerH=math.max(12,math.min(18,math.floor(buffSize*.43)))
    pos(v.flashTint,x,y,buffSize,buffSize)
    local stroke=math.max(2,math.min(4,math.floor(buffSize/16)))
    pos(v.flashTop,x,y,buffSize,stroke)
    pos(v.flashBottom,x,y+buffSize-stroke,buffSize,stroke)
    pos(v.flashLeft,x,y,stroke,buffSize)
    pos(v.flashRight,x+buffSize-stroke,y,stroke,buffSize)
    pos(v.timeBg,x,y+buffSize-timerH,buffSize,timerH)
    pos(v.txt,x,y+buffSize-timerH,buffSize,timerH)
end
local function layoutMiniBars()
    -- Nothing to synchronize for the party: toolbar and rows share a parent.
    -- The overview remains an independent panel with its own controls.
    if HUD.enemyRosterHeader and HUD.overviewModeButton then
        pos(HUD.overviewModeButton,settings.overviewWidth-51,1,40,24)
        pos(HUD.enemyRosterTitle,7,3,math.max(40,settings.overviewWidth-67),21)
    end
end

local function reflowAll()
    if not HUD.groupFrame then return end
    local H,_,_,_,_,sideW=rowMetrics()
    local W=effectiveFrameWidth()+sideW+4
    local p=HUD.groupFrame:GetPlacementPlain()
    p.sizeX=W
    HUD.groupFrame:SetPlacementPlain(p)
    if HUD.groupDrag then
        pos(HUD.groupDrag,sideW+2,1,effectiveFrameWidth(),22)
        if HUD.groupDragText then
            pos(HUD.groupDragText,7,1,math.max(30,effectiveFrameWidth()-14),20)
        end
        if HUD.groupMiniSettings then pos(HUD.groupMiniSettings,math.max(3,effectiveFrameWidth()-62),1,27,21) end
        if HUD.groupMiniLock then pos(HUD.groupMiniLock,math.max(32,effectiveFrameWidth()-33),1,27,21) end
    end
    for _,row in ipairs(HUD.rows) do layoutRow(row) end
    layoutMiniBars()
end
local function updateRow(row,m,onlyVital)
    if not m then
        row.alertActive=false
        row.frameFlashColor=nil
        row.root:Show(false)
        for _,slot in ipairs(row.buffIcons or {}) do slot.flashEnabled=false end
        for _,v in ipairs(row.cds) do
            v.back:Show(false);v.icon:Show(false);v.txt:Show(false)
        end
        return
    end
    row.root:Show(true)
    local preview=m.preview==true
    local cls=tostring(m.className or "UNKNOWN"):upper()
    local classColor=CLASS_HEX[cls] or CLASS_HEX.WARRIOR
    local frameColor=settings.colorMode=="class" and classColor or settings.frameColor
    local effects={}
    if not preview and not onlyVital then
        effects=getEffects(m.id)
        row.alertActive=hasAlertEffect(effects)
    elseif preview then
        -- Visible demonstration of the alert colour on one preview frame.
        row.alertActive=(row.idx==3)
    end
    local alert=row.alertActive==true
    local finalFrameColor=alert and settings.alertColor or frameColor
    row.root:SetBackgroundColor(color(finalFrameColor))
    row.inside:SetBackgroundColor(colorDark(alert and settings.alertColor or (settings.colorMode=="class" and classColor or "#B86A41")))
    row.accent:SetBackgroundColor(color(finalFrameColor))
    -- Light empty-bar contrast makes BLACK HP on control clearly visible.
    row.hpBg:SetBackgroundColor(alert and {r=.60,g=.62,b=.66,a=.95} or COLORS.hidden)
    row.classBg:SetBackgroundColor(colorDark(classColor))
    local classTexture=classTextures[cls] or classTextures.UNKNOWN
    if row.lastClassTexture~=classTexture then
        if classTexture then pcall(function() row.class:SetBackgroundTexture(classTexture) end) end
        row.lastClassTexture=classTexture
    end
    setTxt(row.name,short(m.name,17)) -- inside HP bar
    local pct, shieldPct
    if preview then
        pct=clampPct(m.hpPct)
        shieldPct=clampPct(m.shieldPct)
    else
        local health=safeCall(object.GetHealthInfo,m.id)
        if type(health)=="table" then
            pct=clampPct(tonumber(health.valuePercents))
            if not pct and tonumber(health.limit) and tonumber(health.limit)>0 then
                pct=clampPct(100*(tonumber(health.value) or 0)/tonumber(health.limit))
            end
            shieldPct=clampPct(tonumber(health.additionalPercents))
        end
    end
    pos(row.hpFill,0,0,math.floor(row.barW*(pct or 0)/100),row.hpH)
    pos(row.shieldFill,0,0,math.floor(row.barW*(shieldPct or 0)/100),row.shieldH)
    row.hpFill:SetBackgroundColor(color(alert and settings.alertColor or (settings.colorMode=="class" and classColor or settings.hpColor)))
    row.shieldFill:SetBackgroundColor(color(settings.shieldColor))
    setTxt(row.hpTxt,displayPct(pct))
    row.hpTxt:Show(settings.showHpPercent==true)
    -- If no shield: hide the percentage entirely, never show 0% or a dash.
    if shieldPct and shieldPct>0 then
        setTxt(row.shieldTxt,displayPct(shieldPct));row.shieldTxt:Show(true)
    else
        row.shieldTxt:Show(false)
    end
    if onlyVital then return end
    -- Only selected effects appear, INSIDE the HP bar, right before HP percentage.
    local effectList, spells = {}, {}
    if preview then
        local demo={
          {"","defense"},{"","buff"},{"","buff"},{"","debuff"},
          {"","buff"},{"","debuff"},{"","defense"},{"","buff"},
          {"","debuff"},{"","buff"}
        }
        for k,v in ipairs(demo) do
            if k <= (row.idx==1 and row.buffSlots or (row.idx%3+2)) then
                effectList[#effectList+1]={mark=v[1],kind=v[2],remainingMs=(k+1)*17000}
            end
        end
        -- Preview uses the tracked names, including their per-effect side,
        -- instead of assigning a single global position to dummy icons.
        if row.idx==1 then
            local selected={}
            for _,page in ipairs({"Buffs","Debuffs"}) do
                local listed=(page=="Buffs" and settings.trackedBuffs or settings.trackedDebuffs)
                local names={}
                for name,enabled in pairs(listed) do
                    if enabled then names[#names+1]=name end
                end
                table.sort(names)
                for _,name in ipairs(names) do
                    selected[#selected+1]={name=name,kind=(page=="Buffs" and "buff" or "debuff")}
                end
            end
            for k=1,math.min(#selected,row.buffSlots) do
                effectList[k]={name=selected[k].name,kind=selected[k].kind,
                    remainingMs=(k+1)*17000}
            end
        end
        for _,seconds in ipairs(m.cd or {}) do
            spells[#spells+1]={remaining=seconds}
        end
    else
        local function append(names,kind,mark)
            for _,name in ipairs(names) do
                -- Deduplicate effects selected in more than one category.
                local existing=false
                for _,v in ipairs(effectList) do if v.name==name then existing=true;break end end
                if not existing then
                    effectList[#effectList+1]={name=name,kind=kind,mark=mark,
                        texture=effects[name] and effects[name].texture,
                        remainingMs=effects[name] and effects[name].remainingMs}
                end
            end
        end
        append(matching(effects,settings.trackedBuffs,true),"buff","+")
        append(matching(effects,settings.trackedDebuffs,false),"debuff","-")
        -- Stable left-to-right order: earlier applied effect appears first.
        table.sort(effectList,function(a,b)
            local ao=effects[a.name] and effects[a.name].order or 0
            local bo=effects[b.name] and effects[b.name].order or 0
            if ao==bo then return a.name<b.name end
            return ao<bo
        end)
        local cds=HUD.casts[m.name] or {}
        for spell,c in pairs(cds) do
            if settings.cooldowns[spell] and c.remaining and c.remaining>0 then
                spells[#spells+1]={spell=spell,remaining=c.remaining,icon=c.icon,order=c.order or 0}
            end
        end
        table.sort(spells,function(a,b)
            if a.order~=b.order then return a.order<b.order end
            return tostring(a.spell)<tostring(b.spell)
        end)
    end
    row.frameFlashColor=nil
    for _,effect in ipairs(effectList) do
        local rule=getEffectFlashRule(effect,"ally")
        if rule and rule.frameBlink then row.frameFlashColor=rule.color;break end
    end
    -- Cache original visual colours for a fast 100ms flash without redrawing HP.
    row.baseFrameColor=finalFrameColor
    row.baseInsideColor=alert and settings.alertColor or (settings.colorMode=="class" and classColor or "#B86A41")
    row.baseHpColor=alert and settings.alertColor or (settings.colorMode=="class" and classColor or settings.hpColor)
    local sideTotals={left=0,right=0}
    for i=1,math.min(row.buffSlots,#effectList) do
        local side=effectSide(effectList[i])
        sideTotals[side]=sideTotals[side]+1
    end
    local placed={left=0,right=0}
    for i,v in ipairs(row.buffIcons) do
        local e=i<=row.buffSlots and effectList[i] or nil
        if e then
            local side=effectSide(e)
            placed[side]=placed[side]+1
            placeEffectIcon(row,v,placed[side],side,sideTotals[side])
            -- Real spell artwork stays full-size, without the opaque dark tile.
            local tex=e.texture or (preview and classTextures[({"PRIEST","PALADIN","DRUID","MAGE"})[(i-1)%4+1]])
            if tex then
                v.icon:SetBackgroundColor({r=1,g=1,b=1,a=1})
                if v.currentTexture~=tex then
                    pcall(function() v.icon:SetBackgroundTexture(tex) end)
                    v.currentTexture=tex
                end
            end
            v.expiresAtMs=e.remainingMs and (HUD.clockMs+math.max(0,e.remainingMs)) or nil
            v.hasArtwork=(tex~=nil)
            local remaining=formatEffectTime(e.remainingMs,settings.buffIconSize)
            v.lastTimerText=remaining or (tex and "" or "?")
            setTxt(v.txt,v.lastTimerText)
            if not tex then
                v.back:SetBackgroundColor({r=.94,g=.68,b=.20,a=.62})
            end
            v.back:Show(tex==nil)
            v.icon:Show(tex~=nil)
            v.timeBg:Show(false) -- outlined white timer directly on artwork
            v.txt:Show(remaining~=nil or tex==nil)
        else
            v.expiresAtMs=nil;v.lastTimerText=nil;v.hasArtwork=false
            v.back:Show(false);v.icon:Show(false);v.timeBg:Show(false);v.txt:Show(false)
        end
        local rule=e and getEffectFlashRule(e)
        v.flashEnabled=(rule~=nil and rule.enabled==true)
        local active=v.flashEnabled and HUD.blinkPhase
        if active then
            local fc=color(rule.color)
            local soft={r=fc.r,g=fc.g,b=fc.b,a=.24}
            v.flashTint:SetBackgroundColor(soft)
            for _,border in ipairs({v.flashTop,v.flashBottom,v.flashLeft,v.flashRight}) do
                border:SetBackgroundColor(fc)
            end
        end
        v.flashTint:Show(active)
        v.flashTop:Show(active);v.flashBottom:Show(active)
        v.flashLeft:Show(active);v.flashRight:Show(active)
    end
    if row.frameFlashColor and HUD.blinkPhase then
        row.root:SetBackgroundColor(color(row.frameFlashColor))
        row.inside:SetBackgroundColor(colorDark(row.frameFlashColor))
        row.accent:SetBackgroundColor(color(row.frameFlashColor))
        row.hpFill:SetBackgroundColor(color(row.frameFlashColor))
    end
    for i,v in ipairs(row.cds) do
        local c=settings.showCooldowns and spells[i] or nil
        if c then
            -- Game spell texture + bright untinted icon; warm fallback if the game has no icon.
            if v.currentTexture~=c.icon then
                pcall(function() v.icon:SetBackgroundTexture(c.icon) end)
                v.currentTexture=c.icon
            end
            v.icon:SetBackgroundColor({r=1,g=1,b=1,a=1})
            v.back:SetBackgroundColor(c.icon and {r=.18,g=.17,b=.22,a=1}
                or {r=.92,g=.50,b=.15,a=1})
            setTxt(v.txt,tostring(math.ceil(c.remaining)).."с")
            v.back:Show(true);v.icon:Show(c.icon~=nil);v.txt:Show(true)
        else
            v.back:Show(false);v.icon:Show(false);v.txt:Show(false)
        end
    end
end

-- Update only the small duration labels every 100ms, not the whole roster.
-- Deadlines are refreshed when a buff event or the regular snapshot arrives.
local function refreshEffectTimers()
    for _,row in ipairs(HUD.enemyRosterRows or {}) do
        for _,slot in ipairs(row.effects or {}) do
            if slot.expiresAtMs then
                local ms=math.max(0,slot.expiresAtMs-HUD.clockMs)
                local shown=formatEffectTime(ms) or ""
                if shown~=slot.lastTimerText then
                    slot.lastTimerText=shown
                    setTxt(slot.timer,shown)
                    slot.timer:Show(shown~="")
                    slot.timerBg:Show(shown~="")
                end
            end
        end
    end
    for _,row in ipairs(HUD.rows) do
        for _,slot in ipairs(row.buffIcons or {}) do
            if slot.expiresAtMs then
                local ms=math.max(0,slot.expiresAtMs-HUD.clockMs)
                local shown=formatEffectTime(ms,settings.buffIconSize) or ""
                if shown~=slot.lastTimerText then
                    setTxt(slot.txt,shown)
                    slot.lastTimerText=shown
                    slot.txt:Show(shown~="" or not slot.hasArtwork)
                end
            end
        end
    end
end

-- Flash-only repaint: no expensive group update on every 100 ms tick.
local function refreshFlashVisibility()
    for _,row in ipairs(HUD.rows) do
        if row.frameFlashColor then
            local flash=HUD.blinkPhase
            local hex=flash and row.frameFlashColor or row.baseFrameColor
            if hex then row.root:SetBackgroundColor(color(hex)) end
            if row.baseInsideColor then row.inside:SetBackgroundColor(colorDark(flash and row.frameFlashColor or row.baseInsideColor)) end
            if hex then row.accent:SetBackgroundColor(color(hex)) end
            if row.baseHpColor then row.hpFill:SetBackgroundColor(color(flash and row.frameFlashColor or row.baseHpColor)) end
        end
        for _,slot in ipairs(row.buffIcons or {}) do
            local active=slot.flashEnabled==true and HUD.blinkPhase
            slot.flashTint:Show(active)
            slot.flashTop:Show(active);slot.flashBottom:Show(active)
            slot.flashLeft:Show(active);slot.flashRight:Show(active)
        end
    end
    -- The overview is a separate panel and also supports whole-row flashing.
    for _,row in ipairs(HUD.enemyRosterRows or {}) do
        if row.frameFlashColor and row.bg and row.bg:IsVisibleEx() then
            row.bg:SetBackgroundColor(HUD.blinkPhase and color(row.frameFlashColor) or row.baseColor)
            row.hpFill:SetBackgroundColor(HUD.blinkPhase and color(row.frameFlashColor) or row.baseHpColor or color(settings.hpColor))
        end
    end
end

local function onFlashTimerStep(p)
    if not HUD.fastTimerRunning then return end
    -- Only respond to the animation sequence started by our own invisible timer.
    if type(p)~="table" or p.wtOwner~=HUD.flashTimer then return end
    if p.effectType and ET_FADE and p.effectType~=ET_FADE then return end
    HUD.flashTicks=HUD.flashTicks+1
    HUD.clockMs=HUD.clockMs+100
    -- The toolbar is parented to the HUD; no position syncing on drag.
    refreshEffectTimers()
    pulseTargetMark()
    local periodTicks=math.max(1,math.floor(settings.flashPeriod*10+0.5))
    local phase=(math.floor(HUD.flashTicks/periodTicks)%2==0)
    if HUD.blinkPhase~=phase then
        HUD.blinkPhase=phase
        refreshFlashVisibility()
    end
end

local function startFlashTimer()
    if not HUD.flashTimer then return end
    local ok=pcall(function()
        HUD.flashTimer:PlayFadeEffectSequence({
            {1,1,100,EA_MONOTONOUS_INCREASE},
            cycled=true,
            sendStepEvent=true,
            eventLabel="AllodsPartyHUD_Flash100ms"
        })
    end)
    HUD.fastTimerRunning=ok
end

local function drawRoster()
    if not HUD.groupFrame then return end
    local preview=inPreviewMode()
    local count
    if preview then
        count=HUD.MAX_MEMBERS
        for i,row in ipairs(HUD.rows) do
            local m=PREVIEW[i]
            m.preview=true
            updateRow(row,m)
        end
    else
        syncRoster()
        count=#HUD.roster
        for i,row in ipairs(HUD.rows) do updateRow(row,HUD.roster[i]) end
    end
    if HUD.emptyHint then
        HUD.emptyHint:Show(not preview and count==0)
    end
    -- In solo/empty state do not leave a huge six-slot blank window.
    local p=HUD.groupFrame:GetPlacementPlain()
    local H=rowMetrics()
    local visibleRows=math.max(1,math.min(HUD.MAX_MEMBERS,count))
    local total=28+H*visibleRows-settings.rowSpacing
    if p.sizeY~=total then
        p.sizeY=total
        HUD.groupFrame:SetPlacementPlain(p)
    end
end

-- Never start a CD for an unselected spell. Cooldowns for party members
-- are observational estimates; the game does not expose their action-bar timers.
local function trackSelected(caster, selectedName, spellId, overrideIcon)
    if not caster or not selectedName then return end
    local member=HUD.byId[caster]
    if not member then return end
    local rule=settings.cooldowns[selectedName]
    if not rule then return end
    local seconds=tonumber(rule)
    if rule=="auto" or rule==true then
        seconds=nil
        if spellLib and spellLib.GetCurrentValues and spellId then
            local values=safeCall(spellLib.GetCurrentValues,spellId)
            if type(values)=="table" then
                local milliseconds=tonumber(values.predictedCooldown)
                if milliseconds and milliseconds>0 then seconds=milliseconds/1000 end
            end
        end
    end
    -- If automatic duration is unavailable, do NOT invent a timer.
    if not seconds or seconds<=0 or seconds>3600 then return end
    HUD.casts[member.name]=HUD.casts[member.name] or {}
    local existing=HUD.casts[member.name][selectedName]
    if existing and (existing.remaining or 0)>2 then return end
    local icon=overrideIcon
    if not icon and spellLib and spellLib.GetIcon and spellId then
        icon=safeCall(spellLib.GetIcon,spellId)
    end
    HUD.castSequence=HUD.castSequence+1
    HUD.casts[member.name][selectedName]={remaining=math.ceil(seconds),icon=icon,order=HUD.castSequence}
    drawRoster()
end
local function watchSpell(caster,spellId)
    if not caster or not spellId or not spellLib then return end
    local info=safeCall(spellLib.GetDescription,spellId)
    if not info or not info.name then return end
    local name=clean(info.name)
    if not settings.cooldowns[name] then return end
    trackSelected(caster,name,spellId,nil)
end
local function buffCast(e)
    if not e or not e.buffId then return end
    local info=safeCall(object.GetBuffInfo,e.buffId)
    if not info or not info.producer then return end
    local caster=info.producer.casterId
    local spellId=info.producer.spellId
    -- A rule can match the observed buff's name OR its producing spell.
    local buffName=clean(info.name)
    if settings.cooldowns[buffName] then
        trackSelected(caster,buffName,spellId,info.texture)
    end
    if spellId then watchSpell(caster,spellId) end
end
local function damageCast(e)
    -- Keep cooldown tracking and enemy-attacker tracking independent.
    if e and e.damageSource=="DamageSource_SPELL" then watchSpell(e.source,e.spellId) end
    onIncomingPlayerAttack(e)
    if settings.showTargeters and settings.targeterMode=="attacks" and not inPreviewMode() then
        renderTargeters()
    end
end
local function healCast(e)
    if e then watchSpell(e.healerId,e.spellId) end
end
local function tick()
    HUD.tick=HUD.tick+1
    -- Fallback alignment after drag even if 100ms animation-step events are unavailable.
    layoutMiniBars()
    -- On clients without animation-step events, fall back to 1-second timer.
    if not HUD.fastTimerRunning then
        HUD.clockMs=HUD.clockMs+1000
        HUD.flashTicks=HUD.flashTicks+10
        HUD.blinkPhase=not HUD.blinkPhase
    end
    for _,casts in pairs(HUD.casts) do
        for spell,cd in pairs(casts) do
            cd.remaining=(cd.remaining or 0)-1
            if cd.remaining<=0 then casts[spell]=nil end
        end
    end
    -- One UI module must never prevent the other panels from updating.
    for _,job in ipairs({
        {"roster",drawRoster},
        {"targeters",renderTargeters},
        {"world_mark",refreshTargetMark},
        {"overview",renderEnemyRoster}
    }) do
        local ok,err=pcall(job[2])
        if not ok then
            HUD.lastError="timer/"..job[1]..": "..tostring(err)
            if HUD.emptyHint then
                pcall(function()
                    setTxt(HUD.emptyHint,"HUD ERROR: "..HUD.lastError)
                    HUD.emptyHint:Show(true)
                end)
            end
        end
    end
end

-- GUI -------------------------------------------------------------------------
local function makeFrame(name,x,y,w,h,title)
    local bg=make(mainForm,"WndBgNC",name,x,y,w,h)
    local header=panel(bg,name.."Header",6,5,w-12,29,COLORS.window)
    local titleWidget=label(header,name.."Title",title,12,3,w-30,22)
    DnD.Init(bg,header,true,false)
    return bg,header,titleWidget
end
local function createRow(i)
    local r={idx=i}
    r.root=panel(HUD.groupFrame,"hud_Member"..i,2,2+(i-1)*settings.rowHeight,
        settings.frameWidth,settings.rowHeight-5,color(settings.frameColor))
    r.inside=panel(r.root,"hud_Inside"..i,2,2,settings.frameWidth-4,settings.rowHeight-9,COLORS.row)
    r.accent=panel(r.root,"hud_Accent"..i,0,0,2,settings.rowHeight-5,COLORS.row)
    r.classBg=panel(r.root,"hud_ClassBg"..i,4,4,30,35,COLORS.row)
    r.class=make(r.root,"TM_Icon","hud_Class"..i,7,8,25,24)
    r.shieldBg=panel(r.root,"hud_ShieldBg"..i,41,3,350,14,COLORS.hidden)
    r.shieldFill=panel(r.shieldBg,"hud_ShieldFill"..i,0,0,0,14,color(settings.shieldColor))
    r.shieldTxt=make(r.root,"TM_TxtC","hud_ShieldText"..i,310,3,60,16)
    r.hpBg=panel(r.root,"hud_HpBg"..i,41,19,350,24,COLORS.hidden)
    r.hpFill=panel(r.hpBg,"hud_HpFill"..i,0,0,0,24,color(settings.hpColor))
    r.name=label(r.root,"hud_Name"..i,"",46,20,160,23)
    r.hpTxt=make(r.root,"TM_TxtC","hud_HP"..i,320,20,50,23)
    r.buffIcons={}
    for k=1,HUD.MAX_BUFF_ICONS do
        local back=panel(r.root,"hud_BuffBack"..i.."_"..k,200+(k-1)*20,20,18,18,COLORS.warn)
        local icon=make(r.root,"TM_Icon","hud_BuffIcon"..i.."_"..k,200+(k-1)*20,20,18,18)
        local flashTint=panel(r.root,"hud_BuffFlashTint"..i.."_"..k,200+(k-1)*20,20,18,18,
            {r=1,g=.8,b=.2,a=.24})
        local flashTop=panel(r.root,"hud_BuffFlashTop"..i.."_"..k,200+(k-1)*20,20,18,2,COLORS.warn)
        local flashBottom=panel(r.root,"hud_BuffFlashBottom"..i.."_"..k,200+(k-1)*20,36,18,2,COLORS.warn)
        local flashLeft=panel(r.root,"hud_BuffFlashLeft"..i.."_"..k,200+(k-1)*20,20,2,18,COLORS.warn)
        local flashRight=panel(r.root,"hud_BuffFlashRight"..i.."_"..k,216+(k-1)*20,20,2,18,COLORS.warn)
        local timeBg=panel(r.root,"hud_BuffTimeBg"..i.."_"..k,200+(k-1)*20,26,18,12,
            {r=.01,g=.015,b=.02,a=.85})
        local txt=make(r.root,"TM_TxtC","hud_BuffText"..i.."_"..k,200+(k-1)*20,26,18,12)
        back:Show(false);icon:Show(false);timeBg:Show(false);txt:Show(false)
        flashTint:Show(false);flashTop:Show(false);flashBottom:Show(false)
        flashLeft:Show(false);flashRight:Show(false)
        r.buffIcons[k]={back=back,icon=icon,txt=txt,timeBg=timeBg,
            flashTint=flashTint,flashTop=flashTop,flashBottom=flashBottom,
            flashLeft=flashLeft,flashRight=flashRight}
    end
    r.cds={}
    for k=1,HUD.MAX_CAST_ICONS do
        -- CD icons are siblings of member frames, so they can sit LEFT of the frame.
        local back=panel(HUD.groupFrame,"hud_CDBack"..i.."_"..k,41+(k-1)*23,47,20,20,
            {r=.94,g=.46,b=.12,a=1})
        local icon=make(HUD.groupFrame,"TM_Icon","hud_CDIco"..i.."_"..k,41+(k-1)*23,47,20,20)
        local txt=make(HUD.groupFrame,"TM_TxtC","hud_CDtime"..i.."_"..k,41+(k-1)*23,47,20,20)
        back:Show(false);icon:Show(false);txt:Show(false)
        r.cds[k]={back=back,icon=icon,txt=txt}
    end
    -- Top-most transparent hit area: LMB selects ally in the game client.
    r.target=make(r.root,"TM_RowBtn","hud_Target"..i,0,0,settings.frameWidth,settings.rowHeight-5)
    layoutRow(r)
    r.root:Show(false)
    return r
end
-- One visible effects list; each entry still belongs to its original config table.
-- Combining the UI must never overwrite an existing buff with a same-named debuff.
local function getSelectedFlashItem(items)
    if HUD.page~="Effects" then return nil end
    if HUD.flashSelectedPage~=HUD.page then
        HUD.flashSelectedName=nil
        HUD.flashSelectedKind=nil
        HUD.flashSelectedPage=HUD.page
        HUD.flashSelectedScope=HUD.effectScope
    end
    for _,item in ipairs(items or {}) do
        if item.name==HUD.flashSelectedName and item.kind==HUD.flashSelectedKind then return item end
    end
    local item=items and items[1] or nil
    HUD.flashSelectedName=item and item.name or nil
    HUD.flashSelectedKind=item and item.kind or nil
    return item
end
local function pageItems()
    local result={}
    if HUD.page=="Effects" then
        -- Merge all historical tracks with catalog; no checkbox combination
        -- removes a name from the editor unless the user clicks X.
        local names={}
        for name,enabled in pairs(settings.effectCatalog or {}) do
            if enabled then names[name]={name=name,kind="buff",page="Buffs",extra=""} end
        end
        for _,scope in ipairs({"ally","enemy"}) do
            for _,def in ipairs({{"Buffs","buff"},{"Debuffs","debuff"}}) do
                for name,enabled in pairs(settings[scopedEffectKey(def[1],scope)] or {}) do
                    if enabled then
                        local item=names[name]
                        if not item then
                            item={name=name,kind=def[2],page=def[1],extra=""}
                            names[name]=item
                        end
                        item[scope]=true
                    end
                end
            end
        end
        for _,item in pairs(names) do result[#result+1]=item end
        table.sort(result,function(a,b) return a.name<b.name end)
        return result
    end
    local key=dataText[HUD.page]
    if not key then return result end
    for name,val in pairs(settings[key] or {}) do
        if val then
            local extra=""
            if HUD.page=="Cooldowns" then
                extra=(val=="auto" or val==true) and "  [АВТО]" or ("  ["..tostring(val).." с]")
            end
            result[#result+1]={name=name,extra=extra,page=HUD.page}
        end
    end
    table.sort(result,function(a,b) return a.name<b.name end)
    return result
end
-- Pixel-precise input limits, shared by the +/- controls and manual entry.
local SIZE_SPECS={
    Width={key="frameWidth",low=240,high=720},
    Height={key="rowHeight",low=58,high=120},
    Icon={key="iconSize",low=12,high=64},
    Buff={key="buffIconSize",low=12,high=72},
    BuffCount={key="buffIconCount",low=1,high=10},
    Gap={key="rowSpacing",low=0,high=60}
}
local GENERAL_CONTROLS={"posButton","autoButton","classButton","modeButton","targetersButton","targetersModeButton","markGeneralButton","overviewGeneralButton","groupHpPercent",
    "hpButton","shieldButton","frameButton","hpHex","shieldHex","frameHex",
    "hpApply","shieldApply","frameApply","hpSwatch","shieldSwatch","frameSwatch",
    "sizeWidthLabel","sizeHeightLabel","sizeIconLabel","sizeBuffLabel","sizeBuffCountLabel","sizeGapLabel",
    "sizeWidthValue","sizeHeightValue","sizeIconValue","sizeBuffValue","sizeBuffCountValue","sizeGapValue",
    "sizeWidthDec","sizeWidthInc","sizeHeightDec","sizeHeightInc","sizeIconDec","sizeIconInc",
    "sizeBuffDec","sizeBuffInc","sizeBuffCountDec","sizeBuffCountInc",
    "sizeGapDec","sizeGapInc",
    "sizeWidthApply","sizeHeightApply","sizeIconApply","sizeBuffApply","sizeBuffCountApply","sizeGapApply"}
local paintBlueCheck
local function renderSettings()
    if not HUD.settingsFrame then return end
    for _,t in ipairs(tabs) do
        local btn=HUD.widgets.tabs[t]
        if btn then
            pcall(function() btn:SetBackgroundColor(t==HUD.page and color(settings.shieldColor) or COLORS.window) end)
            setBtn(btn,t==HUD.page and ("["..tabText[t].."]") or tabText[t])
        end
    end
    -- Mode selector remains available on every settings tab.
    if HUD.previewButton and HUD.partyButton then
        local preview=HUD.viewMode~="party"
        setBtn(HUD.previewButton,preview and "[ПРОСМОТР]" or "ПРОСМОТР")
        setBtn(HUD.partyButton,preview and "МОЯ ГРУППА" or "[МОЯ ГРУППА]")
        pcall(function()
            HUD.previewButton:SetBackgroundColor(preview and color(settings.shieldColor) or COLORS.row)
            HUD.partyButton:SetBackgroundColor(preview and COLORS.row or color(settings.shieldColor))
        end)
    end
    local general=(HUD.page=="General")
    local sharePage=(HUD.page=="Share")
    local markPage=(HUD.page=="TargetMark")
    local overviewPage=(HUD.page=="Overview")
    local listPage=(not general and not sharePage and not markPage and not overviewPage)
    HUD.widgets.edit:Show(listPage)
    HUD.widgets.add:Show(listPage)
    HUD.widgets.remove:Show(listPage and HUD.page~="Effects")
    HUD.widgets.count:Show(listPage)
    HUD.widgets.effectKindButton:Show(false)
    if HUD.page=="Effects" then
        setTxt(HUD.widgets.hint,"Введите эффект и нажмите ДОБАВИТЬ. В столбцах ниже — настройки каждого эффекта.")
    end
    for _,w in ipairs(HUD.widgets.list) do w:Show(listPage) end
    for _,w in ipairs(HUD.widgets.deleteButtons) do w:Show(false) end
    local flashPage=(HUD.page=="Effects")
    HUD.widgets.effectSummary:Show(flashPage)
    for _,w in ipairs(HUD.widgets.effectColumnHeaders) do w:Show(flashPage) end
    for _,w in ipairs(HUD.widgets.effectSelectButtons) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.effectSelectionMarks) do w:Show(false) end
    for _,u in ipairs(HUD.widgets.effectAllyUi) do paintBlueCheck(u,false,false) end
    for _,u in ipairs(HUD.widgets.effectEnemyUi) do paintBlueCheck(u,false,false) end
    for _,u in ipairs(HUD.widgets.effectSideUi) do paintBlueCheck(u,false,false) end
    for _,u in ipairs(HUD.widgets.effectFlashUi) do paintBlueCheck(u,false,false) end
    for _,u in ipairs(HUD.widgets.effectFrameUi) do paintBlueCheck(u,false,false) end
    for _,w in ipairs(HUD.widgets.effectMiniIcons) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.effectMiniFallbacks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.flashToggleButtons) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.flashToggleLabels) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.flashColorButtons) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.flashSwatches) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.effectSideChecks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.effectSideLabels) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.effectSideBacks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.flashBacks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.frameFlashBacks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.frameFlashChecks) do w:Show(false) end
    for _,w in ipairs(HUD.widgets.frameFlashLabels) do w:Show(false) end
    for _,w in ipairs({HUD.widgets.flashHint,HUD.widgets.flashSelection,
        HUD.widgets.flashHex,HUD.widgets.flashApply,HUD.widgets.flashSwatch,
        HUD.widgets.flashSpeed,HUD.widgets.flashSpeedDec,
        HUD.widgets.flashSpeedInc,HUD.widgets.flashSpeedRange,
        HUD.widgets.effectScopeButton}) do w:Show(flashPage and w~=HUD.widgets.effectScopeButton) end
    HUD.widgets.flashFrameToggle:Show(false)
    HUD.widgets.prevPage:Show(listPage)
    HUD.widgets.nextPage:Show(listPage)
    for _,key in ipairs(GENERAL_CONTROLS) do HUD.widgets[key]:Show(general) end
    HUD.widgets.previewTip:Show(false)
    for _,w in ipairs(HUD.widgets.shareControls or {}) do w:Show(sharePage) end
    for _,w in ipairs(HUD.widgets.markControls or {}) do w:Show(markPage) end
    for _,w in ipairs(HUD.widgets.overviewControls or {}) do w:Show(overviewPage) end
    if markPage then
        local prof=selectedMarkProfile()
        local st=MARK_STYLES[prof.style] or MARK_STYLES.classic
        setTxt(HUD.widgets.hint,"Одна 3D-метка для ЛЮБОЙ выбранной цели: союзник, враг или моб.")
        setBtn(HUD.widgets.markEnabled,"3D-МЕТКА: "..(settings.showTargetMark and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.markStyle,"СТИЛЬ: "..st.label)
        setBtn(HUD.widgets.markColorMode,"ЦВЕТ: "..(prof.colorMode=="class" and "ПО КЛАССУ" or "СВОЙ"))
        setBtn(HUD.widgets.markPulse,"ПУЛЬСАЦИЯ: "..(prof.pulse and "ВКЛ" or "ВЫКЛ"))
        setTxt(HUD.widgets.markScaleLabel,"Размер: "..tostring(prof.size).."%")
        setTxt(HUD.widgets.markXLabel,"Смещение X: "..tostring(prof.offsetX).." px")
        setTxt(HUD.widgets.markYLabel,"Высота: "..string.format("%.1f",prof.offsetY/10).." м")
        HUD.widgets.markHex:Show(prof.colorMode=="custom")
        HUD.widgets.markHexApply:Show(prof.colorMode=="custom")
        if HUD.markHexDisplayedKind~="universal" then
            HUD.widgets.markHex:SetText(ws(prof.color))
            HUD.markHexDisplayedKind="universal"
        end
        HUD.widgets.markSwatch:SetBackgroundColor(color(prof.color))
        -- Texture previews were empty white squares in some Allods clients;
        -- a clear style label is more useful. The real marker is shown in 3D.
        setTxt(HUD.widgets.markPreview,st.label.." — одна метка на любой цели.\nРазмеры и пропорции восстановлены по BuffAnnounce; высота регулируется отдельно.")
        setTxt(HUD.widgets.markStatus,HUD.selectedTargetError and ("TARGET: "..HUD.selectedTargetError) or HUD.markError and ("Статус: "..HUD.markError) or
            HUD.markInfo or "Выбери любую цель — общая метка появится на ней.")
    end
    if overviewPage then
        setTxt(HUD.widgets.hint,"Список видимых существ. Выбирай категорию прямо над списком — текущая игровая цель не меняется.")
        setBtn(HUD.widgets.overviewShow,"ОБЗОР: "..(settings.showEnemyRoster and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.overviewClick,"ЛКМ ВЫБИРАЕТ ЦЕЛЬ: "..(settings.overviewClickTarget and "ДА" or "НЕТ"))
        setBtn(HUD.widgets.overviewClass,"ИКОНКИ КЛАССОВ: "..(settings.overviewShowClass and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.overviewPercent,"ПРОЦЕНТЫ HP: "..(settings.overviewShowHpPercent and "ВКЛ" or "ВЫКЛ"))
        HUD.widgets.overviewWidthValue:SetText(ws(tostring(settings.overviewWidth)))
        HUD.widgets.overviewHeightValue:SetText(ws(tostring(settings.overviewRowHeight)))
        HUD.widgets.overviewGapValue:SetText(ws(tostring(settings.overviewRowGap)))
        HUD.widgets.overviewCountValue:SetText(ws(tostring(settings.overviewPageSize)))
        setTxt(HUD.widgets.overviewHelp,
            "Ширина и высота не меняют размеры группы.\nНастройка с шагом 1 px через -/+ или ввод числа и OK.\nКатегория выбирается в шапке списка. ЛКМ не меняет таргет, если выключено.")
    end
    if sharePage then
        setBtn(HUD.widgets.shareScopeButton,"Экспорт: "..shareLabel(HUD.shareExportScope))
        setBtn(HUD.widgets.shareModeButton,"Импорт: "..(HUD.shareImportMode=="merge" and "ОБЪЕДИНИТЬ" or "ЗАМЕНИТЬ"))
        setTxt(HUD.widgets.shareStatus,HUD.shareStatus)
        -- Place success/error feedback immediately below the export button;
        -- on smaller screens the status widget at the bottom may be off-screen.
        setTxt(HUD.widgets.shareExportHelp,HUD.shareStatus)
        setTxt(HUD.widgets.hint,"Код PartyHUD (APH1). Коды ADSC / Universe ещё не поддерживаются.")
    end
    local cooldownPage=(HUD.page=="Cooldowns")
    HUD.widgets.cdEntryModeButton:Show(cooldownPage)
    HUD.widgets.cdEntryHelp:Show(cooldownPage)
    local alertPage=(HUD.page=="Alerts")
    for _,w in ipairs({HUD.widgets.alertControlsButton,HUD.widgets.alertDispellableButton,
        HUD.widgets.alertColorButton,HUD.widgets.alertHex,HUD.widgets.alertApply,
        HUD.widgets.alertSwatch,HUD.widgets.alertHelp}) do w:Show(alertPage) end
    if alertPage then
        setBtn(HUD.widgets.alertControlsButton,"".."Контроль: "..(settings.alertControls and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.alertDispellableButton,"".."Счищаемые: "..(settings.alertDispellable and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.alertColorButton,"Цвет тревоги: "..colorTitle(settings.alertColor))
        HUD.widgets.alertSwatch:SetBackgroundColor(color(settings.alertColor))
        setTxt(HUD.widgets.alertHelp,"Добавь названия опасных эффектов в список выше.\nАвтоматически: контроль (сап, оглушение, страх) и счищаемые магические дебафы.\nЦвет HP и рамки можно задать через HEX, например #090909." )
    end
    if cooldownPage then
        setBtn(HUD.widgets.cdEntryModeButton,
            "Добавление КД: "..(settings.cooldownEntryMode=="auto" and "АВТО" or "ВРЕМЯ ВРУЧНУЮ"))
        setTxt(HUD.widgets.cdEntryHelp,settings.cooldownEntryMode=="auto" and
            "Введите точное название бафа или умения. Время берётся из доступных игровых данных." or
            "Введите: Название=секунды (например: Защита=45). Срабатывает при наблюдении применения.")
    end
    if general then
        setBtn(HUD.widgets.markGeneralButton,"МЕТКА ЦЕЛИ: "..(settings.showTargetMark and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.overviewGeneralButton,"ОБЗОР ПЕРСОНАЖЕЙ: "..(settings.showEnemyRoster and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.targetersModeButton,"РЕЖИМ: "..(settings.targeterMode=="attacks" and "АТАКИ" or "ЦЕЛЬ"))
        setBtn(HUD.widgets.targetersButton,"ПАНЕЛЬ ВРАГОВ: "..(settings.showTargeters and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.posButton,"РАСПОЛОЖЕНИЕ КД: "..(settings.cooldownPosition=="left" and "СЛЕВА" or "СНИЗУ"))
        setBtn(HUD.widgets.autoButton,"ПОКАЗ КД: "..(settings.showCooldowns and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.classButton,"Класс: "..(settings.showClass and "ПОКАЗЫВАТЬ" or "СКРЫВАТЬ"))
        setBtn(HUD.widgets.groupHpPercent,"ПРОЦЕНТЫ HP ГРУППЫ: "..(settings.showHpPercent and "ВКЛ" or "ВЫКЛ"))
        setBtn(HUD.widgets.modeButton,"Цвет: "..(settings.colorMode=="class" and "ПО КЛАССАМ" or "ЕДИНЫЙ"))
        setBtn(HUD.widgets.hpButton,"HP: "..colorTitle(settings.hpColor))
        setBtn(HUD.widgets.shieldButton,"ЩИТ: "..colorTitle(settings.shieldColor))
        setBtn(HUD.widgets.frameButton,"РАМКА: "..colorTitle(settings.frameColor))
        HUD.widgets.hpButton:Show(settings.colorMode=="single")
        HUD.widgets.hpHex:Show(settings.colorMode=="single")
        HUD.widgets.hpApply:Show(settings.colorMode=="single")
        HUD.widgets.hpSwatch:Show(settings.colorMode=="single")
        HUD.widgets.frameButton:Show(settings.colorMode=="single")
        HUD.widgets.frameHex:Show(settings.colorMode=="single")
        HUD.widgets.frameApply:Show(settings.colorMode=="single")
        HUD.widgets.frameSwatch:Show(settings.colorMode=="single")
        HUD.widgets.hpSwatch:SetBackgroundColor(color(settings.hpColor))
        HUD.widgets.shieldSwatch:SetBackgroundColor(color(settings.shieldColor))
        HUD.widgets.frameSwatch:SetBackgroundColor(color(settings.frameColor))
        HUD.widgets.sizeWidthValue:SetText(ws(tostring(settings.frameWidth)))
        HUD.widgets.sizeHeightValue:SetText(ws(tostring(settings.rowHeight)))
        HUD.widgets.sizeGapValue:SetText(ws(tostring(settings.rowSpacing)))
        HUD.widgets.sizeIconValue:SetText(ws(tostring(settings.iconSize)))
        HUD.widgets.sizeBuffValue:SetText(ws(tostring(settings.buffIconSize)))
        HUD.widgets.sizeBuffCountValue:SetText(ws(tostring(settings.buffIconCount)))
        setTxt(HUD.widgets.hint,"Размер: -/+ по 1 пикселю или введи число и нажми OK / Enter. В списке эффектов: галочка СЛЕВА; без неё иконка справа.")
    elseif listPage then
        local notes={
            Effects="Введите название и нажмите ДОБАВИТЬ. Настройки эффекта — в строке ниже.",
            Alerts="Названия эффектов, при которых рамка меняет цвет",
            Defenses="Имя защитного положительного эффекта",
            Shields="Имя бафа, означающего наличие щита",
            Cooldowns="Выбирай названия бафов/способностей для отслеживания КД."
        }
        setTxt(HUD.widgets.hint,notes[HUD.page])
        local items=pageItems()
        local maxPage=math.max(0,math.ceil(#items/9)-1)
        HUD.listPage=math.min(HUD.listPage,maxPage)
        local offset=HUD.listPage*9
        local flashSelected=flashPage and getSelectedFlashItem(items) or nil
        for i,w in ipairs(HUD.widgets.list) do
            local v=items[offset+i]
            local visible=v~=nil
            if flashPage then
                pos(w,78,213+(i-1)*26,120,22)
                setTxt(w,v and short(v.name,13) or "")
                HUD.widgets.effectSelectButtons[i]:Show(visible)
                HUD.widgets.effectSelectionMarks[i]:Show(visible and flashSelected~=nil
                    and flashSelected.name==v.name and flashSelected.kind==v.kind)
                local scope=(v and v.ally) and "ally" or "enemy"
                local itemPage=(v and settings[scopedEffectKey("Buffs",scope)][v.name]) and "Buffs" or "Debuffs"
                local sideKey=effectSideKeyForPage(itemPage,scope)
                local side=v and settings[sideKey][v.name] or "right"
                local rule=v and getFlashRule(itemPage,v.name,false,scope) or nil
                local enabled=rule and rule.enabled or false
                paintBlueCheck(HUD.widgets.effectAllyUi[i],v and v.ally==true,visible)
                paintBlueCheck(HUD.widgets.effectEnemyUi[i],v and v.enemy==true,visible)
                paintBlueCheck(HUD.widgets.effectSideUi[i],side=="left",visible)
                paintBlueCheck(HUD.widgets.effectFlashUi[i],enabled,visible)
                paintBlueCheck(HUD.widgets.effectFrameUi[i],rule and rule.frameBlink==true,visible)
                setBtn(HUD.widgets.flashColorButtons[i],v and "..." or "")
                HUD.widgets.flashColorButtons[i]:Show(visible)
                HUD.widgets.flashSwatches[i]:Show(visible)
                HUD.widgets.flashSwatches[i]:SetBackgroundColor(color(rule and rule.color or "#5DC8C0"))
                local tex=v and HUD.effectTextureCache[v.name]
                local drawn=tex and pcall(function() HUD.widgets.effectMiniIcons[i]:SetBackgroundTexture(tex) end)
                HUD.widgets.effectMiniIcons[i]:Show(visible and drawn==true)
                setTxt(HUD.widgets.effectMiniFallbacks[i],v and (v.kind=="debuff" and "Д" or "Б") or "")
                HUD.widgets.effectMiniFallbacks[i]:Show(visible and drawn~=true)
            else
                pos(w,56,213+(i-1)*26,520,22)
                setTxt(w,v and (tostring(offset+i)..". "..short(v.name,29)..v.extra) or "")
            end
            HUD.widgets.deleteButtons[i]:Show(visible)
        end
        HUD.widgets.prevPage:Show(HUD.listPage>0)
        HUD.widgets.nextPage:Show(HUD.listPage<maxPage)
        setTxt(HUD.widgets.count,"Записей: "..tostring(#items))
        if flashPage then
            setTxt(HUD.widgets.flashHint,"СВОИ/ВРАГИ — на ком; СЛЕВА — сторона; МИГ — иконка; РАМКА — вся полоса.")
            setTxt(HUD.widgets.flashSelection,"Цвет эффекта: "..(flashSelected and short(flashSelected.name,38) or "не выбран").." (нажми имя)")
            local selectedScope=flashSelected and (flashSelected.ally and "ally" or "enemy") or "ally"
            local selectedPage=(flashSelected and settings[scopedEffectKey("Buffs",selectedScope)][flashSelected.name]) and "Buffs" or "Debuffs"
            local rule=flashSelected and getFlashRule(selectedPage,flashSelected.name,false,selectedScope) or nil
            if flashSelected then
                local sideKey=effectSideKeyForPage(selectedPage,selectedScope)
                local currentSide=settings[sideKey][flashSelected.name] or "right"
                setTxt(HUD.widgets.effectSummary,
                    "ПОКАЗ: "..(flashSelected.ally and "союзники " or "")..
                    (flashSelected.enemy and "враги" or "")..
                    "   |   ИКОНКА: "..(currentSide=="left" and "слева" or "справа")..
                    "\nМИГАНИЕ: "..(rule and rule.enabled and "иконка " or "нет ")..
                    (rule and rule.frameBlink and "+ рамка" or ""))
            else
                setTxt(HUD.widgets.effectSummary,
                    "Нет добавленных эффектов. Введи название выше и нажми ДОБАВИТЬ.")
            end
            -- The full-row blink is now a checkbox next to every effect,
            -- not a separate button requiring a prior selection.
            HUD.widgets.flashFrameToggle:Show(false)
            local selectedColor=rule and rule.color or (flashSelected and flashSelected.kind=="debuff" and "#FF3860" or "#FFD43B")
            if HUD.flashHexDisplayedPage~=HUD.page or HUD.flashHexDisplayedName~=(flashSelected and flashSelected.name) or HUD.flashHexDisplayedKind~=(flashSelected and flashSelected.kind) then
                HUD.widgets.flashHex:SetText(ws(selectedColor))
                HUD.flashHexDisplayedName=flashSelected and flashSelected.name or nil
                HUD.flashHexDisplayedKind=flashSelected and flashSelected.kind or nil
                HUD.flashHexDisplayedPage=HUD.page
            end
            HUD.widgets.flashSwatch:SetBackgroundColor(color(selectedColor))
            setTxt(HUD.widgets.flashSpeed,"Фаза мигания: "..string.format("%.1f",settings.flashPeriod):gsub("%.",",").." с")
            HUD.widgets.flashApply:Show(flashSelected~=nil)
            HUD.widgets.flashHex:Show(flashSelected~=nil)
        end
    end
end

local function updateSetting(add)
    local key=dataText[HUD.page]
    local raw=clean(HUD.widgets.edit:GetText())
    if raw=="" then return end
    local name=raw
    local rule=true
    if HUD.page=="Effects" then
        if add then
            -- Buff or debuff is established by object.GetBuffsInfo, not a UI toggle.
            -- New rules start on allies; enemy checkbox can independently enable it.
            settings.effectCatalog[name]=true
            settings.trackedBuffs[name]=true
            settings.trackedDebuffs[name]=true
            settings.buffSides[name]=settings.buffSides[name] or "right"
            settings.debuffSides[name]=settings.debuffSides[name] or "right"
        else
            settings.effectCatalog[name]=nil
            for _,scope in ipairs({"ally","enemy"}) do
                for _,page in ipairs({"Buffs","Debuffs"}) do
                    settings[scopedEffectKey(page,scope)][name]=nil
                    settings[effectSideKeyForPage(page,scope)][name]=nil
                    settings[flashKeyForPage(page,scope)][name]=nil
                end
            end
        end
        HUD.widgets.edit:SetText(ws(""))
        saveCfg();renderSettings();drawRoster();renderEnemyRoster()
        return
    end
    if not key then return end
    if HUD.page=="Cooldowns" then
        local n,d=raw:match("^(.-)%s*=%s*(%d+)%s*$")
        if not add then
            name=clean(raw:match("^(.-)%s*=") or raw)
        elseif settings.cooldownEntryMode=="auto" then
            if n then
                setTxt(HUD.widgets.hint,"Для AUTO введи только название без =секунд")
                return
            end
            rule="auto"
        else
            if not n or not d then
                setTxt(HUD.widgets.hint,"Для ручного КД: Название=60")
                return
            end
            name=clean(n)
            rule=tonumber(d)
            if not rule or rule<1 or rule>3600 then
                setTxt(HUD.widgets.hint,"Время КД: от 1 до 3600 секунд")
                return
            end
        end
    end
    if name=="" then return end
    if add then settings[key][name]=rule else
        settings[key][name]=nil
        if HUD.page=="Cooldowns" then
            for _,casts in pairs(HUD.casts) do casts[name]=nil end
        end
    end
    HUD.widgets.edit:SetText(ws(""))
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function deleteListedItem(i)
    local item=pageItems()[i+HUD.listPage*9]
    if not item then return end
    local itemPage=item.page or HUD.page
    local key=HUD.page=="Effects" and scopedEffectKey(itemPage,HUD.effectScope) or dataText[itemPage]
    if HUD.page=="Effects" then
        settings.effectCatalog[item.name]=nil
        for _,scope in ipairs({"ally","enemy"}) do
            for _,page in ipairs({"Buffs","Debuffs"}) do
                settings[scopedEffectKey(page,scope)][item.name]=nil
                settings[effectSideKeyForPage(page,scope)][item.name]=nil
                settings[flashKeyForPage(page,scope)][item.name]=nil
            end
        end
        saveCfg();renderSettings();drawRoster();renderEnemyRoster()
        return
    end
    if not key then return end
    settings[key][item.name]=nil
    local flashKey=flashKeyForPage(itemPage)
    if flashKey then settings[flashKey][item.name]=nil end
    local sideKey=effectSideKeyForPage(itemPage)
    if sideKey then settings[sideKey][item.name]=nil end
    if itemPage=="Cooldowns" then
        for _,casts in pairs(HUD.casts) do casts[item.name]=nil end
    end
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function flashRowItem(i)
    return pageItems()[(HUD.listPage*9)+i]
end
local function selectFlashItem(item)
    if not item then return end
    HUD.flashSelectedName=item.name
    HUD.flashSelectedKind=item.kind
    HUD.flashSelectedPage=HUD.page
    HUD.flashHexDisplayedName=nil
    HUD.flashHexDisplayedKind=nil
end
-- One name may be present in both positive/negative tables. Keep the
-- existing tables for compatibility with older configurations and APH1 codes.
local function effectEnabledFor(name,scope)
    return (settings[scopedEffectKey("Buffs",scope)][name] or
        settings[scopedEffectKey("Debuffs",scope)][name])==true
end
local function eachEffectBinding(name,fn)
    for _,scope in ipairs({"ally","enemy"}) do
        for _,page in ipairs({"Buffs","Debuffs"}) do
            if settings[scopedEffectKey(page,scope)][name] then fn(page,scope) end
        end
    end
end
local function toggleEffectAudience(i,scope)
    local item=flashRowItem(i)
    if not item then return end
    local enable=not effectEnabledFor(item.name,scope)
    for _,page in ipairs({"Buffs","Debuffs"}) do
        local key=scopedEffectKey(page,scope)
        settings[key][item.name]=enable and true or nil
        if enable then
            local src=scope=="ally" and "enemy" or "ally"
            local sideKey=effectSideKeyForPage(page,scope)
            local srcSide=effectSideKeyForPage(page,src)
            settings[sideKey][item.name]=settings[sideKey][item.name] or settings[srcSide][item.name] or "right"
            local ruleKey=flashKeyForPage(page,scope)
            local srcRule=settings[flashKeyForPage(page,src)][item.name]
            if not settings[ruleKey][item.name] and srcRule then
                settings[ruleKey][item.name]={enabled=srcRule.enabled,frameBlink=srcRule.frameBlink,color=srcRule.color}
            end
        end
    end
    selectFlashItem(item)
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function primaryEffectRule(item,create)
    if not item then return nil end
    local scope=effectEnabledFor(item.name,"ally") and "ally" or "enemy"
    HUD.effectScope=scope
    local page=settings[scopedEffectKey("Buffs",scope)][item.name] and "Buffs" or "Debuffs"
    return getFlashRule(page,item.name,create,scope)
end
local function updateAllEffectRules(name,field,value)
    eachEffectBinding(name,function(page,scope)
        local rule=getFlashRule(page,name,true,scope)
        rule[field]=value
    end)
end
local function toggleEffectSide(i)
    local item=flashRowItem(i)
    if not item then return end
    local key=effectSideKeyForPage(item.page, effectEnabledFor(item.name,"ally") and "ally" or "enemy")
    local side=settings[key][item.name]=="left" and "right" or "left"
    eachEffectBinding(item.name,function(page,scope)
        settings[effectSideKeyForPage(page,scope)][item.name]=side
    end)
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function flashRowToggle(i)
    local item=flashRowItem(i)
    if not item then return end
    selectFlashItem(item)
    local rule=primaryEffectRule(item,true)
    updateAllEffectRules(item.name,"enabled",not rule.enabled)
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function flashRowFrameToggle(i)
    local item=flashRowItem(i)
    if not item then return end
    selectFlashItem(item)
    local rule=primaryEffectRule(item,true)
    updateAllEffectRules(item.name,"frameBlink",not (rule.frameBlink==true))
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function flashRowColor(i)
    local item=flashRowItem(i)
    if not item then return end
    selectFlashItem(item)
    local rule=primaryEffectRule(item,true)
    updateAllEffectRules(item.name,"color",nextPalette(rule.color))
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local function applyFlashHex()
    local name=HUD.flashSelectedName
    local kind=HUD.flashSelectedKind
    local page=kind=="debuff" and "Debuffs" or kind=="buff" and "Buffs" or nil
    if not page or not name or not flashKeyForPage(page) then return end
    local hex=normalizedHex(clean(HUD.widgets.flashHex:GetText()))
    if not hex then
        setTxt(HUD.widgets.flashHint,"Неверный HEX. Пример: #FF00CC")
        return
    end
    updateAllEffectRules(name,"color",hex)
    saveCfg();renderSettings();drawRoster();renderEnemyRoster()
end
local refreshDragPermission
-- v1.9.15: compact blue square checkbox. Descriptive titles live in the
-- column headers, rather than being clipped inside narrow toggle buttons.
local function blueCheck(parent,name,caption,x,y,w)
    local bg=panel(parent,name.."Bg",x,y,w,23,{r=.20,g=.30,b=.38,a=1})
    local inner=panel(bg,name.."Inner",2,2,w-4,19,{r=.035,g=.07,b=.10,a=1})
    local tick=label(bg,name.."Tick","V",math.floor((w-15)/2),0,16,22)
    local text=label(bg,name.."Caption","",w-2,1,1,20)
    local click=make(bg,"TM_RowBtn",name,0,0,w,23)
    return {back=bg,inner=inner,tick=tick,caption=text,click=click}
end
paintBlueCheck=function(widget,enabled,visible)
    widget.back:Show(visible)
    widget.click:Show(visible)
    widget.caption:Show(false)
    widget.inner:Show(visible)
    widget.tick:Show(visible and enabled)
    if visible then
        widget.back:SetBackgroundColor(enabled and {r=.08,g=.66,b=.95,a=1} or {r=.19,g=.32,b=.41,a=1})
        widget.inner:SetBackgroundColor(enabled and {r=.035,g=.24,b=.36,a=1} or {r=.035,g=.07,b=.10,a=1})
    end
end

local function createUI()
    HUD.flashTimer=make(mainForm,"Timer","hud_FlashTimer",-9000,-9000,1,1)
    if HUD.flashTimer then HUD.flashTimer:Show(false) end
    -- The launch button is independently movable; DnD keeps its position.
    HUD.launch=button(mainForm,"hud_Launch","ГРУППА",29,162,93,27)
    DnD.Init(HUD.launch,HUD.launch,true,false)
    DnD.Enable(HUD.launch,true)
    -- Always accessible without opening Settings: a single lock controls
    -- group, overview and attacker panel dragging; launch button stays movable.
    HUD.dragLock=button(mainForm,"hud_ToggleDragLock","ЗАМОК",125,162,67,27)
    HUD.dragLockBow=panel(HUD.dragLock,"hud_LockBow",5,3,12,9,{r=.36,g=.80,b=.98,a=1})
    HUD.dragLockBody=panel(HUD.dragLock,"hud_LockBody",3,10,16,12,{r=.24,g=.60,b=.88,a=1})
    HUD.dragLockHole=panel(HUD.dragLock,"hud_LockHole",10,14,3,5,{r=.04,g=.12,b=.22,a=1})
    for _,v in ipairs({HUD.dragLockBow,HUD.dragLockBody,HUD.dragLockHole}) do v:SetTransparentInput(true) end
    -- Legacy floating buttons are kept hidden; compact controls now live
    -- directly above the group/overview panels.
    HUD.launch:Show(false)
    HUD.dragLock:Show(false)
    local outerW=effectiveFrameWidth()+4
    -- Transparent host. No opaque WndBg, heading or enormous backdrop around the bars.
    HUD.groupFrame=panel(mainForm,"hud_GroupWindow",21,205,outerW,
        28+settings.rowHeight*HUD.MAX_MEMBERS,{r=0,g=0,b=0,a=0})
    HUD.emptyHint=label(HUD.groupFrame,"hud_EmptyHint",
        "Нет данных группы — откройте настройки для предпросмотра.",5,10,outerW-10,24)
    HUD.emptyHint:Show(false)
    for i=1,HUD.MAX_MEMBERS do HUD.rows[#HUD.rows+1]=createRow(i) end
    -- Dedicated visible drag handle exists ONLY while the settings are open.
    -- The launch button remains independently draggable as before.
    HUD.groupDrag=panel(HUD.groupFrame,"hud_DragArea",2,1,outerW-4,22,
        {r=.12,g=.19,b=.25,a=.93})
    HUD.groupDragText=label(HUD.groupDrag,"hud_DragText","",7,1,outerW-18,20)
    HUD.groupDragText:SetTransparentInput(true)
    -- Always-visible toolbar is a child of the group's drag handle.
    -- DnD moves the entire groupFrame, so the controls can never lag behind it.
    HUD.groupMiniSettings=button(HUD.groupDrag,"hud_GroupMiniSettings","",outerW-60,1,27,21)
    HUD.groupMiniLock=button(HUD.groupDrag,"hud_GroupMiniLock","",outerW-30,1,27,21)
    -- A small cyan cog, drawn with native panels (no font glyph dependency).
    local function cogPart(suffix,x,y,w,h,paint)
        local v=panel(HUD.groupMiniSettings,"hud_MiniCog"..suffix,x,y,w,h,paint)
        v:SetTransparentInput(true)
    end
    local cog={r=.38,g=.81,b=.99,a=1}
    local cogHole={r=.09,g=.18,b=.27,a=1}
    cogPart("Top",11,3,5,3,cog);cogPart("Bottom",11,16,5,3,cog)
    cogPart("Left",4,10,4,3,cog);cogPart("Right",20,10,4,3,cog)
    cogPart("Core",8,6,12,11,cog);cogPart("Hole",12,10,4,4,cogHole)
    HUD.groupMiniLockBow=panel(HUD.groupMiniLock,"hud_GroupMiniLockBow",7,3,12,9,{r=.36,g=.80,b=.98,a=1})
    HUD.groupMiniLockBody=panel(HUD.groupMiniLock,"hud_GroupMiniLockBody",5,10,16,11,{r=.24,g=.60,b=.88,a=1})
    HUD.groupMiniLockHole=panel(HUD.groupMiniLock,"hud_GroupMiniLockHole",12,13,3,5,{r=.04,g=.12,b=.22,a=1})
    for _,v in ipairs({HUD.groupMiniLockBow,HUD.groupMiniLockBody,HUD.groupMiniLockHole}) do v:SetTransparentInput(true) end
    DnD.Init(HUD.groupFrame,HUD.groupDrag,true,false)
    DnD.Enable(HUD.groupDrag,false)
    HUD.groupDrag:Show(true)
    HUD.dragPreviewOn=true -- the permanent header always occupies the first 24 px
    reflowAll()
    HUD.groupFrame:Show(settings.showGroup)
    -- No separate selected-target frame: the user wants only the category
    -- dropdown and visible-unit list, independent of the game's current target.

    -- Only overview: persistent and independent of the current target.
    -- Transparent host: only the heading and colour bars are painted, never
    -- a solid rectangle behind the whole roster.
    HUD.enemyRosterFrame=panel(mainForm,"hud_VisibleEnemyRoster",1030,225,settings.overviewWidth,85,{r=0,g=0,b=0,a=0})
    HUD.enemyRosterHeader=panel(HUD.enemyRosterFrame,"hud_OverviewDrag",3,2,312,26,{r=.13,g=.20,b=.28,a=.98})
    HUD.enemyRosterTitle=label(HUD.enemyRosterHeader,"hud_OverviewTitle","",7,3,224,21)
    HUD.overviewModeButton=button(HUD.enemyRosterHeader,"hud_InspectModeOpen","v",268,1,40,24)
    HUD.enemyRosterEmpty=label(HUD.enemyRosterFrame,"hud_NoOverviewUnits","",8,34,294,23)
    HUD.enemyRosterRows={}
    for i=1,16 do
        local y=30+(i-1)*37
        local row={}
        row.bg=panel(HUD.enemyRosterFrame,"hud_OverviewUnit"..i,4,y,309,36,COLORS.rowAlt)
        row.class=make(row.bg,"TM_Icon","hud_OverviewClass"..i,3,7,24,24)
        row.class:Show(false)
        row.shieldBg=panel(row.bg,"hud_OverviewShieldBg"..i,30,1,259,6,COLORS.hidden)
        row.shieldFill=panel(row.shieldBg,"hud_OverviewShieldFill"..i,0,0,0,6,color(settings.shieldColor))
        row.shieldText=make(row.bg,"TM_TxtC","hud_OverviewShieldText"..i,30,1,259,7)
        row.shieldText:Show(false)
        row.hpBg=panel(row.bg,"hud_OverviewHpBg"..i,30,8,259,25,COLORS.hidden)
        row.hpFill=panel(row.hpBg,"hud_OverviewHpFill"..i,0,0,0,25,color(settings.hpColor),"PnlBarGradSoft")
        -- A subtle top edge and bottom shade, attached to the HP fill so they
        -- do not create a colourful block when the player has low HP.
        row.hpHighlight=panel(row.hpFill,"hud_OverviewHpHighlight"..i,0,0,0,1,{r=1,g=1,b=1,a=.20})
        row.hpShade=panel(row.hpFill,"hud_OverviewHpShade"..i,0,20,0,5,{r=.02,g=.025,b=.04,a=.24})
        row.hpHighlight:SetTransparentInput(true)
        row.hpShade:SetTransparentInput(true)
        row.name=make(row.bg,"TM_OverviewName","hud_OverviewName"..i,35,8,187,24)
        row.hpText=make(row.bg,"TM_TxtR","hud_OverviewHpPct"..i,224,8,62,24)
        row.effects={}
        for k=1,6 do
            local slot={}
            slot.icon=make(row.bg,"TM_Icon","hud_OverviewBuff"..i.."_"..k,198,9,22,22)
            slot.icon:SetBackgroundColor({r=1,g=1,b=1,a=1})
            slot.timerBg=panel(row.bg,"hud_OverviewBuffTimeBack"..i.."_"..k,
                198,25,22,11,{r=.03,g=.03,b=.035,a=.78})
            slot.timer=make(row.bg,"TM_TxtC","hud_OverviewBuffTime"..i.."_"..k,198,25,22,11)
            slot.icon:Show(false);slot.timerBg:Show(false);slot.timer:Show(false)
            slot.expiresAtMs=nil
            row.effects[k]=slot
        end
        row.click=make(row.bg,"TM_RowBtn","hud_SelectEnemy"..i,0,0,305,34)
        row.click:Show(false)
        -- Thin highlight on the currently selected unit. No target changes
        -- happen unless the user explicitly enables click-to-target.
        row.targetOutline={}
        for _,edge in ipairs({"Top","Bottom","Left","Right"}) do
            local w=panel(row.bg,"hud_OverviewTarget"..edge..i,0,0,2,2,
                {r=1,g=.84,b=.22,a=.95})
            w:SetTransparentInput(true)
            w:Show(false)
            row.targetOutline[edge]=w
        end
        row.bg:Show(false)
        HUD.enemyRosterRows[i]=row
    end
    HUD.overviewPrev=button(HUD.enemyRosterFrame,"hud_OverviewPrev","<",4,33,37,23)
    HUD.overviewPageText=label(HUD.enemyRosterFrame,"hud_OverviewPage","1/1",124,33,65,23)
    HUD.overviewNext=button(HUD.enemyRosterFrame,"hud_OverviewNext",">",267,33,45,23)
    HUD.enemyRosterDrag=HUD.enemyRosterHeader
    DnD.Init(HUD.enemyRosterFrame,HUD.enemyRosterDrag,true,false)
    DnD.Enable(HUD.enemyRosterDrag,false)
    HUD.targetModeMenuOpen=false
    HUD.targetModeMenu=panel(mainForm,"hud_OverviewModePopup",1035,253,settings.overviewWidth-14,140,{r=.08,g=.10,b=.15,a=1})
    HUD.targetModeButtons={}
    for i,kind in ipairs(ROSTER_MODES) do
        HUD.targetModeButtons[kind]=button(HUD.targetModeMenu,"hud_InspectMode_"..kind,
            ROSTER_MODE_LABELS[kind],4,3+(i-1)*33,settings.overviewWidth-22,31)
    end
    HUD.targetModeMenu:Show(false)
    renderEnemyRoster()
    layoutMiniBars()

    -- Standalone, compact panel with a separate saved drag position.
    HUD.targetersFrame=panel(mainForm,'hud_EnemyTargeters',408,205,248,54,
        {r=.15,g=.20,b=.26,a=.98})
    HUD.targetersInner=panel(HUD.targetersFrame,'hud_EnemyInside',2,27,244,24,
        {r=.06,g=.08,b=.115,a=.94})
    HUD.targetersDrag=panel(HUD.targetersFrame,'hud_EnemyDrag',2,2,244,24,
        {r=.13,g=.16,b=.23,a=1})
    HUD.targetersTitle=label(HUD.targetersDrag,'hud_EnemyTitle','НА ВАС: 0',7,2,231,20)
    HUD.targetersFoot=label(HUD.targetersFrame,'hud_EnemyFoot','',8,31,232,20)
    HUD.targeterRows={}
    for i=1,TARGETER_MAX do
        local bg=panel(HUD.targetersFrame,'hud_EnemyBadge'..i,9,31,29,29,
            {r=.09,g=.11,b=.18,a=1})
        local icon=make(HUD.targetersFrame,'TM_Icon','hud_EnemyClass'..i,11,33,25,25)
        local fallback=label(HUD.targetersFrame,'hud_EnemyClassFallback'..i,'',11,33,25,25)
        bg:Show(false);icon:Show(false);fallback:Show(false)
        HUD.targeterRows[i]={bg=bg,icon=icon,label=fallback}
    end
    DnD.Init(HUD.targetersFrame,HUD.targetersDrag,true,false)
    DnD.Enable(HUD.targetersDrag,false)
    HUD.targetersDrag:SetBackgroundColor({r=.13,g=.16,b=.23,a=1})
    -- Render again after settings frame exists, to use the real/preview mode.
    HUD.settingsFrame,HUD.settingsHeader=makeFrame("hud_SettingsWindow",570,217,600,733,"PARTY HUD | НАСТРОЙКИ")
    -- These buttons choose what is displayed WHILE the settings are open.
    -- Closing settings always shows the real party (no stale preview).
    HUD.previewButton=button(HUD.settingsHeader,"hud_ViewPreview","[ПРОСМОТР]",253,2,121,24)
    HUD.partyButton=button(HUD.settingsHeader,"hud_ViewParty","МОЯ ГРУППА",379,2,128,24)
    button(HUD.settingsHeader,"hud_CloseSettings","X",543,2,34,24)
    HUD.widgets.tabs={}
    for i,t in ipairs(tabs) do
        HUD.widgets.tabs[t]=button(HUD.settingsFrame,"hud_Tab_"..t,tabText[t],10+(i-1)*73,44,71,29)
    end
    HUD.widgets.hint=label(HUD.settingsFrame,"hud_Hint","",17,91,568,34)
    HUD.widgets.edit=make(HUD.settingsFrame,"EdtShare","hud_Edit",17,135,391,27)
    HUD.widgets.edit:SetText(ws(""))
    -- The old buff/debuff choice has been retired: runtime buff positivity is
    -- detected automatically. Keep no interactive type selector in this slot.
    HUD.widgets.effectKindButton=button(HUD.settingsFrame,"hud_EffectKind","",17,168,391,29)
    HUD.widgets.effectKindButton:Show(false)
    HUD.widgets.add=button(HUD.settingsFrame,"hud_Add","ДОБАВИТЬ",423,134,160,29)
    HUD.widgets.remove=button(HUD.settingsFrame,"hud_Remove","УДАЛИТЬ",423,168,160,29)
    HUD.widgets.list={}
    HUD.widgets.deleteButtons={}
    HUD.widgets.flashToggleButtons={}
    HUD.widgets.flashToggleLabels={}
    HUD.widgets.flashColorButtons={}
    HUD.widgets.flashSwatches={}
    HUD.widgets.effectSideChecks={}
    HUD.widgets.effectSideLabels={}
    HUD.widgets.effectSideBacks={}
    HUD.widgets.flashBacks={}
    HUD.widgets.frameFlashBacks={}
    HUD.widgets.frameFlashChecks={}
    HUD.widgets.frameFlashLabels={}
    HUD.widgets.effectAllyUi={}
    HUD.widgets.effectEnemyUi={}
    HUD.widgets.effectSideUi={}
    HUD.widgets.effectFlashUi={}
    HUD.widgets.effectFrameUi={}
    HUD.widgets.effectMiniIcons={}
    HUD.widgets.effectMiniFallbacks={}
    HUD.widgets.effectSelectButtons={}
    HUD.widgets.effectSelectionMarks={}
    HUD.widgets.effectColumnHeaders={}
    -- Headers above each compact toggle; shown only on the EFFECTS page.
    for i,def in ipairs({
        {"СВОИ",198,56}, {"ВРАГИ",258,60}, {"СЛЕВА",322,60},
        {"МИГ",382,60}, {"РАМКА",444,62}, {"ЦВЕТ",509,70}
    }) do
        HUD.widgets.effectColumnHeaders[i]=label(HUD.settingsFrame,
            "hud_EffectHeading"..i,def[1],def[2],181,def[3],23)
    end
    for i=1,9 do
        local y=211+(i-1)*26
        HUD.widgets.deleteButtons[i]=button(HUD.settingsFrame,"hud_Delete"..i,"X",17,y,29,23)
        HUD.widgets.effectMiniIcons[i]=make(HUD.settingsFrame,"TM_Icon","hud_EffectMini"..i,49,y+1,22,22)
        HUD.widgets.effectMiniFallbacks[i]=label(HUD.settingsFrame,"hud_EffectFallback"..i,"?",50,y+2,20,19)
        HUD.widgets.list[i]=label(HUD.settingsFrame,"hud_List"..i,"",78,y+2,120,22)
        HUD.widgets.effectSelectButtons[i]=make(HUD.settingsFrame,"TM_RowBtn",
            "hud_EffectSelect"..i,77,y,121,23)
        HUD.widgets.effectSelectionMarks[i]=panel(HUD.settingsFrame,
            "hud_EffectChosen"..i,78,y+22,119,2,{r=.08,g=.66,b=.95,a=1})
        HUD.widgets.effectAllyUi[i]=blueCheck(HUD.settingsFrame,"hud_EffectAlly"..i,"",214,y,25)
        HUD.widgets.effectEnemyUi[i]=blueCheck(HUD.settingsFrame,"hud_EffectEnemy"..i,"",273,y,25)
        HUD.widgets.effectSideUi[i]=blueCheck(HUD.settingsFrame,"hud_EffectSide"..i,"",335,y,25)
        HUD.widgets.effectFlashUi[i]=blueCheck(HUD.settingsFrame,"hud_FlashToggle"..i,"",395,y,25)
        HUD.widgets.effectFrameUi[i]=blueCheck(HUD.settingsFrame,"hud_FlashFrame"..i,"",463,y,25)
        HUD.widgets.effectSideBacks[i]=HUD.widgets.effectSideUi[i].back
        HUD.widgets.effectSideChecks[i]=HUD.widgets.effectSideUi[i].click
        HUD.widgets.effectSideLabels[i]=HUD.widgets.effectSideUi[i].caption
        HUD.widgets.flashBacks[i]=HUD.widgets.effectFlashUi[i].back
        HUD.widgets.flashToggleButtons[i]=HUD.widgets.effectFlashUi[i].click
        HUD.widgets.flashToggleLabels[i]=HUD.widgets.effectFlashUi[i].caption
        HUD.widgets.frameFlashBacks[i]=HUD.widgets.effectFrameUi[i].back
        HUD.widgets.frameFlashChecks[i]=HUD.widgets.effectFrameUi[i].click
        HUD.widgets.frameFlashLabels[i]=HUD.widgets.effectFrameUi[i].caption
        HUD.widgets.flashColorButtons[i]=button(HUD.settingsFrame,"hud_FlashColor"..i,"...",512,y,40,23)
        HUD.widgets.flashSwatches[i]=panel(HUD.settingsFrame,"hud_FlashSwatch"..i,561,y+2,19,18,COLORS.warn)
    end
    HUD.widgets.count=label(HUD.settingsFrame,"hud_Count","",94,451,410,23)
    HUD.widgets.prevPage=button(HUD.settingsFrame,"hud_PrevPage","<",17,449,57,26)
    HUD.widgets.nextPage=button(HUD.settingsFrame,"hud_NextPage",">",526,449,57,26)
    HUD.widgets.flashHint=label(HUD.settingsFrame,"hud_FlashHint","",17,486,567,31)
    HUD.widgets.flashSelection=label(HUD.settingsFrame,"hud_FlashSelection","",17,517,567,24)
    HUD.widgets.flashHex=make(HUD.settingsFrame,"EdtShare","hud_FlashHex",17,550,153,28)
    HUD.widgets.flashApply=button(HUD.settingsFrame,"hud_FlashApply","HEX OK",181,550,99,28)
    HUD.widgets.flashSwatch=panel(HUD.settingsFrame,"hud_FlashCurrent",292,552,27,23,COLORS.warn)
    HUD.widgets.flashSpeedDec=button(HUD.settingsFrame,"hud_FlashSpeedDec","-",17,588,50,29)
    HUD.widgets.flashSpeed=label(HUD.settingsFrame,"hud_FlashSpeed","",82,591,275,26)
    HUD.widgets.flashSpeedInc=button(HUD.settingsFrame,"hud_FlashSpeedInc","+",362,588,50,29)
    HUD.widgets.flashSpeedRange=label(HUD.settingsFrame,"hud_FlashSpeedRange","0,1-1,0 с",426,591,160,26)
    HUD.widgets.effectSummary=label(HUD.settingsFrame,"hud_EffectSummary","",17,635,565,55)
    HUD.widgets.effectScopeButton=button(HUD.settingsFrame,"hud_EffectScope","",352,94,231,28)
    HUD.widgets.effectScopeButton:Show(false)
    HUD.widgets.flashFrameToggle=button(HUD.settingsFrame,"hud_FlashFrameToggle","",17,631,566,31)
    HUD.widgets.cdEntryModeButton=button(HUD.settingsFrame,"hud_CdEntryMode","",17,487,567,32)
    HUD.widgets.cdEntryHelp=label(HUD.settingsFrame,"hud_CdEntryHelp","",19,528,555,52)
    HUD.widgets.alertControlsButton=button(HUD.settingsFrame,"hud_AlertControls","",17,490,278,32)
    HUD.widgets.alertDispellableButton=button(HUD.settingsFrame,"hud_AlertDispellable","",305,490,278,32)
    HUD.widgets.alertColorButton=button(HUD.settingsFrame,"hud_AlertNext","",17,536,277,30)
    HUD.widgets.alertHex=make(HUD.settingsFrame,"EdtShare","hud_AlertHex",305,536,129,29)
    HUD.widgets.alertHex:SetText(ws(settings.alertColor))
    HUD.widgets.alertApply=button(HUD.settingsFrame,"hud_AlertApply","HEX OK",445,536,109,29)
    HUD.widgets.alertSwatch=panel(HUD.settingsFrame,"hud_AlertSwatch",564,540,18,18,color(settings.alertColor))
    HUD.widgets.alertHelp=label(HUD.settingsFrame,"hud_AlertHelp","",19,582,565,96)
    local function settingButton(key,name,x,y,w)
        HUD.widgets[key]=button(HUD.settingsFrame,name,"",x,y,w or 246,32)
    end
    settingButton("posButton","hud_Position",17,132,268)
    settingButton("autoButton","hud_Auto",301,132,282)
    settingButton("classButton","hud_ShowClass",17,179,268)
    settingButton("modeButton","hud_ColorMode",301,179,282)
    local function colorControl(key,y,labelName)
        settingButton(key.."Button","hud_"..labelName.."Next",17,y,260)
        HUD.widgets[key.."Hex"]=make(HUD.settingsFrame,"EdtShare",
            "hud_"..labelName.."Hex",311,y,133,29)
        HUD.widgets[key.."Hex"]:SetText(ws(settings[key=="hp" and "hpColor" or key=="shield" and "shieldColor" or "frameColor"]))
        HUD.widgets[key.."Apply"]=button(HUD.settingsFrame,"hud_"..labelName.."Apply","HEX OK",454,y,100,29)
        HUD.widgets[key.."Swatch"]=panel(HUD.settingsFrame,
            "hud_"..labelName.."Swatch",564,y+5,19,19,COLORS.hidden)
    end
    colorControl("hp",227,"Hp")
    colorControl("shield",280,"Shield")
    colorControl("frame",333,"Frame")
    -- Full live size controls. Buttons preserve all 6 rows and do not reset DnD.
    local function sizeControl(key,text,y,code)
        HUD.widgets[key.."Label"]=label(HUD.settingsFrame,"hud_"..code.."Label",text,19,y+3,207,24)
        HUD.widgets[key.."Dec"]=button(HUD.settingsFrame,"hud_"..code.."Dec","-",234,y,48,27)
        HUD.widgets[key.."Value"]=make(HUD.settingsFrame,"EdtShare","hud_"..code.."Value",294,y,81,27)
        HUD.widgets[key.."Value"]:SetText(ws("0"))
        HUD.widgets[key.."Inc"]=button(HUD.settingsFrame,"hud_"..code.."Inc","+",383,y,43,27)
        HUD.widgets[key.."Apply"]=button(HUD.settingsFrame,"hud_"..code.."Apply","OK",434,y,55,27)
    end
    sizeControl("sizeWidth","Ширина рамки",383,"Width")
    sizeControl("sizeHeight","Высота строки",418,"Height")
    sizeControl("sizeIcon","Размер иконок КД",453,"Icon")
    sizeControl("sizeBuff","Размер иконок бафов",488,"Buff")
    sizeControl("sizeBuffCount","Лимит видимых бафов",523,"BuffCount")
    sizeControl("sizeGap","Расстояние между союзниками",558,"Gap")
    HUD.widgets.targetersButton=button(HUD.settingsFrame,"hud_ToggleTargeters","",17,599,269,30)
    HUD.widgets.targetersModeButton=button(HUD.settingsFrame,"hud_TargetersMode","",304,599,279,30)
    HUD.widgets.markGeneralButton=button(HUD.settingsFrame,"hud_MarkGeneral","",17,635,566,30)
    HUD.widgets.overviewGeneralButton=button(HUD.settingsFrame,"hud_ToggleOverviewGeneral","",17,671,566,29)
    HUD.widgets.previewTip=label(HUD.settingsFrame,"hud_PreviewTip","",19,702,558,23)
    HUD.widgets.previewTip:Show(false)
    HUD.widgets.groupHpPercent=button(HUD.settingsFrame,"hud_GroupHpPercent","",17,701,566,28)
    -- Dedicated profile exchange tab, styled like the other settings.
    HUD.widgets.shareControls={}
    local function addShare(w) table.insert(HUD.widgets.shareControls,w);return w end
    HUD.widgets.shareScopeButton=addShare(button(HUD.settingsFrame,"hud_ShareScope","",17,128,270,32))
    HUD.widgets.shareExportButton=addShare(button(HUD.settingsFrame,"hud_ShareExport","СФОРМИРОВАТЬ КОД",298,128,285,32))
    HUD.widgets.shareExportHelp=addShare(label(HUD.settingsFrame,"hud_ShareExportHelp",
        "Выбери раздел, сформируй код. В верхнем поле: Ctrl+A и Ctrl+C.",17,168,563,36))
    HUD.widgets.shareExportBg=addShare(panel(HUD.settingsFrame,"hud_ShareExportBg",17,206,566,122,COLORS.row,"PnlSolidNC"))
    HUD.widgets.shareExportBox=addShare(make(HUD.settingsFrame,"APHCodeBox","hud_ShareExportBox",19,209,560,116))
    HUD.widgets.shareImportHelp=addShare(label(HUD.settingsFrame,"hud_ShareImportHelp",
        "Вставь код в поле ниже (Ctrl+V), проверь его и только затем примени.",17,339,563,36))
    HUD.widgets.shareImportBg=addShare(panel(HUD.settingsFrame,"hud_ShareImportBg",17,378,566,125,COLORS.row,"PnlSolidNC"))
    HUD.widgets.shareImportBox=addShare(make(HUD.settingsFrame,"APHCodeBox","hud_ShareImportBox",19,381,560,119))
    HUD.widgets.shareVerifyButton=addShare(button(HUD.settingsFrame,"hud_ShareVerify","ПРОВЕРИТЬ КОД",17,517,270,33))
    HUD.widgets.shareModeButton=addShare(button(HUD.settingsFrame,"hud_ShareMode","",298,517,285,33))
    HUD.widgets.shareApplyButton=addShare(button(HUD.settingsFrame,"hud_ShareApply","ПРИМЕНИТЬ ИМПОРТ",17,560,566,34))
    HUD.widgets.shareStatus=addShare(label(HUD.settingsFrame,"hud_ShareStatus","",17,606,567,78))

    -- BuffAnnounce-style selected-category editor: two independent toggles.
    HUD.widgets.markControls={}
    local function addMark(w) table.insert(HUD.widgets.markControls,w);return w end
    addMark(label(HUD.settingsFrame,"hud_OneMarkForAll",
        "ЕДИНАЯ МЕТКА ДЛЯ ВРАГОВ, СОЮЗНИКОВ И МОБОВ",17,132,566,24))
    HUD.widgets.markEnabled=addMark(button(HUD.settingsFrame,"hud_MarkEnabled","",17,170,566,31))
    HUD.widgets.markStyle=addMark(button(HUD.settingsFrame,"hud_MarkStyle","",17,208,270,31))
    HUD.widgets.markPulse=addMark(button(HUD.settingsFrame,"hud_MarkPulse","",302,208,281,31))
    HUD.widgets.markColorMode=addMark(button(HUD.settingsFrame,"hud_MarkColorMode","",17,247,270,31))
    HUD.widgets.markHex=addMark(make(HUD.settingsFrame,"EdtShare","hud_MarkHex",17,285,158,29))
    HUD.widgets.markHex:SetText(ws(selectedMarkProfile().color))
    HUD.widgets.markHexApply=addMark(button(HUD.settingsFrame,"hud_MarkHexApply","ПРИМЕНИТЬ HEX",186,285,160,29))
    HUD.widgets.markSwatch=addMark(panel(HUD.settingsFrame,"hud_MarkColorSwatch",362,288,26,24,color(selectedMarkProfile().color)))
    HUD.widgets.markScaleLabel=addMark(label(HUD.settingsFrame,"hud_MarkScaleLabel","",17,327,280,27))
    addMark(button(HUD.settingsFrame,"hud_MarkSizeDec","-",313,325,60,29))
    addMark(button(HUD.settingsFrame,"hud_MarkSizeInc","+",387,325,60,29))
    HUD.widgets.markXLabel=addMark(label(HUD.settingsFrame,"hud_MarkXLabel","",17,368,280,27))
    addMark(button(HUD.settingsFrame,"hud_MarkXDec","-",313,367,60,29))
    addMark(button(HUD.settingsFrame,"hud_MarkXInc","+",387,367,60,29))
    HUD.widgets.markYLabel=addMark(label(HUD.settingsFrame,"hud_MarkYLabel","",17,409,280,27))
    addMark(button(HUD.settingsFrame,"hud_MarkYDec","-",313,409,60,29))
    addMark(button(HUD.settingsFrame,"hud_MarkYInc","+",387,409,60,29))
    addMark(label(HUD.settingsFrame,"hud_MarkPreviewTitle","ВЫБРАННЫЙ СТИЛЬ",17,520,510,24))
    HUD.widgets.markPreview=addMark(label(HUD.settingsFrame,"hud_MarkPreviewInfo","",17,555,560,63))
    HUD.widgets.markStatus=addMark(label(HUD.settingsFrame,"hud_MarkStatus","",17,635,560,59))
    HUD.widgets.overviewControls={}
    local function addOverview(w) table.insert(HUD.widgets.overviewControls,w);return w end
    HUD.widgets.overviewShow=addOverview(button(HUD.settingsFrame,"hud_OverviewShow","",17,142,566,34))
    HUD.widgets.overviewClass=addOverview(button(HUD.settingsFrame,"hud_OverviewClass","",17,230,566,32))
    HUD.widgets.overviewClick=addOverview(button(HUD.settingsFrame,"hud_OverviewClick","",17,187,566,34))
    HUD.widgets.overviewPercent=addOverview(button(HUD.settingsFrame,"hud_OverviewPercent","",17,449,566,32))
    local function overviewSize(code,caption,y)
        HUD.widgets["overview"..code.."Label"]=addOverview(label(HUD.settingsFrame,
            "hud_Overview"..code.."Label",caption,19,y+4,210,24))
        addOverview(button(HUD.settingsFrame,"hud_Overview"..code.."Dec","-",235,y,47,28))
        HUD.widgets["overview"..code.."Value"]=addOverview(make(HUD.settingsFrame,
            "EdtShare","hud_Overview"..code.."Value",294,y,86,28))
        addOverview(button(HUD.settingsFrame,"hud_Overview"..code.."Inc","+",389,y,46,28))
        addOverview(button(HUD.settingsFrame,"hud_Overview"..code.."Apply","OK",446,y,61,28))
    end
    overviewSize("Width","Ширина панели (px)",276)
    overviewSize("Height","Высота строки (px)",318)
    overviewSize("Gap","Промежуток (px)",360)
    overviewSize("Count","Строк на странице",402)
    HUD.widgets.overviewHelp=addOverview(label(HUD.settingsFrame,"hud_OverviewHelp","",17,483,560,131))
    HUD.settingsFrame:Show(false)
    refreshDragPermission()
    local okRender,errRender=pcall(renderSettings)
    local okRoster,errRoster=pcall(drawRoster)
    local okEnemies,errEnemies=pcall(renderTargeters)
    if HUD.emptyHint and (not okRender or not okRoster) then
        setTxt(HUD.emptyHint,"HUD ERROR: "..tostring(errRender or errRoster))
        HUD.emptyHint:Show(true)
    end
end
local function applyHex(key,edit)
    local raw=clean(edit:GetText())
    local c=normalizedHex(raw)
    if not c then
        setTxt(HUD.widgets.hint,"Некорректный HEX. Пример: #30BC59")
        return
    end
    settings[key]=c
    saveCfg();renderSettings();drawRoster()
end
local function applySizeInput(code)
    local spec=SIZE_SPECS[code]
    if not spec then return end
    local widget=HUD.widgets["size"..code.."Value"]
    if not widget then return end
    local raw=clean(widget:GetText())
    local number=tonumber(raw)
    -- Only positive integer pixels/counts, not fractional values or expressions.
    if not raw:match("^%d+$") or not number then
        widget:SetText(ws(tostring(settings[spec.key])))
        return
    end
    settings[spec.key]=clampNum(number,spec.low,spec.high,DEFAULT[spec.key])
    saveCfg();reflowAll();renderSettings();drawRoster()
end
local function syncHexFields()
    HUD.widgets.hpHex:SetText(ws(settings.hpColor))
    HUD.widgets.shieldHex:SetText(ws(settings.shieldColor))
    HUD.widgets.frameHex:SetText(ws(settings.frameColor))
end
local function reportError(section,err)
    HUD.lastError=tostring(section)..": "..tostring(err)
    if HUD.emptyHint and HUD.emptyHint:IsValid() then
        setTxt(HUD.emptyHint,"HUD ERROR: "..HUD.lastError)
        HUD.emptyHint:Show(true)
    end
end
refreshDragPermission=function()
    local unlocked=(settings.dragUnlocked==true)
    local settingsOpen=HUD.settingsFrame and HUD.settingsFrame:IsVisibleEx()
    local allowed=unlocked or settingsOpen
    local function paintMiniLock(btn,bow,body)
        if not btn then return end
        setBtn(btn,"")
        if bow then pos(bow,unlocked and 14 or 10,3,12,9) end
        pcall(function() btn:SetBackgroundColor(unlocked and {r=.16,g=.39,b=.34,a=1} or {r=.14,g=.19,b=.27,a=1}) end)
        if body then body:SetBackgroundColor(unlocked and {r=.30,g=.82,b=.70,a=1} or {r=.24,g=.60,b=.88,a=1}) end
    end
    if HUD.dragLock then HUD.dragLock:Show(false) end
    if HUD.launch then HUD.launch:Show(settings.showGroup~=true) end
    paintMiniLock(HUD.groupMiniLock,HUD.groupMiniLockBow,HUD.groupMiniLockBody)
    if HUD.groupDrag then HUD.groupDrag:Show(true) end
    if HUD.enemyRosterDrag then DnD.Enable(HUD.enemyRosterDrag,allowed) end
    if HUD.targetersDrag then DnD.Enable(HUD.targetersDrag,allowed) end
    if HUD.groupDrag then DnD.Enable(HUD.groupDrag,allowed) end
    if HUD.groupDrag then HUD.groupDrag:Show(true) end
    HUD.dragPreviewOn=true
    reflowAll()
end

local function setSettingsVisible(open)
    if open then HUD.viewMode="preview" end
    HUD.settingsFrame:Show(open)
    HUD.dragPreviewOn=true
    -- The independent overview dropdown is always clickable when enabled.
    if renderEnemyRoster then renderEnemyRoster() end
    if HUD.targetersDrag then
        HUD.targetersDrag:SetBackgroundColor((open or settings.dragUnlocked) and {r=.20,g=.34,b=.45,a=1}
            or {r=.13,g=.16,b=.23,a=1})
    end
    refreshDragPermission()
    if open then HUD.groupFrame:Show(true) else HUD.groupFrame:Show(settings.showGroup) end
    if HUD.launch then HUD.launch:Show(not open and settings.showGroup~=true) end
    layoutMiniBars()
    local ok,err=pcall(renderSettings)
    if not ok then reportError("settings",err) end
    local ok2,err2=pcall(drawRoster)
    if not ok2 then reportError("preview",err2) end
    local ok3,err3=pcall(renderTargeters)
    if not ok3 then reportError("targeters",err3) end
    local ok5,err5=pcall(renderEnemyRoster)
    if not ok5 then reportError("enemy_roster",err5) end
end
local function onMarkButton(name)
    local prof=selectedMarkProfile()
    if name=="hud_MarkEnabled" then
        settings.showTargetMark=not settings.showTargetMark
    elseif name=="hud_MarkStyle" then
        local nextStyle={classic="triple",triple="pvp",pvp="classic"}
        prof.style=nextStyle[prof.style] or "classic"
    elseif name=="hud_MarkColorMode" then
        prof.colorMode=prof.colorMode=="class" and "custom" or "class"
    elseif name=="hud_MarkPulse" then
        prof.pulse=not prof.pulse
    elseif name=="hud_MarkHexApply" then
        local value=normalizedHex(clean(HUD.widgets.markHex:GetText()))
        if not value then setTxt(HUD.widgets.markStatus,"Неверный HEX, пример: #FFE533");return true end
        prof.color=value
    elseif name=="hud_MarkSizeDec" then
        prof.size=clampNum(prof.size-10,50,300,100)
    elseif name=="hud_MarkSizeInc" then
        prof.size=clampNum(prof.size+10,50,300,100)
    elseif name=="hud_MarkXDec" then
        prof.offsetX=clampNum(prof.offsetX-5,-60,60,0)
    elseif name=="hud_MarkXInc" then
        prof.offsetX=clampNum(prof.offsetX+5,-60,60,0)
    elseif name=="hud_MarkYDec" then
        prof.offsetY=clampNum(prof.offsetY-1,-30,80,0)
    elseif name=="hud_MarkYInc" then
        prof.offsetY=clampNum(prof.offsetY+1,-30,80,0)
    else return false end
    saveCfg();refreshTargetMark()
    if renderEnemyRoster then renderEnemyRoster() end
    renderSettings()
    return true
end
local function onButton(p)
    local name=(p and p.sender) or ""
    if (name=="" and p and p.widget) then name=p.widget:GetName() end
    if tostring(name):match("^hud_Mark") then
        if onMarkButton(name) then return end
    end
    if name=="hud_InspectModeOpen" then
        HUD.targetModeMenuOpen=not HUD.targetModeMenuOpen
        renderEnemyRoster()
        return
    end
    if name=="hud_OverviewPrev" then
        HUD.overviewPage=math.max(1,(HUD.overviewPage or 1)-1)
        renderEnemyRoster();return
    end
    if name=="hud_OverviewNext" then
        HUD.overviewPage=(HUD.overviewPage or 1)+1
        renderEnemyRoster();return
    end
    if name=="hud_OverviewShow" then
        settings.showEnemyRoster=not settings.showEnemyRoster
        HUD.targetModeMenuOpen=false
        saveCfg();renderEnemyRoster();renderSettings();return
    end
    if name=="hud_OverviewClass" then
        settings.overviewShowClass=not settings.overviewShowClass
        saveCfg();renderEnemyRoster();renderSettings();return
    end
    if name=="hud_OverviewPercent" then
        settings.overviewShowHpPercent=not settings.overviewShowHpPercent
        saveCfg();renderEnemyRoster();renderSettings();return
    end
    if name=="hud_GroupHpPercent" then
        settings.showHpPercent=not settings.showHpPercent
        saveCfg();drawRoster();renderSettings();return
    end
    if name=="hud_OverviewClick" then
        settings.overviewClickTarget=not settings.overviewClickTarget
        saveCfg();renderEnemyRoster();renderSettings();return
    end
    local ovCode,ovOp=tostring(name):match("^hud_Overview([A-Za-z]+)(Dec)$")
    if not ovCode then ovCode,ovOp=tostring(name):match("^hud_Overview([A-Za-z]+)(Inc)$") end
    if not ovCode then ovCode,ovOp=tostring(name):match("^hud_Overview([A-Za-z]+)(Apply)$") end
    local limits={Width={"overviewWidth",220,720},Height={"overviewRowHeight",24,80},
        Gap={"overviewRowGap",0,25},Count={"overviewPageSize",3,16}}
    local spec=limits[ovCode]
    if spec and ovOp then
        if ovOp=="Apply" then
            local edit=HUD.widgets["overview"..ovCode.."Value"]
            local raw=clean(edit:GetText())
            if raw:match("^%d+$") then
                settings[spec[1]]=clampNum(tonumber(raw),spec[2],spec[3],settings[spec[1]])
            end
        else
            settings[spec[1]]=clampNum(settings[spec[1]]+(ovOp=="Inc" and 1 or -1),
                spec[2],spec[3],settings[spec[1]])
        end
        HUD.overviewPage=1
        saveCfg();renderEnemyRoster();renderSettings();return
    end
    local mode=tostring(name):match("^hud_InspectMode_(%a+)$")
    if mode and ROSTER_MODE_LABELS[mode] then
        settings.rosterMode=mode
        HUD.targetModeMenuOpen=false
        saveCfg()
        HUD.overviewPage=1
        renderEnemyRoster()
        return
    end
    local enemyIndex=tonumber(tostring(name):match("^hud_SelectEnemy(%d+)$"))
    if enemyIndex then
        local id=HUD.enemyRosterIDs and HUD.enemyRosterIDs[enemyIndex]
        if settings.overviewClickTarget and id and not inPreviewMode() then safeCall(avatar.SelectTarget,id) end
        return
    end
    local targetIndex=tonumber(tostring(name):match("^hud_Target(%d+)$"))
    if targetIndex then
        -- Selection is legal only inside mouse reaction handler. Preview cannot target.
        if not inPreviewMode() then
            local ally=HUD.roster[targetIndex]
            if ally and ally.id then safeCall(avatar.SelectTarget,ally.id) end
        end
        return
    end
    if name=="hud_ToggleDragLock" or name=="hud_GroupMiniLock"  then
        settings.dragUnlocked=not settings.dragUnlocked
        saveCfg();refreshDragPermission();drawRoster();renderEnemyRoster()
        return
    end
    if name=="hud_Launch" or name=="hud_OpenSettings" or name=="hud_GroupMiniSettings" then
        setSettingsVisible(not HUD.settingsFrame:IsVisibleEx())
    elseif name=="hud_CloseSettings" then
        setSettingsVisible(false)
    elseif name=="hud_ViewPreview" or name=="hud_ViewParty" then
        HUD.viewMode=(name=="hud_ViewParty") and "party" or "preview"
        renderSettings();drawRoster();renderTargeters();renderEnemyRoster()
    elseif string.sub(name,1,8)=="hud_Tab_" then
        HUD.page=string.sub(name,9);HUD.listPage=0;renderSettings()
    elseif name=="hud_ShareScope" then
        local nextScope={all="effects",effects="cooldowns",cooldowns="all"}
        HUD.shareExportScope=nextScope[HUD.shareExportScope] or "all"
        renderSettings()
    elseif name=="hud_ShareMode" then
        HUD.shareImportMode=(HUD.shareImportMode=="merge") and "replace" or "merge"
        renderSettings()
    elseif name=="hud_ShareExport" then
        -- No export failure may escape the button handler. Engine edit-boxes can
        -- throw when SetText receives a large text or a widget is not ready.
        local generated,code,err=pcall(function()
            if not APH_CodeExchange or type(APH_CodeExchange.Encode)~="function" then
                return nil,"Модуль CodeExchange не загружен"
            end
            return APH_CodeExchange.Encode(HUD.shareExportScope,exportSnapshot(HUD.shareExportScope))
        end)
        if not generated then
            HUD.shareStatus="Ошибка сборки профиля: "..tostring(code)
        elseif not code then
            HUD.shareStatus="Ошибка экспорта: "..tostring(err)
        else
            local w=HUD.widgets.shareExportBox
            local setOK,setErr=pcall(function() w:SetText(ws(code)) end)
            if not setOK then
                -- Some client builds expose the text value via SetVal instead.
                local success,fallbackErr=pcall(function() w:SetVal("value",ws(code)) end)
                if success then setOK=true else setErr=fallbackErr end
            end
            if setOK then
                HUD.shareStatus="Код готов ("..tostring(#code).." символов). Выдели Ctrl+A и скопируй Ctrl+C."
            else
                HUD.shareStatus="Ошибка поля экспорта: "..tostring(setErr)
            end
        end
        renderSettings()
    elseif name=="hud_ShareVerify" then
        local readOK,packet,err=pcall(checkSharedCode)
        if not readOK then err=packet;packet=nil end
        if packet then
            HUD.shareStatus="Код проверен: "..shareLabel(packet.scope)..". "..profileCount(packet.data)
        else HUD.shareStatus="Ошибка: "..tostring(err) end
        renderSettings()
    elseif name=="hud_ShareApply" then
        local packet=HUD.shareValidated
        if not packet or HUD.shareValidatedText~=currentShareCode() then
            HUD.shareStatus="Сначала нажми ПРОВЕРИТЬ КОД (или проверь изменённый код)."
        else
            local ok,err=verifyShareData(packet)
            if not ok then HUD.shareStatus="Ошибка проверки: "..tostring(err)
            else
                local applied,saved=pcall(applySharedData,packet,HUD.shareImportMode)
                if applied then
                    HUD.shareStatus="Импорт выполнен ("..(HUD.shareImportMode=="merge" and "объединение" or "замена").."). "..profileCount(packet.data)
                    HUD.shareValidated=nil;HUD.shareValidatedText=nil
                    reflowAll();drawRoster();refreshTargetMark()
                else HUD.shareStatus="Ошибка импорта: "..tostring(saved) end
            end
        end
        renderSettings()
    elseif name=="hud_PrevPage" then
        HUD.listPage=math.max(0,HUD.listPage-1);renderSettings()
    elseif name=="hud_NextPage" then
        HUD.listPage=HUD.listPage+1;renderSettings()
    elseif name=="hud_FlashFrameToggle" then
        local item=getSelectedFlashItem(pageItems())
        if item then
            local rule=getFlashRule(item.page,item.name,true)
            rule.frameBlink=not (rule.frameBlink==true)
            saveCfg();renderSettings();drawRoster();renderEnemyRoster()
        end
    elseif name=="hud_Add" then updateSetting(true)
    elseif name=="hud_Remove" then updateSetting(false)
    elseif tostring(name):match("^hud_EffectSelect%d+$") then
        local i=tonumber(tostring(name):match("^hud_EffectSelect(%d+)$"))
        local item=flashRowItem(i)
        if item then
            selectFlashItem(item)
            renderSettings()
        end
    elseif tostring(name):match("^hud_EffectAlly%d+$") then
        toggleEffectAudience(tonumber(tostring(name):match("^hud_EffectAlly(%d+)$")),"ally")
    elseif tostring(name):match("^hud_EffectEnemy%d+$") then
        toggleEffectAudience(tonumber(tostring(name):match("^hud_EffectEnemy(%d+)$")),"enemy")
    elseif tostring(name):match("^hud_EffectSide%d+$") then
        toggleEffectSide(tonumber(tostring(name):match("^hud_EffectSide(%d+)$")))
    elseif tostring(name):match("^hud_FlashToggle%d+$") then
        flashRowToggle(tonumber(tostring(name):match("^hud_FlashToggle(%d+)$")))
    elseif tostring(name):match("^hud_FlashFrame%d+$") then
        flashRowFrameToggle(tonumber(tostring(name):match("^hud_FlashFrame(%d+)$")))
    elseif tostring(name):match("^hud_FlashColor%d+$") then
        flashRowColor(tonumber(tostring(name):match("^hud_FlashColor(%d+)$")))
    elseif name=="hud_FlashApply" then
        applyFlashHex()
    elseif name=="hud_FlashSpeedDec" or name=="hud_FlashSpeedInc" then
        local step=name=="hud_FlashSpeedInc" and 1 or -1
        settings.flashPeriod=normalizeFlashPeriod(settings.flashPeriod+step*0.1)
        -- Restart phase from visible so the user's change is reflected immediately.
        HUD.flashTicks=0;HUD.blinkPhase=true
        saveCfg();renderSettings();refreshFlashVisibility()
    elseif tostring(name):match("^hud_Delete%d+$") then
        deleteListedItem(tonumber(tostring(name):match("^hud_Delete(%d+)$")))
    elseif name=="hud_AlertControls" then
        settings.alertControls=not settings.alertControls
        saveCfg();renderSettings();drawRoster()
    elseif name=="hud_AlertDispellable" then
        settings.alertDispellable=not settings.alertDispellable
        saveCfg();renderSettings();drawRoster()
    elseif name=="hud_AlertNext" then
        settings.alertColor=nextPalette(settings.alertColor)
        HUD.widgets.alertHex:SetText(ws(settings.alertColor))
        saveCfg();renderSettings();drawRoster()
    elseif name=="hud_AlertApply" then
        applyHex("alertColor",HUD.widgets.alertHex)
    elseif name=="hud_Position" then
        settings.cooldownPosition=settings.cooldownPosition=="left" and "bottom" or "left"
        saveCfg();reflowAll();renderSettings();drawRoster()
    elseif name=="hud_MarkGeneral" then
        settings.showTargetMark=not settings.showTargetMark
        saveCfg();refreshTargetMark();renderSettings()
    elseif name=="hud_ToggleOverviewGeneral" then
        settings.showEnemyRoster=not settings.showEnemyRoster
        HUD.targetModeMenuOpen=false
        saveCfg();renderEnemyRoster();renderSettings()
    elseif name=="hud_ToggleTargeters" then
        settings.showTargeters=not settings.showTargeters
        saveCfg();renderSettings();renderTargeters()
    elseif name=="hud_TargetersMode" then
        settings.targeterMode=(settings.targeterMode=="attacks") and "targets" or "attacks"
        saveCfg();renderSettings();renderTargeters()
    elseif name=="hud_Auto" then
        settings.showCooldowns=not settings.showCooldowns
        saveCfg();reflowAll();renderSettings();drawRoster()
    elseif name=="hud_CdEntryMode" then
        settings.cooldownEntryMode=settings.cooldownEntryMode=="auto" and "manual" or "auto"
        saveCfg();renderSettings()
    elseif name=="hud_ShowClass" then
        settings.showClass=not settings.showClass
        saveCfg();reflowAll();renderSettings();drawRoster()
    elseif name=="hud_ColorMode" then
        settings.colorMode=settings.colorMode=="class" and "single" or "class"
        saveCfg();renderSettings();drawRoster()
    elseif name=="hud_HpNext" then
        settings.hpColor=nextPalette(settings.hpColor)
        syncHexFields();saveCfg();renderSettings();drawRoster()
    elseif name=="hud_ShieldNext" then
        settings.shieldColor=nextPalette(settings.shieldColor)
        syncHexFields();saveCfg();renderSettings();drawRoster()
    elseif name=="hud_FrameNext" then
        settings.frameColor=nextPalette(settings.frameColor)
        syncHexFields();saveCfg();renderSettings();drawRoster()
    elseif name=="hud_HpApply" then applyHex("hpColor",HUD.widgets.hpHex)
    elseif name=="hud_ShieldApply" then applyHex("shieldColor",HUD.widgets.shieldHex)
    elseif name=="hud_FrameApply" then applyHex("frameColor",HUD.widgets.frameHex)
    elseif name:match("^hud_([%a]+)Apply$") and SIZE_SPECS[name:match("^hud_([%a]+)Apply$")] then
        applySizeInput(name:match("^hud_([%a]+)Apply$"))
    elseif name=="hud_WidthDec" or name=="hud_WidthInc" or
        name=="hud_HeightDec" or name=="hud_HeightInc" or
        name=="hud_IconDec" or name=="hud_IconInc" or
        name=="hud_BuffDec" or name=="hud_BuffInc" or
        name=="hud_BuffCountDec" or name=="hud_BuffCountInc" or
        name=="hud_GapDec" or name=="hud_GapInc" then
        local changes={
            hud_WidthDec={"frameWidth",-1,240,720},
            hud_WidthInc={"frameWidth",1,240,720},
            hud_HeightDec={"rowHeight",-1,58,120},
            hud_HeightInc={"rowHeight",1,58,120},
            hud_IconDec={"iconSize",-1,12,64},
            hud_IconInc={"iconSize",1,12,64},
            hud_BuffDec={"buffIconSize",-1,12,72},
            hud_BuffInc={"buffIconSize",1,12,72},
            hud_BuffCountDec={"buffIconCount",-1,1,10},
            hud_BuffCountInc={"buffIconCount",1,1,10},
            hud_GapDec={"rowSpacing",-1,0,60},
            hud_GapInc={"rowSpacing",1,0,60}
        }
        local spec=changes[name]
        if spec then
            settings[spec[1]]=clampNum(settings[spec[1]]+spec[2],spec[3],spec[4],DEFAULT[spec[1]])
            saveCfg();reflowAll();renderSettings();drawRoster()
        end
    end
end

local function onEnter(p)
    local name=p and (p.sender or (p.widget and p.widget:GetName())) or ""
    if name=="hud_Edit" then
        updateSetting(true)
    elseif tostring(name):match("^hud_Overview([A-Za-z]+)Value$") then
        local code=tostring(name):match("^hud_Overview([A-Za-z]+)Value$")
        onButton({sender="hud_Overview"..code.."Apply"})
    else
        local code=tostring(name):match("^hud_([%a]+)Value$")
        if code and SIZE_SPECS[code] then applySizeInput(code) end
    end
end

local function safeUI(fn,section)
    return function(params)
        local ok,err=pcall(fn,params)
        if not ok then
            if section=="click" and HUD.page=="Share" then
                HUD.shareStatus="Ошибка кнопки: "..tostring(err)
                if HUD.widgets.shareStatus then
                    pcall(function() setTxt(HUD.widgets.shareStatus,HUD.shareStatus) end)
                end
            end
            reportError(section,err)
        end
    end
end

local function onHealthChanged(event)
    local id=event and (event.id or event.unitId or event.objectId)
    if not id or inPreviewMode() then return end
    local member=HUD.byId[id]
    if member then
        for index,m in ipairs(HUD.roster) do
            if m.id==id and HUD.rows[index] then updateRow(HUD.rows[index],member,true);break end
        end
    end
    if settings.showEnemyRoster and renderEnemyRoster then renderEnemyRoster() end
end
local function onBuffChanged(event)
    local id=event and (event.id or event.unitId or event.objectId)
    if not id or inPreviewMode() then return end
    local member=HUD.byId[id]
    if member then
        for index,m in ipairs(HUD.roster) do
            if m.id==id and HUD.rows[index] then updateRow(HUD.rows[index],member);break end
        end
    end
    if settings.showEnemyRoster and renderEnemyRoster then renderEnemyRoster() end
end
local initialized=false
local function init()
    if initialized then return end
    initialized=true
    initializeClassTextures()
    initializeMarkTextures()
    common.RegisterReactionHandler(safeUI(onButton,"click"),"button_click")
    common.RegisterReactionHandler(safeUI(onEnter,"edit"),"TM_EdtEnter")
    common.RegisterEventHandler(safeUI(tick,"timer"),"EVENT_SECOND_TIMER")
    common.RegisterEventHandler(safeUI(onFlashTimerStep,"flash_timer"),"EVENT_EFFECT_SEQUENCE_STEP")
    common.RegisterEventHandler(safeUI(onHealthChanged,"health"),"EVENT_OBJECT_HEALTH_CHANGED")
    for _,eventName in ipairs({"EVENT_OBJECT_BUFF_ADDED","EVENT_OBJECT_BUFF_REMOVED",
        "EVENT_OBJECT_BUFF_CHANGED"}) do
        common.RegisterEventHandler(safeUI(onBuffChanged,"effect"),eventName)
    end
    for _,e in ipairs({ "EVENT_GROUP_APPEARED", "EVENT_GROUP_DISAPPEARED",
        "EVENT_GROUP_MEMBER_ADDED", "EVENT_GROUP_MEMBER_REMOVED", "EVENT_GROUP_MEMBER_CHANGED",
        "EVENT_RAID_APPEARED", "EVENT_RAID_DISAPPEARED", "EVENT_RAID_CHANGED",
        "EVENT_RAID_MEMBER_ADDED", "EVENT_RAID_MEMBER_REMOVED", "EVENT_UNITS_CHANGED" }) do
        common.RegisterEventHandler(safeUI(drawRoster,"roster"),e)
    end
    common.RegisterEventHandler(safeUI(renderTargeters,"targeters"),"EVENT_UNITS_CHANGED")
    common.RegisterEventHandler(safeUI(renderEnemyRoster,"enemy_roster"),"EVENT_UNITS_CHANGED")
    common.RegisterEventHandler(safeUI(onTargetMarkChanged,"world_mark"),"EVENT_AVATAR_TARGET_CHANGED")
    common.RegisterEventHandler(safeUI(renderEnemyRoster,"target_overview"),"EVENT_AVATAR_TARGET_CHANGED")
    common.RegisterEventHandler(safeUI(onTargetMarkAttachFailed,"mark_attach"),"EVENT_CANNOT_ATTACH_WIDGET_3D")
    -- The selected player may enter the loaded 3D scene after target selection.
    common.RegisterEventHandler(safeUI(refreshTargetMark,"mark_unit_list"),"EVENT_UNITS_CHANGED")
    common.RegisterEventHandler(safeUI(buffCast,"buff"),"EVENT_OBJECT_BUFF_ADDED")
    common.RegisterEventHandler(safeUI(damageCast,"damage"),"EVENT_UNIT_DAMAGE_RECEIVED")
    common.RegisterEventHandler(safeUI(healCast,"heal"),"EVENT_HEALING_RECEIVED")
    local ok,err=pcall(createUI)
    if not ok then reportError("createUI",err) else startFlashTimer();refreshTargetMark();renderEnemyRoster() end
end
common.RegisterEventHandler(init,"EVENT_AVATAR_CREATED")
if safeCall(avatar.IsExist) then init() end
