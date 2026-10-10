local ok, err = xpcall(function()
    local Players = game:GetService("Players")
    local CS = game:GetService("CollectionService")
    local R = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
    local CandyState = R:WaitForChild("CandyState")
    local Request = R:WaitForChild("RequestCandyState")
    local StartBattle = R:WaitForChild("StartBattle")
    local BattleEnd = R:WaitForChild("BattleEnd")
    local OpenTower = R:WaitForChild("OpenHalloweenTower")
    local player = Players.LocalPlayer

    local SLOT = 2          -- updated automatically when the tower UI opens
    local MAX_FLOOR = 500
    local MAX_STAGE = 100   -- 100 groups of 5 floors
    local AUTO_DELAY = 3    -- seconds between two milestones / retries

    local state, offset, auto, busy, total, nextT = {}, 0, false, false, 0, nil
    local stage, towerAuto = 1, false

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
    main.Size = UDim2.fromOffset(250, 365)
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

    local function button(text, x, y, w, h, color)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, h)
        b.Position = UDim2.fromOffset(x, y)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = FONT
        b.TextSize = 15
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Text = text
        b.ZIndex = 5
        b.Parent = main
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

    local openBtn = button("Open Tower UI", 10, 218, 230, 26, PURPLE)

    local minusBtn = button("-", 10, 254, 36, 28, DARK)
    local floorBox = Instance.new("TextBox")
    floorBox.Size = UDim2.fromOffset(122, 28)
    floorBox.Position = UDim2.fromOffset(52, 254)
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
    local plusBtn = button("+", 180, 254, 36, 28, DARK)

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

    local startBtn = button("Start", 10, 294, 105, 28, BLUE)
    local towerAutoBtn = button("Auto: OFF", 125, 294, 115, 28, RED)
    label("Slot: auto | retries on loss", 332, Color3.fromRGB(180, 170, 200), 14)

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

    local function stopTowerAuto(msg)
        towerAuto = false
        towerAutoBtn.Text = "Auto: OFF"
        towerAutoBtn.BackgroundColor3 = RED
        if msg then towerStatus.Text = msg end
    end

    -- The server answers OpenHalloweenTower with (clearedFloor, slot, pausedRun)
    OpenTower.OnClientEvent:Connect(function(cleared, slot)
        SLOT = (slot == 2) and 2 or 1
        towerStatus.Text = ("Tower: UI open (cleared %s, slot %d)"):format(tostring(cleared or 0), SLOT)
    end)

    local function roomVisible()
        local pg = player:FindFirstChild("PlayerGui")
        local g = pg and pg:FindFirstChild("HalloweenTowerGui")
        local r = g and g:FindFirstChild("RoomFrame")
        return r and r.Visible
    end

    openBtn.MouseButton1Click:Connect(function()
        task.spawn(function()
            local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            local prompt, npcPos
            pcall(function()
                local npc = workspace.NPCs.HalloweenTower
                prompt = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt and prompt.Parent and prompt.Parent:IsA("BasePart") then
                    npcPos = prompt.Parent.Position
                else
                    npcPos = npc:GetPivot().Position
                end
            end)

            local back
            if hrp and npcPos then
                back = hrp.CFrame
                hrp.CFrame = CFrame.new(npcPos + Vector3.new(0, 3, 4))
                towerStatus.Text = "Tower: going to Calamity..."
                task.wait(0.7) -- let the server see where you are
            end

            OpenTower:FireServer()
            task.wait(1.5)

            if not roomVisible() and prompt and fireproximityprompt then
                -- fallback: use the NPC dialog, then click Accept
                fireproximityprompt(prompt)
                towerStatus.Text = "Tower: click Accept in the dialog"
                task.wait(4)
            end

            if back and hrp and hrp.Parent then hrp.CFrame = back end
        end)
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
        end
    end)

    -- Any of these results counts as a loss -> retry the SAME stage
    local LOSS = { lose = true, loss = true, lost = true, defeat = true, fail = true, failed = true }

    BattleEnd.OnClientEvent:Connect(function(data)
        if type(data) ~= "table" or data.tower ~= "halloween" or data.mode ~= "infinite_room" then return end
        towerStatus.Text = ("Tower: floor %s %s"):format(tostring(data.floor), tostring(data.result))
        if not towerAuto then return end

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
