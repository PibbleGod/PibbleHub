local ok, err = xpcall(function()
    local Players = game:GetService("Players")
    local CS = game:GetService("CollectionService")
    local R = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
    local CandyState = R:WaitForChild("CandyState")
    local Request = R:WaitForChild("RequestCandyState")
    local StartBattle = R:WaitForChild("StartBattle")
    local BattleEnd = R:WaitForChild("BattleEnd")
    local OpenTower = R:WaitForChild("OpenHalloweenTower")
    local EndTower = R:WaitForChild("EndTowerRemote", 5) -- "Give up"
    local player = Players.LocalPlayer

    local SLOT = 2          -- updated automatically when the tower UI opens
    local MAX_FLOOR = 500
    local MAX_STAGE = 100   -- 100 groups of 5 floors
    local AUTO_DELAY = 3    -- seconds between two milestones / retries
    local END_ARG = 1       -- argument sent to EndTowerRemote (as logged when clicking Give up)

    local state, offset, auto, busy, total, nextT = {}, 0, false, false, 0, nil
    local stage, towerAuto = 1, false
    local restoreTowerGui   -- defined below, shows the tower UI again after auto stops
    local popOn, minPopFloor = false, 1            -- Infinite Tower: auto give up when a weather appears
    local infFloor = 1                             -- current floor of the Infinite Tower run
    local weatherName, lastGiveUp = nil, 0
    -- List of weathers (shown in the Weather menu)
    local WEATHERS = {"Typhoon", "Blizzard", "Windstorm", "Sharingan", "Singularity", "Lightning",
                      "Monarch Domain", "Void", "Made in Heaven"}
    -- Selected weathers (lowercase name -> true). Empty = any weather triggers the give up.
    local selected = {}

    local function weatherAllowed(name)
        if next(selected) == nil then return true end
        return selected[tostring(name or ""):lower()] == true
    end

    CandyState.OnClientEvent:Connect(function(t, now)
        if type(now) == "number" then offset = now - os.time() end
        state = type(t) == "table" and t or {}
    end)

    -- ========== UI ==========
    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    for _, n in ipairs({"PibbleHub", "HalloweenUI"}) do
        local old = parent:FindFirstChild(n)
        if old then old:Destroy() end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "PibbleHub"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = parent

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(250, 414)
    main.Position = UDim2.new(0, 30, 0.3, 0)
    main.BackgroundColor3 = Color3.fromRGB(26, 14, 38)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.ZIndex = 1
    main.Parent = gui
    Instance.new("UICorner", main)

    local FONT = Enum.Font.SourceSansBold
    local ORANGE = Color3.fromRGB(255, 160, 50)
    local BLUE = Color3.fromRGB(70, 110, 200)
    local DARK = Color3.fromRGB(80, 60, 110)
    local RED = Color3.fromRGB(110, 60, 60)
    local GREEN = Color3.fromRGB(50, 140, 80)
    local PURPLE = Color3.fromRGB(120, 60, 150)

    -- ========== Open / collapse button (square, rounded corners) ==========
    -- Icon: the embedded puppy is used by default. To force another image, paste its id here, e.g. "rbxassetid://123456789"
    local ICON_ID = ""
    -- Puppy icon embedded in the script (base64 JPEG). It is written to a local file and loaded with getcustomasset.
    local ICON_B64 = [[
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
]]
    local function b64decode(data)
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local map = {}
        for i = 1, #alphabet do map[alphabet:byte(i)] = i - 1 end
        local out, buf, bits = {}, 0, 0
        for i = 1, #data do
            local v = map[data:byte(i)]
            if v then
                buf = buf * 64 + v
                bits += 6
                if bits >= 8 then
                    bits -= 8
                    local byte = math.floor(buf / 2 ^ bits)
                    buf = buf - byte * 2 ^ bits
                    out[#out + 1] = string.char(byte)
                end
            end
        end
        return table.concat(out)
    end
    if ICON_ID == "" then
        pcall(function()
            if writefile and getcustomasset then
                writefile("pibblehub_icon.jpg", b64decode(ICON_B64))
                ICON_ID = getcustomasset("pibblehub_icon.jpg")
            end
        end)
    end
    local toggle
    if ICON_ID ~= "" then
        toggle = Instance.new("ImageButton")
        toggle.Image = ICON_ID
        toggle.ScaleType = Enum.ScaleType.Crop
    else
        toggle = Instance.new("TextButton")
        toggle.Font = FONT
        toggle.TextSize = 22
        toggle.TextColor3 = ORANGE
        toggle.Text = "P"
    end
    toggle.Name = "ToggleButton"
    toggle.Size = UDim2.fromOffset(44, 44)
    toggle.Position = UDim2.new(0, 30, 0.3, -52)
    toggle.BackgroundColor3 = Color3.fromRGB(26, 14, 38)
    toggle.BorderSizePixel = 0
    toggle.Active = true
    toggle.Draggable = true
    toggle.ZIndex = 50
    toggle.Parent = gui
    local toggleCorner = Instance.new("UICorner", toggle)
    toggleCorner.CornerRadius = UDim.new(0, 12)
    local toggleStroke = Instance.new("UIStroke", toggle)
    toggleStroke.Color = ORANGE
    toggleStroke.Thickness = 2
    toggle.MouseButton1Click:Connect(function()
        main.Visible = not main.Visible
    end)

    local function label(text, y, color, size)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -20, 0, 20)
        l.Position = UDim2.fromOffset(10, y)
        l.BackgroundTransparency = 1
        l.Font = FONT
        l.TextSize = size or 16
        l.TextColor3 = color or Color3.new(1, 1, 1)
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Text = text
        l.ZIndex = 5
        l.Parent = main
        return l
    end

    local function button(text, x, y, w, h, color, parentFrame, z)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, h)
        b.Position = UDim2.fromOffset(x, y)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = FONT
        b.TextSize = 15
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Text = text
        b.ZIndex = z or 5
        b.Parent = parentFrame or main
        Instance.new("UICorner", b)
        return b
    end

    label("PibbleHub", 5, ORANGE, 20)

    -- Candy section
    label("Candy Collector", 30, ORANGE)
    local status = label("Status: idle", 50)
    local timer = label("Respawn: -", 70)
    local count = label("Collected: 0", 90)
    local goBtn = button("Collect now", 10, 114, 105, 26, BLUE)
    local autoBtn = button("Auto: OFF", 125, 114, 115, 26, RED)

    -- Tower section
    label("Halloween Tower", 152, ORANGE)
    local floorLbl = label("Floors 1-5", 172)
    local towerStatus = label("Tower: idle", 192)

    local minusBtn = button("-", 10, 218, 36, 28, DARK)
    local floorBox = Instance.new("TextBox")
    floorBox.Size = UDim2.fromOffset(122, 28)
    floorBox.Position = UDim2.fromOffset(52, 218)
    floorBox.BackgroundColor3 = Color3.fromRGB(45, 30, 65)
    floorBox.BorderSizePixel = 0
    floorBox.Font = FONT
    floorBox.TextSize = 16
    floorBox.TextColor3 = Color3.new(1, 1, 1)
    floorBox.PlaceholderText = "Floor (1-500)"
    floorBox.PlaceholderColor3 = Color3.fromRGB(150, 140, 170)
    floorBox.ClearTextOnFocus = true
    floorBox.Text = "1"
    floorBox.ZIndex = 5
    floorBox.Parent = main
    Instance.new("UICorner", floorBox)
    local plusBtn = button("+", 180, 218, 36, 28, DARK)

    local function firstFloor(s) return (s - 1) * 5 + 1 end

    local function setStage(s)
        stage = math.clamp(math.floor(s), 1, MAX_STAGE)
        local a = firstFloor(stage)
        floorBox.Text = tostring(a)
        floorLbl.Text = ("Floors %d-%d"):format(a, a + 4)
    end

    local function readBox()
        local n = tonumber(floorBox.Text)
        if n then setStage(math.ceil(math.clamp(math.floor(n), 1, MAX_FLOOR) / 5)) end
    end

    floorBox.FocusLost:Connect(function()
        local n = tonumber(floorBox.Text)
        if n then readBox() else setStage(stage) end
    end)

    minusBtn.MouseButton1Click:Connect(function() setStage(stage - 1) end)
    plusBtn.MouseButton1Click:Connect(function() setStage(stage + 1) end)

    local startBtn = button("Start", 10, 258, 105, 28, BLUE)
    local towerAutoBtn = button("Auto: OFF", 125, 258, 115, 28, RED)

    -- Infinite Tower section (separate from the Halloween Tower)
    label("Infinite Tower", 298, ORANGE)
    local infStatus = label("Auto give up: idle", 318)
    local wLabel = button("Weather: Any", 10, 342, 230, 28, DARK)
    local popBtn = button("Pop: OFF", 10, 378, 105, 28, RED)
    local minBox = Instance.new("TextBox")
    minBox.Size = UDim2.fromOffset(115, 28)
    minBox.Position = UDim2.fromOffset(125, 378)
    minBox.BackgroundColor3 = Color3.fromRGB(45, 30, 65)
    minBox.BorderSizePixel = 0
    minBox.Font = FONT
    minBox.TextSize = 15
    minBox.TextColor3 = Color3.new(1, 1, 1)
    minBox.PlaceholderText = "Min floor"
    minBox.PlaceholderColor3 = Color3.fromRGB(150, 140, 170)
    minBox.ClearTextOnFocus = true
    minBox.Text = "1"
    minBox.ZIndex = 5
    minBox.Parent = main
    Instance.new("UICorner", minBox)

    -- ========== Weather menu (opens to the right of the main window) ==========
    local ITEM_H, ITEM_GAP = 28, 4
    local menuH = (#WEATHERS + 1) * (ITEM_H + ITEM_GAP) + ITEM_GAP
    local weatherMenu = Instance.new("Frame")
    weatherMenu.Size = UDim2.fromOffset(190, menuH)
    weatherMenu.Position = UDim2.fromOffset(258, 304)
    weatherMenu.BackgroundColor3 = Color3.fromRGB(36, 22, 52)
    weatherMenu.BorderSizePixel = 0
    weatherMenu.Visible = false
    weatherMenu.ZIndex = 20
    weatherMenu.Parent = main
    Instance.new("UICorner", weatherMenu)

    local anyBtn = button("Any weather", 8, ITEM_GAP, 174, ITEM_H, DARK, weatherMenu, 21)
    local weatherBtns = {}
    for i, w in ipairs(WEATHERS) do
        local y = ITEM_GAP + i * (ITEM_H + ITEM_GAP)
        weatherBtns[w] = button(w, 8, y, 174, ITEM_H, DARK, weatherMenu, 21)
    end

    local function refreshWeatherPick()
        local n, last = 0, nil
        for _, w in ipairs(WEATHERS) do
            local on = selected[w:lower()] == true
            if on then n += 1; last = w end
            weatherBtns[w].BackgroundColor3 = on and GREEN or DARK
            weatherBtns[w].Text = (on and "[x] " or "[  ] ") .. w
        end
        anyBtn.BackgroundColor3 = (n == 0) and GREEN or DARK
        if n == 0 then
            wLabel.Text = "Weather: Any"
        elseif n == 1 then
            wLabel.Text = "Weather: " .. last
        else
            wLabel.Text = ("Weather: %d selected"):format(n)
        end
    end

    for _, w in ipairs(WEATHERS) do
        weatherBtns[w].MouseButton1Click:Connect(function()
            local k = w:lower()
            if selected[k] then selected[k] = nil else selected[k] = true end
            refreshWeatherPick()
        end)
    end
    anyBtn.MouseButton1Click:Connect(function()
        selected = {}
        refreshWeatherPick()
    end)
    wLabel.MouseButton1Click:Connect(function()
        weatherMenu.Visible = not weatherMenu.Visible
    end)
    refreshWeatherPick()

    setStage(1)

    -- ========== Tower logic ==========
    local function fireBind(name, ...)
        local pg = player:FindFirstChild("PlayerGui")
        local b = pg and pg:FindFirstChild(name)
        if b and b:IsA("BindableEvent") then b:Fire(...) end
    end

    local function enterStage(s, isAuto)
        local m = firstFloor(s)
        local suffix = SLOT == 2 and "2" or ""
        -- same calls the game's own Enter button makes
        fireBind("ResetBattleFloor" .. suffix, m, "infinite_room")
        fireBind("StartInfiniteRoomBattle" .. suffix, m, "halloween", isAuto or nil)
        StartBattle:FireServer("infinite_room", {
            tower = "halloween",
            milestone = m,
            slot = SLOT,
        })
        towerStatus.Text = ("Tower: started %d-%d"):format(m, m + 4)
    end

    -- Infinite Tower "Give up": defined below (needs clean/shown helpers)
    local giveUp

    -- Weather detection on screen (see scanWeather below)
    local function clean(t) return (tostring(t):gsub("<[^>]+>", "")) end

    local function shown(o)
        local x = o
        while x and x ~= game do
            if x:IsA("ScreenGui") then
                if not x.Enabled then return false end
            elseif x:IsA("GuiObject") then
                if not x.Visible then return false end
            end
            x = x.Parent
        end
        return true
    end

    -- Reads PlayerGui.WeatherGui.WeatherIndicator: WeatherName "[ Void ]" + TimerLabel "Time Remaining: 268".
    -- (EventIndicator is a different thing, e.g. "[ Release Event ]", and is ignored.)
    local function scanWeather()
        local pg = player:FindFirstChild("PlayerGui")
        local wg = pg and pg:FindFirstChild("WeatherGui")
        local ind = wg and wg:FindFirstChild("WeatherIndicator")
        if not ind then return nil end
        local nameL, timerL = ind:FindFirstChild("WeatherName"), ind:FindFirstChild("TimerLabel")
        if not (nameL and timerL and shown(nameL) and shown(timerL)) then return nil end
        local n = clean(nameL.Text):match("^%s*%[%s*(.-)%s*%]%s*$")
        local secs = tonumber(clean(timerL.Text):match("(%d+)"))
        if n and n ~= "" and secs and secs > 0 then return n end
        return nil
    end

    -- ===== Give up =====
    -- Method 1: press the game's own "Give up" button (fires its real click handlers)
    -- Method 2 (fallback): fire EndTowerRemote directly
    local function btnText(o)
        if o:IsA("TextButton") or o:IsA("TextLabel") then return clean(o.Text):lower() end
        return ""
    end

    local function findButton(pred)
        local pg = player:FindFirstChild("PlayerGui")
        if not pg then return nil end
        local best
        for _, d in ipairs(pg:GetDescendants()) do
            if d ~= gui and not d:IsDescendantOf(gui) and pred(btnText(d)) then
                -- a label inside a button: use the button
                local b = d
                if not (b:IsA("TextButton") or b:IsA("ImageButton")) then
                    b = d:FindFirstAncestorWhichIsA("TextButton") or d:FindFirstAncestorWhichIsA("ImageButton")
                end
                if b then
                    if shown(b) then return b end
                    best = best or b
                end
            end
        end
        return best
    end

    local function activateButton(b)
        local fired = false
        for _, sig in ipairs({"MouseButton1Click", "Activated"}) do
            if typeof(firesignal) == "function" then
                if pcall(function() firesignal(b[sig]) end) then fired = true end
            elseif typeof(getconnections) == "function" then
                pcall(function()
                    for _, c in ipairs(getconnections(b[sig])) do c:Fire(); fired = true end
                end)
            end
            if fired then break end
        end
        return fired
    end

    -- some games ask "are you sure?" after Give up: press Yes / Confirm if it appears
    local function confirmDialog()
        local b = findButton(function(t)
            return t == "yes" or t == "confirm" or t == "give up!" or t:find("^yes[%s%p]") ~= nil
        end)
        if b and shown(b) then activateButton(b) end
    end

    giveUp = function()
        lastGiveUp = os.clock()
        infFloor = 1 -- the game restarts the run by itself
        local method
        local b = findButton(function(t) return t:find("give up", 1, true) ~= nil end)
        if b and activateButton(b) then
            method = "button"
            task.delay(0.6, confirmDialog)
        elseif EndTower then
            EndTower:FireServer(END_ARG)
            method = "remote"
        end
        return method
    end

    -- Every second while Pop is ON: reads the weather and shows why it does (or doesn't) give up
    task.spawn(function()
        while gui.Parent do
            task.wait(1)
            if popOn then
                local n = scanWeather()
                weatherName = n
                local why
                if not n then
                    why = "no weather"
                elseif not weatherAllowed(n) then
                    why = "not selected"
                elseif infFloor < minPopFloor then
                    why = "floor<min"
                elseif os.clock() - lastGiveUp < 8 then
                    why = "cooldown"
                else
                    why = "GIVE UP"
                    giveUp()
                end
                infStatus.Text = ("%s | F%d | %s"):format(n or "-", infFloor, why)
            end
        end
    end)

    local function stopTowerAuto(msg)
        towerAuto = false
        if restoreTowerGui then restoreTowerGui() end
        towerAutoBtn.Text = "Auto: OFF"
        towerAutoBtn.BackgroundColor3 = RED
        if msg then towerStatus.Text = msg end
    end

    -- hides the game's tower UI (used while auto runs so it doesn't pop up again)
    local hiddenObjs = {}

    local function hideObj(o)
        if o:IsA("ScreenGui") then
            if o.Enabled then o.Enabled = false; hiddenObjs[o] = true end
        elseif o:IsA("GuiObject") then
            if o.Visible then o.Visible = false; hiddenObjs[o] = true end
        end
    end

    local towerPanel, lastScan = nil, 0

    -- Finds the tower window only: the smallest frame that contains BOTH the
    -- "Enter Tower" button and the "Floors x-y" list. Other UIs are never matched.
    local function findTowerPanel(pg)
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("TextLabel"))
                and tostring(d.Text):lower():find("enter tower", 1, true) then
                local a = d.Parent
                while a and not a:IsA("ScreenGui") do
                    if a:IsA("GuiObject") then
                        for _, x in ipairs(a:GetDescendants()) do
                            if (x:IsA("TextLabel") or x:IsA("TextButton"))
                                and tostring(x.Text):find("^%s*[Ff]loors?%s+%d") then
                                return a
                            end
                        end
                    end
                    a = a.Parent
                end
            end
        end
    end

    local function hideTowerGui()
        pcall(function()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return end
            -- the tower's own gui, if it exists under this name
            local g = pg:FindFirstChild("HalloweenTowerGui")
            if g then hideObj(g) end
            -- the tower window found by content (cached, rescanned at most once per second)
            if not (towerPanel and towerPanel.Parent) and os.clock() - lastScan > 1 then
                lastScan = os.clock()
                towerPanel = findTowerPanel(pg)
            end
            if towerPanel and towerPanel.Parent then hideObj(towerPanel) end
        end)
    end

    restoreTowerGui = function()
        for o in pairs(hiddenObjs) do
            if o.Parent then
                pcall(function()
                    if o:IsA("ScreenGui") then o.Enabled = true else o.Visible = true end
                end)
            end
            hiddenObjs[o] = nil
        end
    end

    -- The server answers OpenHalloweenTower with (clearedFloor, slot, pausedRun)
    -- (keeps SLOT up to date when the game opens the tower UI)
    OpenTower.OnClientEvent:Connect(function(cleared, slot)
        SLOT = (slot == 2) and 2 or 1
        towerStatus.Text = ("Tower: UI open (cleared %s, slot %d)"):format(tostring(cleared or 0), SLOT)
        if towerAuto then task.defer(hideTowerGui) end
    end)

    popBtn.MouseButton1Click:Connect(function()
        popOn = not popOn
        popBtn.Text = popOn and "Pop: ON" or "Pop: OFF"
        popBtn.BackgroundColor3 = popOn and GREEN or RED
    end)

    minBox.FocusLost:Connect(function()
        local n = tonumber(minBox.Text)
        if n then minPopFloor = math.max(1, math.floor(n)) end -- no upper limit
        minBox.Text = tostring(minPopFloor)
    end)

    startBtn.MouseButton1Click:Connect(function()
        readBox()
        enterStage(stage, false)
    end)

    towerAutoBtn.MouseButton1Click:Connect(function()
        if towerAuto then
            stopTowerAuto("Tower: auto stopped")
        else
            readBox()
            towerAuto = true
            towerAutoBtn.Text = "Auto: ON"
            towerAutoBtn.BackgroundColor3 = GREEN
            enterStage(stage, true)
            -- keep the tower UI hidden while auto runs
            task.spawn(function()
                while towerAuto and gui.Parent do
                    hideTowerGui()
                    task.wait(0.25)
                end
            end)
        end
    end)

    -- Any of these results counts as a loss -> retry the SAME stage
    local LOSS = { lose = true, loss = true, lost = true, defeat = true, fail = true, failed = true }

    BattleEnd.OnClientEvent:Connect(function(data)
        if type(data) ~= "table" then return end
        local res = tostring(data.result):lower()

        -- Not the Halloween Tower = Infinite Tower: only track the floor for the auto give up
        if data.tower ~= "halloween" or data.mode ~= "infinite_room" then
            local fl = tonumber(data.floor)
            if os.clock() - lastGiveUp < 10 or LOSS[res] then
                infFloor = 1 -- run ended (our give up or a loss): the next run starts at floor 1
            elseif fl then
                infFloor = fl + 1
            end
            pcall(function() print("[PibbleHub] BattleEnd (infinite):", game:GetService("HttpService"):JSONEncode(data)) end)
            return
        end

        towerStatus.Text = ("Tower: floor %s %s"):format(tostring(data.floor), tostring(data.result))
        if not towerAuto then return end
        task.defer(hideTowerGui)

        -- loss: relaunch the same stage (stage is not modified)
        if LOSS[tostring(data.result):lower()] then
            task.delay(AUTO_DELAY, function()
                if towerAuto and gui.Parent then enterStage(stage, true) end
            end)
            return
        end

        if data.result ~= "milestone_complete" then return end -- single floor won, group continues

        -- win: stay on the SAME stage (stage is not modified), relaunch it
        task.delay(AUTO_DELAY, function()
            if towerAuto and gui.Parent then enterStage(stage, true) end
        end)
    end)

    -- ========== Candy logic ==========
    local function refresh()
        Request:FireServer()
        task.wait(1.5)
    end

    local function run()
        if busy then return end
        busy = true
        local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            status.Text = "Status: character not found"
            busy = false
            return
        end

        local back = hrp.CFrame
        local tried = {}

        local function confirm()
            for id in pairs(tried) do
                local ready = state[id]
                if ready and ready > os.time() + offset then
                    total += 1
                    tried[id] = nil
                end
            end
            count.Text = "Collected: " .. total
        end

        for attempt = 1, 3 do
            status.Text = "Status: updating (" .. attempt .. "/3)"
            refresh()
            confirm()
            nextT = nil
            local pending = 0

            for _, model in ipairs(CS:GetTagged("PickupCandy")) do
                local id = model:GetAttribute("CandyId")
                if type(id) == "string" then
                    local ready = state[id]
                    if ready and ready > os.time() + offset then
                        nextT = nextT and math.min(nextT, ready) or ready
                    else
                        local okBox, cf = pcall(function() return model:GetBoundingBox() end)
                        if okBox then
                            pending += 1
                            tried[id] = true
                            status.Text = "Collecting: " .. id
                            hrp.CFrame = CFrame.new(cf.Position + Vector3.new(0, 12, 0))
                            task.wait(0.4)
                            hrp.CFrame = CFrame.new(cf.Position)
                            task.wait(0.4)
                        end
                    end
                end
            end

            if pending == 0 then break end
        end

        refresh()
        confirm()
        for id in pairs(tried) do print("Failed:", id) end
        hrp.CFrame = back
        status.Text = auto and "Status: auto running" or "Status: done"
        busy = false
    end

    goBtn.MouseButton1Click:Connect(function() task.spawn(run) end)
    autoBtn.MouseButton1Click:Connect(function()
        auto = not auto
        autoBtn.Text = auto and "Auto: ON" or "Auto: OFF"
        autoBtn.BackgroundColor3 = auto and GREEN or RED
    end)

    task.spawn(function()
        local t = 30
        while gui.Parent do
            task.wait(1)
            t += 1
            if nextT then
                local left = math.max(0, nextT - (os.time() + offset))
                timer.Text = ("Respawn: %dm %02ds"):format(left // 60, left % 60)
            end
            if auto and not busy and t >= 30 then
                t = 0
                task.spawn(run)
            end
        end
    end)
end, debug.traceback)

if not ok then
    warn("PibbleHub error:", err)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "PibbleHub error",
            Text = tostring(err):sub(1, 150),
            Duration = 10,
        })
    end)
end
