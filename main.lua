-- СКРИПТ ОТ ДЭЙВА | Build A Boat for Treasure | автофарм золота
-- Летит с начального острова через все этапы до золотого сундука, забирает золото,
-- делает респавн и повторяет. K — открыть/закрыть меню, G — вкл/выкл фарм.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local CONFIG_FILE = "DaveBABFT_config.json"

-- ===== Чистка старой копии =====
local env = (getgenv and getgenv()) or _G
if env.DaveBabftCleanup then pcall(env.DaveBabftCleanup) end

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
local oldGui = guiParent:FindFirstChild("DaveBABFT")
if oldGui then oldGui:Destroy() end

local conns, running = {}, true
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(conns, c)
    return c
end

-- ===== Настройки (сохраняются в файл) =====
local state = {
    farm = false,
    speed = 250,       -- скорость полёта, студов в секунду
    stageWait = 0.15,  -- пауза у каждой чёрной стены (сек)
    chestWait = 6,     -- пауза у сундука после получения золота (сек)
    startDelay = 3,    -- пауза после респавна перед стартом (сек)
    status = "Выключено",
    cycles = 0,
}
local PERSIST = {"speed", "stageWait", "chestWait", "startDelay"}

local function saveCfg()
    if not writefile then return end
    local t = {}
    for _, k in ipairs(PERSIST) do t[k] = state[k] end
    pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(t))
end

local function loadCfg()
    if not (isfile and readfile and isfile(CONFIG_FILE)) then return end
    local ok, t = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
    if ok and type(t) == "table" then
        for _, k in ipairs(PERSIST) do
            if type(t[k]) == "number" then state[k] = t[k] end
        end
    end
end
loadCfg()

local function getChar()
    local c = lp.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end

-- ===== Золото (ищем значение с "gold" в названии у игрока) =====
local goldObj
local function findGold()
    if goldObj and goldObj.Parent then return goldObj end
    for _, d in ipairs(lp:GetDescendants()) do
        if d:IsA("ValueBase") and d.Name:lower():find("gold", 1, true) and tonumber(d.Value) then
            goldObj = d
            return d
        end
    end
end

-- ===== Полёт и ноклип =====
local flying, holdBV = false, nil

local function beginFlight()
    local _, hum, root = getChar()
    if not (hum and root) then return false end
    flying = true
    hum.PlatformStand = true
    if holdBV then holdBV:Destroy() end
    holdBV = Instance.new("BodyVelocity")
    holdBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    holdBV.Velocity = Vector3.zero
    holdBV.Parent = root
    return true
end

local function endFlight()
    flying = false
    if holdBV then holdBV:Destroy() holdBV = nil end
    local _, hum = getChar()
    if hum then hum.PlatformStand = false end
end

bind(RS.Stepped, function()
    if not flying then return end
    local c = lp.Character
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end)

-- Летим к точке с заданной скоростью. Возвращает true, когда долетели.
local function flyTo(target)
    while running and state.farm do
        local dt = math.min(RS.Heartbeat:Wait(), 0.1)
        local _, hum, root = getChar()
        if not (hum and root) or hum.Health <= 0 then return false end
        local delta = target - root.Position
        local dist = delta.Magnitude
        if dist <= 2.5 then return true end
        local speed = math.clamp(state.speed, 20, 1000)
        root.CFrame = root.CFrame + delta.Unit * math.min(dist, speed * dt)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    return false
end

local function touch(part)
    local _, _, root = getChar()
    if root and part and firetouchinterest then
        pcall(function()
            firetouchinterest(root, part, 0)
            task.wait()
            firetouchinterest(root, part, 1)
        end)
    end
end

-- ===== Поиск этапов и сундука =====
local function partOf(inst)
    if not inst then return end
    if inst:IsA("BasePart") then return inst.Position, inst end
    if inst:IsA("Model") then
        return inst:GetPivot().Position, inst:FindFirstChildWhichIsA("BasePart", true)
    end
end

-- Основной путь: Workspace.BoatStages.NormalStages.CaveStage1..10.DarknessPart и TheEnd.GoldenChest.Trigger
local function collectMain()
    local bs = workspace:FindFirstChild("BoatStages")
    local stages = bs and bs:FindFirstChild("NormalStages")
    if not stages then return nil end
    local list = {}
    for i = 1, 10 do
        local st = stages:FindFirstChild("CaveStage" .. i)
        local dp = st and st:FindFirstChild("DarknessPart")
        local pos, part = partOf(dp)
        if pos then table.insert(list, {name = "Этап " .. i, pos = pos, part = part}) end
    end
    local theEnd = stages:FindFirstChild("TheEnd")
    local chest = theEnd and theEnd:FindFirstChild("GoldenChest")
    local trig = chest and (chest:FindFirstChild("Trigger") or chest)
    local cpos, cpart = partOf(trig)
    if cpos then table.insert(list, {name = "Сундук", pos = cpos, part = cpart, final = true}) end
    if #list >= 2 and list[#list].final then return list end
end

-- Запасной путь: ищем детали по именам по всей карте и строим маршрут от ближайшей к дальней
local function collectFallback(fromPos)
    local darks, chest = {}, nil
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Name == "DarknessPart" then
                table.insert(darks, d)
            elseif not chest and d.Name == "Trigger" and d.Parent and d.Parent.Name:lower():find("chest", 1, true) then
                chest = d
            end
        end
    end
    if #darks == 0 and not chest then return nil end
    local list, cur = {}, fromPos
    while #darks > 0 do
        local bi, bd
        for i, p in ipairs(darks) do
            local dd = (p.Position - cur).Magnitude
            if not bd or dd < bd then bi, bd = i, dd end
        end
        local p = table.remove(darks, bi)
        table.insert(list, {name = "Этап " .. (#list + 1), pos = p.Position, part = p})
        cur = p.Position
    end
    if chest then
        table.insert(list, {name = "Сундук", pos = chest.Position, part = chest, final = true})
    end
    return list
end

local function collectWaypoints(fromPos)
    local list = collectMain()
    if list then return list, "основной" end
    list = collectFallback(fromPos)
    if list and #list > 0 then return list, "запасной" end
    return nil, "Не нашёл этапы карты (BoatStages). Возможно, игру обновили"
end

local function claimGold()
    local r = workspace:FindFirstChild("ClaimRiverResultsGold")
        or ReplicatedStorage:FindFirstChild("ClaimRiverResultsGold", true)
    if r and r:IsA("RemoteEvent") then
        pcall(function() r:FireServer() end)
        return true
    end
    return false
end

-- ===== Один цикл фарма =====
local function waitRespawn(oldChar)
    local t0 = os.clock()
    repeat
        task.wait(0.3)
    until not running
        or (lp.Character and lp.Character ~= oldChar and lp.Character:FindFirstChild("HumanoidRootPart")
            and lp.Character:FindFirstChildOfClass("Humanoid"))
        or os.clock() - t0 > 25
end

local function runCycle()
    local char, hum, root = getChar()
    if not (hum and root) or hum.Health <= 0 then
        state.status = "Жду респавн..."
        task.wait(1)
        return
    end

    local wps, how = collectWaypoints(root.Position)
    if not wps then
        state.status = how
        task.wait(4)
        return
    end

    if not beginFlight() then return end
    local reached = true
    for i, wp in ipairs(wps) do
        if not (running and state.farm) then reached = false break end
        state.status = ("Лечу: %s (%d/%d)"):format(wp.name, i, #wps)
        if not flyTo(wp.pos) then reached = false break end
        if wp.part then touch(wp.part) end
        task.wait(wp.final and 0.3 or math.max(state.stageWait, 0))
    end
    endFlight()
    if not reached then return end

    state.status = "Забираю золото..."
    local claimed = claimGold()
    state.cycles += 1
    state.status = claimed and "Золото получено, жду..." or "У сундука (remote не найден), жду..."
    task.wait(math.max(state.chestWait, 0))

    if not (running and state.farm) then return end
    state.status = "Респавн..."
    local _, h2 = getChar()
    if h2 then h2.Health = 0 end
    waitRespawn(char)
    state.status = "Новый круг..."
    task.wait(math.max(state.startDelay, 0))
end

task.spawn(function()
    while running do
        if state.farm then
            local ok, err = pcall(runCycle)
            if not ok then
                endFlight()
                warn("[Dave] ошибка цикла:", err)
                state.status = "Ошибка: " .. tostring(err)
                task.wait(3)
            end
        else
            task.wait(0.3)
        end
    end
end)

-- Анти-АФК
bind(lp.Idled, function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ===================================================================
-- ИНТЕРФЕЙС
-- ===================================================================
local THEME = {
    accent = Color3.fromRGB(226, 34, 34),
    bg = Color3.fromRGB(20, 20, 24),
    panel = Color3.fromRGB(34, 34, 40),
    panel2 = Color3.fromRGB(50, 50, 60),
    text = Color3.fromRGB(238, 238, 242),
    muted = Color3.fromRGB(165, 165, 176),
    off = Color3.fromRGB(74, 74, 86),
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function corner(o, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end

local function tween(o, t, props)
    return TS:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
end

local sg = new("ScreenGui", {Name = "DaveBABFT", ResetOnSpawn = false}, guiParent)

local function notify(text)
    local l = new("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -90),
        Size = UDim2.fromOffset(400, 34),
        BackgroundColor3 = THEME.bg,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        Text = text,
    }, sg)
    corner(l, 8)
    new("UIStroke", {Color = THEME.accent, Thickness = 1.5}, l)
    task.delay(3, function() if l then l:Destroy() end end)
end

local HEAD_H, WIDTH, FULL_H = 44, 310, 470

local frame = new("Frame", {
    Size = UDim2.fromOffset(WIDTH, FULL_H),
    Position = UDim2.fromOffset(40, 110),
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
    Active = true,
    Draggable = true,
    ClipsDescendants = true,
}, sg)
corner(frame, 12)
new("UIStroke", {Color = THEME.accent, Thickness = 2}, frame)

-- Шапка: клик сворачивает/разворачивает меню
local header = new("TextButton", {
    Size = UDim2.new(1, -44, 0, HEAD_H),
    BackgroundTransparency = 1,
    Text = "СКРИПТ ОТ ДЭЙВА | BABFT",
    TextColor3 = THEME.text,
    Font = Enum.Font.GothamBlack,
    TextSize = 15,
    AutoButtonColor = false,
}, frame)

-- Крестик: полностью скрывает меню (вернуть на K)
local closeBtn = new("TextButton", {
    Position = UDim2.new(1, -36, 0, 9),
    Size = UDim2.fromOffset(26, 26),
    BackgroundColor3 = THEME.accent,
    Text = "X",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 14,
}, frame)
corner(closeBtn, 7)

local body = new("ScrollingFrame", {
    Position = UDim2.fromOffset(8, HEAD_H + 2),
    Size = UDim2.new(1, -16, 1, -(HEAD_H + 10)),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = THEME.accent,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, frame)
new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, body)
new("UIPadding", {PaddingRight = UDim.new(0, 8)}, body)

local order = 0
local function nextOrder() order += 1 return order end

local function row(h)
    local f = new("Frame", {
        Size = UDim2.new(1, 0, 0, h),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    corner(f, 8)
    return f
end

local function addLabel(text, h, card)
    local l = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, h),
        BackgroundColor3 = THEME.panel,
        BackgroundTransparency = card and 0 or 1,
        TextColor3 = card and THEME.text or THEME.muted,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = text,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    if card then
        corner(l, 8)
        new("UIPadding", {
            PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
            PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
        }, l)
    end
    return l
end

-- Переключатель
local setFarm
local function addToggle(text, get, set)
    local r = row(38)
    new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -66, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, r)
    local pill = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(42, 22),
        BackgroundColor3 = THEME.off,
        BorderSizePixel = 0,
    }, r)
    corner(pill, 11)
    local knob = new("Frame", {
        Position = UDim2.new(0, 2, 0.5, -9),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, pill)
    corner(knob, 9)
    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5,
    }, r)
    local function paint(anim)
        local on = get()
        local pc = on and THEME.accent or THEME.off
        local kp = on and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
        if anim then
            tween(pill, 0.15, {BackgroundColor3 = pc}):Play()
            tween(knob, 0.15, {Position = kp}):Play()
        else
            pill.BackgroundColor3 = pc
            knob.Position = kp
        end
    end
    paint(false)
    hit.MouseButton1Click:Connect(function()
        set(not get())
        paint(true)
    end)
    return function() paint(true) end
end

local function addInput(labelText, key)
    local r = row(36)
    new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.55, -12, 1, 0),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = THEME.text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, r)
    local box = new("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.new(0.45, -12, 0, 26),
        BackgroundColor3 = THEME.panel2,
        TextColor3 = THEME.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        ClearTextOnFocus = false,
        Text = tostring(state[key]),
    }, r)
    corner(box, 6)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then state[key] = n else box.Text = tostring(state[key]) end
        saveCfg()
    end)
end

local function addButton(text, onClick)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = THEME.panel2,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        Text = text,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    corner(b, 8)
    b.MouseEnter:Connect(function() tween(b, 0.12, {BackgroundColor3 = THEME.accent}):Play() end)
    b.MouseLeave:Connect(function() tween(b, 0.12, {BackgroundColor3 = THEME.panel2}):Play() end)
    b.MouseButton1Click:Connect(onClick)
end

-- Карточка статуса
local info = addLabel("", 86, true)

local repaintFarm = addToggle("Автофарм золота",
    function() return state.farm end,
    function(on)
        state.farm = on
        if on then
            state.status = "Запуск..."
        else
            state.status = "Выключено"
            endFlight()
        end
    end)
setFarm = function(on)
    state.farm = on
    state.status = on and "Запуск..." or "Выключено"
    if not on then endFlight() end
    repaintFarm()
end

addInput("Скорость полёта (студов/сек)", "speed")
addInput("Пауза у стены этапа (сек)", "stageWait")
addInput("Пауза у сундука (сек)", "chestWait")
addInput("Пауза после респавна (сек)", "startDelay")

addButton("Проверить карту", function()
    local _, _, root = getChar()
    local wps, how = collectWaypoints(root and root.Position or Vector3.zero)
    if wps then
        notify(("Найдено точек: %d (%s поиск)"):format(#wps, how))
        print("[Dave] маршрут (" .. how .. "):")
        for i, wp in ipairs(wps) do
            print(("  %d. %s  %s"):format(i, wp.name, tostring(wp.pos)))
        end
    else
        notify(how)
    end
end)

addLabel("Скрипт сам летит от острова до сундука, забирает золото, делает респавн и повторяет. Скорость 250 — безопасный старт, выше риск бана. K — меню, G — фарм.", 76)

-- Обновление карточки статуса
local startedAt, startGold = os.clock(), nil
local function fmtTime(sec)
    sec = math.floor(sec)
    return ("%02d:%02d:%02d"):format(sec // 3600, (sec % 3600) // 60, sec % 60)
end

task.spawn(function()
    while running do
        local g = findGold()
        local goldLine
        if g then
            local v = tonumber(g.Value) or 0
            startGold = startGold or v
            goldLine = ("Золото: %d (за сессию +%d)"):format(v, v - startGold)
        else
            goldLine = "Золото: счётчик не найден"
        end
        local el = os.clock() - startedAt
        local perHour = el > 60 and (state.cycles / el * 3600) or 0
        info.Text = ("%s\nКругов: %d (≈%.1f/час)\nВремя: %s\n%s"):format(
            state.status, state.cycles, perHour, fmtTime(el), goldLine)
        task.wait(0.5)
    end
end)

-- Сворачивание по клику на шапку (если это не перетаскивание)
local collapsed, downPos = false, nil
header.MouseButton1Down:Connect(function() downPos = frame.Position end)
header.MouseButton1Click:Connect(function()
    if downPos and frame.Position ~= downPos then return end
    collapsed = not collapsed
    tween(frame, 0.2, {Size = UDim2.fromOffset(WIDTH, collapsed and HEAD_H or FULL_H)}):Play()
end)

closeBtn.MouseButton1Click:Connect(function() frame.Visible = false end)

-- K — меню, G — автофарм
bind(UIS.InputBegan, function(input, gpe)
    if gpe or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if input.KeyCode == Enum.KeyCode.K then
        frame.Visible = not frame.Visible
    elseif input.KeyCode == Enum.KeyCode.G then
        setFarm(not state.farm)
    end
end)

if game.PlaceId ~= 537413528 then
    print("[Dave] PlaceId:", game.PlaceId, "(Build A Boat for Treasure обычно 537413528)")
end
notify("Скрипт загружен. K — меню, G — фарм")

env.DaveBabftCleanup = function()
    running = false
    state.farm = false
    endFlight()
    for _, c in ipairs(conns) do c:Disconnect() end
    sg:Destroy()
end
-- СКРИПТ ОТ ДЭЙВА | Build A Boat for Treasure | автофарм золота
-- Летит с начального острова через все этапы до золотого сундука, забирает золото,
-- делает респавн и повторяет. K — открыть/закрыть меню, G — вкл/выкл фарм.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local VIM = game:GetService("VirtualInputManager")
local SoundService = game:GetService("SoundService")
local lp = Players.LocalPlayer

local CONFIG_FILE = "DaveBABFT_config.json"
local SOUND_URL = ""                     -- прямая ссылка на свой звук (необязательно)
local LOCAL_SOUNDS = {"DaveStartup.mp3", "DaveStartup.ogg", "DaveStartup.wav"}
local BG_FILE = "DaveBG.png"             -- своя картинка фона (если лежит в workspace, берётся она)
local BG_URL = ""                        -- или прямая ссылка на картинку
local BG_B64 = "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"              -- встроенный фон
local SAIL_WORDS = {"set sail", "sail", "Отплы", "отплы", "ОТПЛЫ"}
local SOUND_B64 = "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"          -- встроенный звук win31.mp3

-- ===== Чистка старой копии =====
local env = (getgenv and getgenv()) or _G
if env.DaveBabftCleanup then pcall(env.DaveBabftCleanup) end

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
local oldGui = guiParent:FindFirstChild("DaveBABFT")
if oldGui then oldGui:Destroy() end

local conns, running = {}, true
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(conns, c)
    return c
end

local notify, prepareBoat, playTada -- заполняются ниже

-- ===== Настройки (сохраняются в файл) =====
local state = {
    farm = false,
    speed = 250,       -- скорость полёта, студов в секунду
    stageWait = 0.15,  -- пауза у каждой чёрной стены (сек)
    chestWait = 6,     -- пауза у сундука после получения золота (сек)
    startDelay = 3,    -- пауза после респавна перед стартом (сек)
    status = "Выключено",
    cycles = 0,
    useBlock = true,   -- ставить блок перед отплытием
    buildSlot = 2,     -- слот молотка на панели (клавиша 2)
    useSail = true,    -- нажимать «Отплыть»
    soundOn = true,    -- звук Windows 3.1
    volume = 1,
    bgAlpha = 0.5,     -- прозрачность фото-фона
    panelAlpha = 0.3,  -- прозрачность панелей поверх фото (0 = без прозрачности)
}
local PERSIST = {"speed", "stageWait", "chestWait", "startDelay",
    "useBlock", "buildSlot", "useSail", "soundOn", "volume", "bgAlpha", "panelAlpha"}

local function saveCfg()
    if not writefile then return end
    local t = {}
    for _, k in ipairs(PERSIST) do t[k] = state[k] end
    pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(t))
end

local function loadCfg()
    if not (isfile and readfile and isfile(CONFIG_FILE)) then return end
    local ok, t = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
    if ok and type(t) == "table" then
        for _, k in ipairs(PERSIST) do
            if type(t[k]) == type(state[k]) then state[k] = t[k] end
        end
    end
end
loadCfg()

local function getChar()
    local c = lp.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end

-- ===== Золото (ищем значение с "gold" в названии у игрока) =====
local goldObj
local function findGold()
    if goldObj and goldObj.Parent then return goldObj end
    for _, d in ipairs(lp:GetDescendants()) do
        if d:IsA("ValueBase") and d.Name:lower():find("gold", 1, true) and tonumber(d.Value) then
            goldObj = d
            return d
        end
    end
end

local goldLabel
local function getGold()
    local g = findGold()
    if g then return tonumber(g.Value) end
    if goldLabel and not goldLabel.Parent then goldLabel = nil end
    if not goldLabel then
        local pg = lp:FindFirstChildOfClass("PlayerGui")
        if pg then
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") and d:GetFullName():lower():find("gold", 1, true)
                    and tonumber((d.Text:gsub("[,%s]", ""))) then
                    goldLabel = d
                    break
                end
            end
        end
    end
    if goldLabel then return tonumber((goldLabel.Text:gsub("[,%s]", ""))) end
end

-- ===== Полёт и ноклип =====
local flying, holdBV = false, nil

local function beginFlight()
    local _, hum, root = getChar()
    if not (hum and root) then return false end
    flying = true
    hum.PlatformStand = true
    if holdBV then holdBV:Destroy() end
    holdBV = Instance.new("BodyVelocity")
    holdBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    holdBV.Velocity = Vector3.zero
    holdBV.Parent = root
    return true
end

local function endFlight()
    flying = false
    if holdBV then holdBV:Destroy() holdBV = nil end
    local _, hum = getChar()
    if hum then hum.PlatformStand = false end
end

bind(RS.Stepped, function()
    if not flying then return end
    local c = lp.Character
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end)

-- Летим к точке с заданной скоростью. Возвращает true, когда долетели.
local function flyTo(target)
    while running and state.farm do
        local dt = math.min(RS.Heartbeat:Wait(), 0.1)
        local _, hum, root = getChar()
        if not (hum and root) or hum.Health <= 0 then return false end
        local delta = target - root.Position
        local dist = delta.Magnitude
        if dist <= 2.5 then return true end
        local speed = math.clamp(state.speed, 20, 1000)
        root.CFrame = root.CFrame + delta.Unit * math.min(dist, speed * dt)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    return false
end

local function touch(part)
    local _, _, root = getChar()
    if root and part and firetouchinterest then
        pcall(function()
            firetouchinterest(root, part, 0)
            task.wait()
            firetouchinterest(root, part, 1)
        end)
    end
end

-- ===== Поиск этапов и сундука =====
local function partOf(inst)
    if not inst then return end
    if inst:IsA("BasePart") then return inst.Position, inst end
    if inst:IsA("Model") then
        return inst:GetPivot().Position, inst:FindFirstChildWhichIsA("BasePart", true)
    end
end

-- Основной путь: Workspace.BoatStages.NormalStages.CaveStage1..10.DarknessPart и TheEnd.GoldenChest.Trigger
local function collectMain()
    local bs = workspace:FindFirstChild("BoatStages")
    local stages = bs and bs:FindFirstChild("NormalStages")
    if not stages then return nil end
    local list = {}
    for i = 1, 10 do
        local st = stages:FindFirstChild("CaveStage" .. i)
        local dp = st and st:FindFirstChild("DarknessPart")
        local pos, part = partOf(dp)
        if pos then table.insert(list, {name = "Этап " .. i, pos = pos, part = part}) end
    end
    local theEnd = stages:FindFirstChild("TheEnd")
    local chest = theEnd and theEnd:FindFirstChild("GoldenChest")
    local trig = chest and (chest:FindFirstChild("Trigger") or chest)
    local cpos, cpart = partOf(trig)
    if cpos then table.insert(list, {name = "Сундук", pos = cpos, part = cpart, final = true}) end
    if #list >= 2 and list[#list].final then return list end
end

-- Запасной путь: ищем детали по именам по всей карте и строим маршрут от ближайшей к дальней
local function collectFallback(fromPos)
    local darks, chest = {}, nil
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Name == "DarknessPart" then
                table.insert(darks, d)
            elseif not chest and d.Name == "Trigger" and d.Parent and d.Parent.Name:lower():find("chest", 1, true) then
                chest = d
            end
        end
    end
    if #darks == 0 and not chest then return nil end
    local list, cur = {}, fromPos
    while #darks > 0 do
        local bi, bd
        for i, p in ipairs(darks) do
            local dd = (p.Position - cur).Magnitude
            if not bd or dd < bd then bi, bd = i, dd end
        end
        local p = table.remove(darks, bi)
        table.insert(list, {name = "Этап " .. (#list + 1), pos = p.Position, part = p})
        cur = p.Position
    end
    if chest then
        table.insert(list, {name = "Сундук", pos = chest.Position, part = chest, final = true})
    end
    return list
end

local function collectWaypoints(fromPos)
    local list = collectMain()
    if list then return list, "основной" end
    list = collectFallback(fromPos)
    if list and #list > 0 then return list, "запасной" end
    return nil, "Не нашёл этапы карты (BoatStages). Возможно, игру обновили"
end

local function claimGold()
    local r = workspace:FindFirstChild("ClaimRiverResultsGold")
        or ReplicatedStorage:FindFirstChild("ClaimRiverResultsGold", true)
    if r and r:IsA("RemoteEvent") then
        pcall(function() r:FireServer() end)
        return true
    end
    return false
end

-- ===== Один цикл фарма =====
local function waitRespawn(oldChar)
    local t0 = os.clock()
    repeat
        task.wait(0.3)
    until not running
        or (lp.Character and lp.Character ~= oldChar and lp.Character:FindFirstChild("HumanoidRootPart")
            and lp.Character:FindFirstChildOfClass("Humanoid"))
        or os.clock() - t0 > 25
end

local function runCycle()
    local char, hum, root = getChar()
    if not (hum and root) or hum.Health <= 0 then
        state.status = "Жду респавн..."
        task.wait(1)
        return
    end

    local wps, how = collectWaypoints(root.Position)
    if not wps then
        state.status = how
        task.wait(4)
        return
    end

    prepareBoat()
    if not (running and state.farm) then return end

    if not beginFlight() then return end
    local reached = true
    for i, wp in ipairs(wps) do
        if not (running and state.farm) then reached = false break end
        state.status = ("Лечу: %s (%d/%d)"):format(wp.name, i, #wps)
        if not flyTo(wp.pos) then reached = false break end
        if wp.part then touch(wp.part) end
        task.wait(wp.final and 0.3 or math.max(state.stageWait, 0))
    end
    endFlight()
    if not reached then return end

    state.status = "Забираю золото..."
    local claimed = claimGold()
    state.cycles += 1
    state.status = claimed and "Золото получено, жду..." or "У сундука (remote не найден), жду..."
    task.wait(math.max(state.chestWait, 0))

    if not (running and state.farm) then return end
    state.status = "Респавн..."
    local _, h2 = getChar()
    if h2 then h2.Health = 0 end
    waitRespawn(char)
    state.status = "Новый круг..."
    task.wait(math.max(state.startDelay, 0))
end

task.spawn(function()
    while running do
        if state.farm then
            local ok, err = pcall(runCycle)
            if not ok then
                endFlight()
                warn("[Dave] ошибка цикла:", err)
                state.status = "Ошибка: " .. tostring(err)
                task.wait(3)
            end
        else
            task.wait(0.3)
        end
    end
end)

-- ===================================================================
-- ЧАСТЬ 2: звук Windows 3.1, фото-фон, блок перед отплытием и «Отплыть»
-- ===================================================================

-- ----- Звук (твой файл > ссылка > встроенная фанфара «та-да») -----
local function buildWav()
    local sr, dur = 22050, 2.4
    local n = math.floor(sr * dur)
    local hits = {
        {t = 0.00, d = 0.9, f = {392.00, 493.88, 587.33}, a = 0.5},
        {t = 0.38, d = 2.0, f = {523.25, 659.25, 783.99, 1046.50}, a = 0.7},
    }
    local buf = table.create(n)
    for i = 0, n - 1 do
        local t = i / sr
        local s = 0
        for _, h in ipairs(hits) do
            local lt = t - h.t
            if lt >= 0 and lt < h.d then
                local e = math.min(lt / 0.01, 1) * math.exp(-lt * 2.2)
                for _, f in ipairs(h.f) do
                    s += e * h.a / #h.f * (
                        math.sin(2 * math.pi * f * lt)
                        + 0.35 * math.sin(4 * math.pi * f * lt)
                        + 0.15 * math.sin(6 * math.pi * f * lt))
                end
            end
        end
        s = math.clamp(s * 0.6, -1, 1)
        buf[i + 1] = string.pack("<i2", math.floor(s * 32767))
    end
    local data = table.concat(buf)
    local header = "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVE"
        .. "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16)
        .. "data" .. string.pack("<I4", #data)
    return header .. data
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64LOOK = {}
for i = 1, 64 do B64LOOK[B64:byte(i)] = i - 1 end

local function b64decode(data)
    local out, n = {}, 0
    local buf, bits = 0, 0
    for i = 1, #data do
        local v = B64LOOK[data:byte(i)]
        if v then
            buf = bit32.bor(bit32.lshift(buf, 6), v)
            bits += 6
            if bits >= 8 then
                bits -= 8
                n += 1
                out[n] = string.char(bit32.band(bit32.rshift(buf, bits), 255))
                buf = bit32.band(buf, bit32.lshift(1, bits) - 1)
            end
        end
    end
    return table.concat(out)
end

local soundAsset
local function getSoundAsset()
    if soundAsset then return soundAsset end
    if not (getcustomasset and writefile and isfile) then return nil end
    for _, name in ipairs(LOCAL_SOUNDS) do
        local ok, res = pcall(function()
            if isfile(name) then return getcustomasset(name) end
        end)
        if ok and res then soundAsset = res return res end
    end
    if SOUND_B64 ~= "" then
        local ok, res = pcall(function()
            writefile("DaveStartup_embedded.mp3", b64decode(SOUND_B64))
            return getcustomasset("DaveStartup_embedded.mp3")
        end)
        if ok and res then soundAsset = res return res end
        warn("[Dave] встроенный звук не загрузился:", res)
    end
    if SOUND_URL ~= "" then
        local ok, res = pcall(function()
            local ext = SOUND_URL:lower():match("%.(%w+)$") or "mp3"
            local file = "DaveStartup_dl." .. ext
            writefile(file, game:HttpGet(SOUND_URL))
            return getcustomasset(file)
        end)
        if ok and res then soundAsset = res return res end
        warn("[Dave] не удалось скачать звук по ссылке")
    end
    local ok, res = pcall(function()
        writefile("DaveStartup_synth.wav", buildWav())
        return getcustomasset("DaveStartup_synth.wav")
    end)
    if ok and res then soundAsset = res return res end
    warn("[Dave] не удалось создать звук:", res)
    return nil
end

local lastSoundAt = 0
function playTada(force)
    if not (state.soundOn or force) then return end
    if tick() - lastSoundAt < 0.4 then return end
    lastSoundAt = tick()
    task.spawn(function()
        local id = getSoundAsset()
        if not id then
            if force and notify then notify("Звук недоступен: нужны getcustomasset и writefile") end
            return
        end
        local s = Instance.new("Sound")
        s.SoundId = id
        s.Volume = math.clamp(state.volume, 0, 3)
        s.Parent = SoundService
        local t0 = tick()
        while not s.IsLoaded and tick() - t0 < 3 do task.wait(0.1) end
        if s.TimeLength == 0 and force and notify then
            notify("Звук не играет (формат?). Попробуй свой mp3 или ogg")
        end
        s:Play()
        s.Ended:Connect(function() s:Destroy() end)
        task.delay(8, function() if s then s:Destroy() end end)
    end)
end

-- ----- Фото-фон -----

local function loadBackground(img)
    task.spawn(function()
        if not (getcustomasset and writefile and isfile) then
            warn("[Dave] фон: у executor нет getcustomasset/writefile")
            return
        end
        local asset
        local ok, err = pcall(function()
            if isfile(BG_FILE) then
                asset = getcustomasset(BG_FILE)
            elseif BG_URL ~= "" then
                writefile("DaveBG_dl.png", game:HttpGet(BG_URL))
                asset = getcustomasset("DaveBG_dl.png")
            elseif BG_B64 ~= "" then
                writefile("DaveBG_embedded.png", b64decode(BG_B64))
                asset = getcustomasset("DaveBG_embedded.png")
            end
        end)
        if ok and asset then img.Image = asset else warn("[Dave] фон не загрузился:", err) end
    end)
end

-- ----- Кнопка интерфейса: поиск и нажатие -----
local function isShown(gui)
    local cur = gui
    while cur and cur ~= game do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

local function findSailButton()
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    for _, v in ipairs(pg:GetDescendants()) do
        if (v:IsA("TextButton") or v:IsA("TextLabel")) and v.Text ~= "" and isShown(v) and v.AbsoluteSize.X > 0 then
            local raw = v.Text
            local low = raw:lower()
            for _, w in ipairs(SAIL_WORDS) do
                if raw:find(w, 1, true) or low:find(w, 1, true) then
                    local btn = v
                    while btn and not btn:IsA("GuiButton") do
                        btn = btn.Parent
                        if btn == pg then btn = nil break end
                    end
                    return btn or v
                end
            end
        end
    end
end

local function pressButton(btn)
    local fired = false
    if getconnections then
        for _, sig in ipairs({"MouseButton1Click", "Activated", "MouseButton1Down", "MouseButton1Up"}) do
            pcall(function()
                for _, c in ipairs(getconnections(btn[sig])) do c:Fire() fired = true end
            end)
        end
    end
    if not fired then
        local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
        local inset = GuiService:GetGuiInset()
        VIM:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, true, game, 0)
        VIM:SendMouseButtonEvent(pos.X, pos.Y + inset.Y, 0, false, game, 0)
    end
end

-- ----- Запись и повтор вызовов игры (установка блока / «Отплыть») -----
local rec = {block = nil, sail = nil}
local recording, recordUntil = nil, 0
local hookActive = true
local SKIP = {"mouse", "move", "camera", "ping", "heartbeat", "cursor", "afk", "analytics", "log", "look"}

local function describe(inst)
    local d = {name = inst.Name}
    if inst.Parent and inst.Parent:IsA("Tool") then d.tool = inst.Parent.Name end
    local names, cur = {}, inst
    while cur and cur ~= game do
        table.insert(names, 1, cur.Name)
        cur = cur.Parent
    end
    d.names = names
    d.full = inst:GetFullName()
    return d
end

local function resolveRemote(d)
    if d.tool then
        local char = lp.Character
        local t = (char and char:FindFirstChild(d.tool)) or lp.Backpack:FindFirstChild(d.tool)
        return t and t:FindFirstChild(d.name)
    end
    local cur = game
    for _, n in ipairs(d.names) do
        cur = cur and cur:FindFirstChild(n)
        if not cur then return nil end
    end
    return cur
end

local hookOk = false
if hookmetamethod and getnamecallmethod then
    local oldNamecall
    local function handler(self, ...)
        if hookActive and recording then
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and typeof(self) == "Instance"
                and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction"))
                and os.clock() < recordUntil then
                local nm = self.Name:lower()
                local skip = false
                for _, w in ipairs(SKIP) do
                    if nm:find(w, 1, true) then skip = true break end
                end
                if not skip then
                    local slot = recording
                    recording = nil
                    local d = describe(self)
                    d.method = method
                    d.args = table.pack(...)
                    rec[slot] = d
                    task.defer(function()
                        print("[Dave] записано (" .. slot .. "): " .. d.full .. " :" .. method)
                        if notify then notify("Записано: " .. d.name) end
                    end)
                end
            end
        end
        return oldNamecall(self, ...)
    end
    local ok = pcall(function()
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure and newcclosure(handler) or handler)
    end)
    hookOk = ok and oldNamecall ~= nil
end

local function startRecord(slot)
    if not hookOk then
        notify("Executor не умеет записывать вызовы (нет hookmetamethod)")
        return
    end
    recording = slot
    recordUntil = os.clock() + 25
    notify(slot == "block" and "Запись 25 сек: молоток уже в руках, поставь первый блок" or "Запись 25 сек: нажми «Отплыть» руками")
    task.delay(25, function()
        if recording == slot then
            recording = nil
            notify("Ничего не поймал. Попробуй ещё раз")
        end
    end)
end

local function replay(slot)
    local r = rec[slot]
    if not r then return false end
    local remote
    for _ = 1, 20 do
        local _, hum = getChar()
        if r.tool and hum then
            local t = lp.Backpack:FindFirstChild(r.tool)
            if t then hum:EquipTool(t) end
        end
        remote = resolveRemote(r)
        if remote then break end
        task.wait(0.25)
    end
    if not remote then return false end
    task.spawn(function()
        pcall(function()
            if r.method == "InvokeServer" then
                remote:InvokeServer(table.unpack(r.args, 1, r.args.n))
            else
                remote:FireServer(table.unpack(r.args, 1, r.args.n))
            end
        end)
    end)
    return true
end

-- ----- Подготовка лодки: блок + «Отплыть» -----
local SLOT_KEYS = {"One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"}

-- Достаём молоток: клавиша слота (если в руках пусто), запасной вариант — по порядку в рюкзаке
local function equipSlot(n)
    local char, hum = getChar()
    if not (char and hum) then return end
    if char:FindFirstChildOfClass("Tool") then return end
    n = math.clamp(math.floor(n), 1, 9)
    local kc = Enum.KeyCode[SLOT_KEYS[n]]
    VIM:SendKeyEvent(true, kc, false, game)
    task.wait(0.05)
    VIM:SendKeyEvent(false, kc, false, game)
    task.wait(0.5)
    if not char:FindFirstChildOfClass("Tool") then
        local t = lp.Backpack:GetChildren()[n]
        if t and t:IsA("Tool") then hum:EquipTool(t) task.wait(0.4) end
    end
end

local warned = {}
local function warnOnce(key, text)
    if warned[key] then return end
    warned[key] = true
    notify(text)
end

function prepareBoat()
    if state.useBlock then
        state.status = "Ставлю блок..."
        equipSlot(state.buildSlot)
        if rec.block then
            if not replay("block") then warnOnce("blockfail", "Блок не поставился: не нашёл remote. Запиши заново") end
        else
            warnOnce("blockrec", "Блок не ставится: сначала нажми «Записать: поставить блок»")
        end
        task.wait(0.7)
    end
    if state.useSail then
        state.status = "Жму «Отплыть»..."
        local btn = findSailButton()
        if btn then
            pressButton(btn)
        elseif rec.sail then
            replay("sail")
        else
            warnOnce("sail", "Кнопка «Отплыть» не найдена. Нажми «Записать: кнопка Отплыть»")
        end
        task.wait(1.2)
    end
end

-- Анти-АФК
bind(lp.Idled, function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ===================================================================
-- ИНТЕРФЕЙС
-- ===================================================================
local THEME = {
    accent = Color3.fromRGB(226, 34, 34),
    bg = Color3.fromRGB(20, 20, 24),
    panel = Color3.fromRGB(34, 34, 40),
    panel2 = Color3.fromRGB(50, 50, 60),
    text = Color3.fromRGB(238, 238, 242),
    muted = Color3.fromRGB(165, 165, 176),
    off = Color3.fromRGB(74, 74, 86),
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function corner(o, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end

local function tween(o, t, props)
    return TS:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
end

local sg = new("ScreenGui", {Name = "DaveBABFT", ResetOnSpawn = false}, guiParent)

function notify(text)
    local l = new("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -90),
        Size = UDim2.fromOffset(400, 34),
        BackgroundColor3 = THEME.bg,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        Text = text,
    }, sg)
    corner(l, 8)
    new("UIStroke", {Color = THEME.accent, Thickness = 1.5}, l)
    task.delay(3, function() if l then l:Destroy() end end)
end

local HEAD_H, WIDTH, FULL_H = 44, 310, 520

local frame = new("Frame", {
    Size = UDim2.fromOffset(WIDTH, FULL_H),
    Position = UDim2.fromOffset(40, 110),
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
    Active = true,
    Draggable = true,
    ClipsDescendants = true,
}, sg)
corner(frame, 12)
new("UIStroke", {Color = THEME.accent, Thickness = 2}, frame)

-- Фото на фоне окна: размер = размер окна, прозрачность по умолчанию 50%
local bgImg = new("ImageLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ScaleType = Enum.ScaleType.Crop,
    ImageTransparency = math.clamp(state.bgAlpha, 0, 1),
    ZIndex = 0,
}, frame)
corner(bgImg, 12)
loadBackground(bgImg)

-- Шапка: клик сворачивает/разворачивает меню
local header = new("TextButton", {
    Size = UDim2.new(1, -44, 0, HEAD_H),
    BackgroundTransparency = 1,
    Text = "СКРИПТ ОТ ДЭЙВА | BABFT",
    TextColor3 = THEME.text,
    Font = Enum.Font.GothamBlack,
    TextSize = 15,
    AutoButtonColor = false,
}, frame)

-- Крестик: полностью скрывает меню (вернуть на K)
local closeBtn = new("TextButton", {
    Position = UDim2.new(1, -36, 0, 9),
    Size = UDim2.fromOffset(26, 26),
    BackgroundColor3 = THEME.accent,
    Text = "X",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 14,
}, frame)
corner(closeBtn, 7)

local body = new("ScrollingFrame", {
    Position = UDim2.fromOffset(8, HEAD_H + 2),
    Size = UDim2.new(1, -16, 1, -(HEAD_H + 10)),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = THEME.accent,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, frame)
new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, body)
new("UIPadding", {PaddingRight = UDim.new(0, 8)}, body)

local order = 0
local panelFrames = {}
local function nextOrder() order += 1 return order end

local function row(h)
    local f = new("Frame", {
        Size = UDim2.new(1, 0, 0, h),
        BackgroundColor3 = THEME.panel,
        BackgroundTransparency = state.panelAlpha,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    corner(f, 8)
    table.insert(panelFrames, f)
    return f
end

local function addLabel(text, h, card)
    local l = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, h),
        BackgroundColor3 = THEME.panel,
        BackgroundTransparency = card and state.panelAlpha or 1,
        TextColor3 = card and THEME.text or THEME.muted,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = text,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    if card then
        table.insert(panelFrames, l)
        corner(l, 8)
        new("UIPadding", {
            PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
            PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
        }, l)
    end
    return l
end

-- Переключатель
local setFarm
local function addToggle(text, get, set)
    local r = row(38)
    new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -66, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, r)
    local pill = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(42, 22),
        BackgroundColor3 = THEME.off,
        BorderSizePixel = 0,
    }, r)
    corner(pill, 11)
    local knob = new("Frame", {
        Position = UDim2.new(0, 2, 0.5, -9),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, pill)
    corner(knob, 9)
    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5,
    }, r)
    local function paint(anim)
        local on = get()
        local pc = on and THEME.accent or THEME.off
        local kp = on and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
        if anim then
            tween(pill, 0.15, {BackgroundColor3 = pc}):Play()
            tween(knob, 0.15, {Position = kp}):Play()
        else
            pill.BackgroundColor3 = pc
            knob.Position = kp
        end
    end
    paint(false)
    hit.MouseButton1Click:Connect(function()
        set(not get())
        paint(true)
    end)
    return function() paint(true) end
end

local function addInput(labelText, key, onApply)
    local r = row(36)
    new("TextLabel", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.55, -12, 1, 0),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = THEME.text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, r)
    local box = new("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.new(0.45, -12, 0, 26),
        BackgroundColor3 = THEME.panel2,
        TextColor3 = THEME.text,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        ClearTextOnFocus = false,
        Text = tostring(state[key]),
    }, r)
    corner(box, 6)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then state[key] = n else box.Text = tostring(state[key]) end
        saveCfg()
        if onApply then onApply() end
    end)
end

local function addButton(text, onClick)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = THEME.panel2,
        TextColor3 = THEME.text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        Text = text,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, body)
    corner(b, 8)
    b.MouseEnter:Connect(function() tween(b, 0.12, {BackgroundColor3 = THEME.accent}):Play() end)
    b.MouseLeave:Connect(function() tween(b, 0.12, {BackgroundColor3 = THEME.panel2}):Play() end)
    b.MouseButton1Click:Connect(onClick)
end

-- Карточка статуса
local info = addLabel("", 86, true)

local repaintFarm = addToggle("Автофарм золота",
    function() return state.farm end,
    function(on)
        state.farm = on
        if on then
            state.status = "Запуск..."
        else
            state.status = "Выключено"
            endFlight()
        end
    end)
setFarm = function(on)
    state.farm = on
    state.status = on and "Запуск..." or "Выключено"
    if not on then endFlight() end
    repaintFarm()
end

addInput("Скорость полёта (студов/сек)", "speed")
addInput("Пауза у стены этапа (сек)", "stageWait")
addInput("Пауза у сундука (сек)", "chestWait")
addInput("Пауза после респавна (сек)", "startDelay")

addToggle("Ставить блок перед отплытием",
    function() return state.useBlock end,
    function(on) state.useBlock = on saveCfg() end)
addToggle("Нажимать «Отплыть»",
    function() return state.useSail end,
    function(on) state.useSail = on saveCfg() end)
addInput("Слот молотка (1-9)", "buildSlot")
addButton("Записать: поставить блок", function() startRecord("block") end)
addButton("Записать: кнопка «Отплыть»", function() startRecord("sail") end)

addToggle("Звук Windows 3.1 (открыть/закрыть)",
    function() return state.soundOn end,
    function(on) state.soundOn = on saveCfg() end)
addInput("Громкость звука (0-3)", "volume")
addButton("Проиграть звук", function() playTada(true) end)
addInput("Прозрачность фото (0-1)", "bgAlpha", function()
    bgImg.ImageTransparency = math.clamp(state.bgAlpha, 0, 1)
end)
addInput("Прозрачность панелей (0-1)", "panelAlpha", function()
    for _, f in ipairs(panelFrames) do
        f.BackgroundTransparency = math.clamp(state.panelAlpha, 0, 1)
    end
end)

addButton("Проверить карту", function()
    local _, _, root = getChar()
    local wps, how = collectWaypoints(root and root.Position or Vector3.zero)
    if wps then
        notify(("Найдено точек: %d (%s поиск)"):format(#wps, how))
        print("[Dave] маршрут (" .. how .. "):")
        for i, wp in ipairs(wps) do
            print(("  %d. %s  %s"):format(i, wp.name, tostring(wp.pos)))
        end
    else
        notify(how)
    end
end)

addLabel("Скрипт сам летит от острова до сундука, забирает золото, делает респавн и повторяет. Скорость 250 — безопасный старт, выше риск бана. K — меню, G — фарм. Перед первым запуском: достань молоток (слот 2), нажми «Записать: поставить блок» и поставь самый первый блок. Потом «Записать: кнопка Отплыть» и нажми её руками. После перезахода запись делается заново.", 140)

-- Обновление карточки статуса
local startedAt, startGold = os.clock(), nil
local function fmtTime(sec)
    sec = math.floor(sec)
    return ("%02d:%02d:%02d"):format(sec // 3600, (sec % 3600) // 60, sec % 60)
end

task.spawn(function()
    while running do
        local v = getGold()
        local goldLine
        if v then
            startGold = startGold or v
            goldLine = ("Золото: %d (за сессию +%d)"):format(v, v - startGold)
        else
            goldLine = "Золото: счётчик не найден"
        end
        local el = os.clock() - startedAt
        local perHour = el > 60 and (state.cycles / el * 3600) or 0
        info.Text = ("%s\nКругов: %d (≈%.1f/час)\nВремя: %s\n%s"):format(
            state.status, state.cycles, perHour, fmtTime(el), goldLine)
        task.wait(0.5)
    end
end)

-- Сворачивание по клику на шапку (если это не перетаскивание)
local collapsed, downPos = false, nil
header.MouseButton1Down:Connect(function() downPos = frame.Position end)
header.MouseButton1Click:Connect(function()
    if downPos and frame.Position ~= downPos then return end
    collapsed = not collapsed
    playTada()
    tween(frame, 0.2, {Size = UDim2.fromOffset(WIDTH, collapsed and HEAD_H or FULL_H)}):Play()
end)

closeBtn.MouseButton1Click:Connect(function()
    playTada()
    frame.Visible = false
end)

-- K — меню, G — автофарм
bind(UIS.InputBegan, function(input, gpe)
    if gpe or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if input.KeyCode == Enum.KeyCode.K then
        playTada()
        frame.Visible = not frame.Visible
    elseif input.KeyCode == Enum.KeyCode.G then
        setFarm(not state.farm)
    end
end)

if game.PlaceId ~= 537413528 then
    print("[Dave] PlaceId:", game.PlaceId, "(Build A Boat for Treasure обычно 537413528)")
end
playTada()
notify("Скрипт загружен. K — меню, G — фарм")

env.DaveBabftCleanup = function()
    running = false
    hookActive = false
    state.farm = false
    endFlight()
    for _, c in ipairs(conns) do c:Disconnect() end
    sg:Destroy()
end
