--[[
    PibbleHub
    =====================================================================
    Layout of this file (search for the "== N." headers):
       1. Services & remotes
       2. Config & static data
       3. Shared state (one table per feature)
       4. Settings (saved to a file, restored on the next launch)
       5. Generic helpers
       6. Window & UI builders
       7. GUI automation helpers (find / press the game's buttons)
      7b. Anti-AFK
      7c. World teleport (Auto Boss: each boss NPC lives in its own world)
       8. Feature: Candy Collector
       9. Feature: Halloween Tower
      10. Feature: Auto Boss
      11. Feature: Infinite Tower (auto give up when a weather appears)
     11b. Feature: Auto Raid (4 fights at xx:00 and xx:30, 15 min window)
     11c. Feature: Auto Dungeon (left when the raid opens, restarted after the raid)
      12. BattleEnd router + restore of the saved switches
      13. Start-up + embedded icon (at the very bottom of the file)

    Every feature lives in its own do ... end block: its UI, its logic and its
    event wiring are all in one place. Features talk to each other only through
    the state tables from section 3 (Candy, Tower, Boss, Infinite, Raid).
]]

local ICON_B64 -- base64 JPEG of the toggle-button icon, assigned at the bottom of the file

local function runHub()
    -- =====================================================================
    -- == 1. SERVICES & REMOTES
    -- =====================================================================
    local Players = game:GetService("Players")
    local CS = game:GetService("CollectionService")
    local HttpService = game:GetService("HttpService")
    local R = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")

    local Remotes = {
        CandyState = R:WaitForChild("CandyState"),
        RequestCandy = R:WaitForChild("RequestCandyState"),
        StartBattle = R:WaitForChild("StartBattle"),
        BattleEnd = R:WaitForChild("BattleEnd"),
        OpenTower = R:WaitForChild("OpenHalloweenTower"),
        EndTower = R:WaitForChild("EndTowerRemote", 5),     -- "Give up"
        Teleport = R:WaitForChild("TeleportToWorld", 5),    -- :FireServer("lobby")
        SetNPCDiff = R:WaitForChild("SetNPCDifficulty", 5), -- :FireServer("hw_alucard_anderson", "impossible")
        StartNPC = R:WaitForChild("StartNPCBattle", 5),     -- :FireServer("boss_rimuru")
        StartRaid = R:WaitForChild("StartRaidBattle", 5),   -- :FireServer()  (Auto Raid)
    }
    local player = Players.LocalPlayer
    print("[PibbleHub] loading...")

    -- =====================================================================
    -- == 2. CONFIG & STATIC DATA
    -- =====================================================================
    local CFG = {
        MAX_FLOOR = 500,
        MAX_STAGE = 100,     -- 100 groups of 5 floors
        AUTO_DELAY = 3,      -- seconds between two milestones / retries
        END_ARG = 1,         -- argument sent to EndTowerRemote (as logged when clicking Give up)
        BOSS_TIMEOUT = 300,  -- seconds: if no BattleEnd arrives, the fight is considered over
        BOSS_RETRIES = 2,    -- retries of the SAME boss + difficulty after a loss, before moving on
        BOSS_MIN_FIGHT = 5,  -- seconds: a BattleEnd received sooner than this is a stale event of the previous fight
        TIMER_CHECK_DELAY = 3.5, -- seconds after StartNPCBattle during which a "cooldown" answer is looked for
        TIMER_MARGIN = 2,    -- seconds added to a detected timer before trying that boss again
        RESYNC_SECS = 300,   -- the NPC dialog (timers of every difficulty) is read once per boss, then again only after this many seconds
        DIFF_DELAY = 0.8,    -- seconds to wait after SetNPCDifficulty (raise it if a fight starts on the wrong difficulty)
        BOSS_DELAY = 1,      -- seconds between the end of a boss fight and the next one
        WIN_COOLDOWN = 600,  -- seconds a boss + difficulty stays on cooldown after a WIN (the dialog corrects it with the real timer on the next visit)
        COOLDOWN_BY_NPC = { hw_seras_integra = 300 }, -- NPCs whose cooldown is not WIN_COOLDOWN (seconds), e.g. hw_walter = 300
        UNKNOWN_COOLDOWN = 600, -- seconds a boss is put aside when the server refused it without telling the timer
        REFUSE_IF_SILENT = true, -- true: if the server sends NOTHING back after StartNPCBattle, the fight is treated as refused (cooldown)
        IGNORE_REMOTES = { CandyState = true }, -- server events that don't count as an "answer" (they fire all the time)
        TRUST_NPC_TIMER = false, -- true: also use the timer written above the NPC (it is NOT per difficulty, so it is off). The real per-difficulty timers are read from the NPC dialog
        DEBUG_TIMER = true,  -- print what the game shows / sends around each boss attempt (F9 console)
        RESTORE_DELAY = 3,   -- seconds after launch before the saved switches are restored
        POP_GIVEUP_LEFT = 60, -- Infinite Tower: a wanted weather is only given up when this many seconds (or less) are left on it
        ICON_ID = "",        -- optional: force an image, e.g. "rbxassetid://123456789" (empty = embedded icon)

        -- Auto Raid
        RAID_WORLD = "RaidWorld",   -- world id sent to TeleportToWorld
        RAID_FIGHTS = 4,            -- fights launched per raid
        RAID_INTERVAL = 30 * 60,    -- a raid slot every 30 min (xx:00 and xx:30, real clock)
        RAID_WINDOW = 15 * 60,      -- the raid can be done during the first 15 min of each slot
        RAID_TP_TIMEOUT = 25,       -- max seconds to wait for the teleport to RaidWorld to really happen (the character moves)
        RAID_LOAD_DELAY = 4,        -- extra seconds to let the raid world finish loading once we are there
        RAID_NPC_ID = "raid_soul_king_npc",        -- NPCId attribute of the raid boss (Workspace.NPCs.Yhwach)
        RAID_BOSS_NAMES = {"Yhwach", "Soul King"}, -- accepted model names / billboard texts (spaces, case and _ are ignored)
        RAID_NEAR = 1500,           -- if the raid boss is closer than this many studs, we are already in the raid world (no teleport)
        RAID_RETRY_EVERY = 60,      -- Auto: new attempt every X seconds when the raid could not start (until it really starts)
        -- RAID_BOSS_POS = Vector3.new(0, 0, 0), -- optional: uncomment and set a fixed position to stand at in the raid world (overrides the detection)
        RAID_START_TRIES = 3,       -- how many times StartRaidBattle is fired (and the game's own start button pressed) if the server does not react
        RAID_START_CHECK = 5,       -- seconds to wait for a server reaction after each try
        RAID_START_EVENTS = {"battle", "raid", "fight"}, -- a server event whose name contains one of these words = the fight was accepted
        RAID_FIGHT_DELAY = 2,       -- seconds between the end of a fight and the next one
        RAID_FIGHT_TIMEOUT = 90,    -- seconds: if no BattleEnd arrives after StartRaidBattle, go on with the next fight
        RAID_MIN_FIGHT = 2,         -- seconds: a BattleEnd received sooner than this is a stale event
        RAID_WAIT_OTHERS = 120,     -- max seconds to wait for a running boss fight / candy run before the raid starts
        RAID_SILENT_IS_COOLDOWN = true, -- true: if the boss was found but the server never reacts to StartRaidBattle, the raid is on cooldown -> this slot is skipped (no retry every minute)
        RAID_REFUSE_WORDS = {"cooldown", "cool down", "already", "limit", "come back", "try again", "not available", "no attempts", "no more", "completed"}, -- a server text with one of these after StartRaidBattle = the raid was refused
        RAID_END_EVENTS = {"end", "result", "complete", "finish", "victory", "defeat"}, -- fallback: a *raid* remote (not sync/state) whose name has one of these = the fight is over

        -- Auto Dungeon
        DUNGEON_NPC = "DungeonNPC",   -- name of the dungeon NPC model (Workspace.NPCs.DungeonNPC, prompt "Talk", "Marine Dungeon")
        DUNGEON_START_REMOTE = "",    -- optional: exact name of the remote that starts the dungeon (empty = auto-detect *dungeon* + start/enter/join)
        DUNGEON_LEAVE_REMOTE = "",    -- optional: exact name of the remote that leaves the dungeon (empty = auto-detect *dungeon* + leave/exit/quit)
        DUNGEON_ARGS = {},            -- optional: arguments sent with the start remote, e.g. {"marine_dungeon"}
        DUNGEON_LEAVE_ARGS = {},      -- optional: arguments sent with the leave remote
        DUNGEON_START_TRIES = 2,      -- how many times the start is attempted (remote, then NPC) before giving up
        DUNGEON_START_CHECK = 6,      -- seconds to wait for a server reaction / a teleport after each attempt
        DUNGEON_TIMEOUT = 0,          -- seconds: a dungeon running longer than this is left (0 = never)
        DUNGEON_COOLDOWN = 30,        -- seconds between the end of a dungeon and the next one (Tower / Boss get their turn in between)
        DUNGEON_GONE_AFTER = 20,      -- seconds without the dungeon's Exit button / dungeon events: we consider the dungeon was left (manually)
        DUNGEON_NEAR_NPC = 150,       -- studs: being this close to the DungeonNPC while a dungeon is "running" also means it was left
    }

    local FONT = Enum.Font.SourceSansBold
    local ORANGE = Color3.fromRGB(255, 160, 50)
    local BLUE = Color3.fromRGB(70, 110, 200)
    local DARK = Color3.fromRGB(80, 60, 110)
    local RED = Color3.fromRGB(110, 60, 60)
    local GREEN = Color3.fromRGB(50, 140, 80)

    -- Weathers shown in the Infinite Tower menu
    local WEATHERS = {"Typhoon", "Blizzard", "Windstorm", "Sharingan", "Singularity", "Lightning",
                      "Monarch Domain", "Void", "Made in Heaven"}

    -- Auto Boss difficulties
    local DIFFS = {"normal", "medium", "hard", "extreme", "impossible"}

    -- Every NPC of every world, in progression order (the last one of each world is its boss)
    local BOSS_WORLDS = {
        {"Namek", {"goku", "vegeta", "boss_frieza"}},
        {"Leaf Village", {"naruto", "kakashi", "boss_pain"}},
        {"Dressrosa", {"usopp", "sanji", "boss_doflamingo"}},
        {"Shibuya", {"itadori", "toji", "boss_sukuna"}},
        {"Soul Society", {"rukia", "ichigo", "boss_aizen"}},
        {"Train to Kyoto", {"power", "denji", "boss_makima"}},
        {"Isekai", {"ise_tanya_npc", "ise_smith_npc", "boss_rimuru"}},
        {"Hellsing Mansion", {"hw_walter", "hw_seras_integra", "hw_alucard_anderson"}},
    }
    -- Reward of the first clear (grows with the difficulty), shown next to each NPC
    local FIRST_CLEAR = {
        boss_aizen = 800, boss_doflamingo = 60, boss_frieza = 40, boss_makima = 1000, boss_pain = 50,
        boss_rimuru = 1200, boss_sukuna = 400, denji = 300, goku = 20, hw_alucard_anderson = 1400,
        hw_seras_integra = 400, hw_walter = 400, ichigo = 250, ise_smith_npc = 350, ise_tanya_npc = 350,
        itadori = 200, kakashi = 30, naruto = 30, power = 300, rukia = 250, sanji = 40, toji = 200,
        usopp = 40, vegeta = 20,
    }

    -- Any of these battle results counts as a loss -> retry the SAME stage
    local LOSS = { lose = true, loss = true, lost = true, defeat = true, fail = true, failed = true }

    -- =====================================================================
    -- == 3. SHARED STATE
    -- =====================================================================
    local Candy = {
        state = {},        -- candyId -> respawn timestamp (server time), pushed by the server
        offset = 0,        -- server time - local time
        auto = false,
        busy = false,      -- a collect run is in progress
        total = 0,
        nextT = nil,       -- earliest respawn timestamp
        lastRun = 0,
        runIfReady = nil,  -- set by the Candy feature
        setAuto = nil,     -- set by the Candy feature (used to restore the saved switch)
        goLobby = nil,     -- set by the Candy feature (teleports to the lobby, used by Auto Boss)
    }
    local Tower = {
        slot = 2,          -- updated automatically when the tower UI opens
        stage = 1,         -- group of 5 floors (stage 1 = floors 1-5)
        auto = false,
        startAuto = nil,   -- set by the Tower feature (used to restore the saved switch)
        resume = nil,      -- set by the Tower feature (relaunches the stage after a raid)
    }
    local Boss = {
        auto = false,
        active = false,    -- a fight started by this script is running
        waiting = false,
        run = 0,           -- id of the current fight (for the timeout)
        current = nil,     -- {id, difficulty} of the fight in progress
        lastDone = nil,    -- key "id|difficulty" of the last finished fight (the queue resumes right after it)
        retries = 0,       -- losses in a row on the current fight
        started = false,   -- true once StartNPCBattle was fired for the current fight
        startedAt = 0,     -- os.clock() when it was fired
        lastEnd = 0,       -- os.clock() of the last handled BattleEnd
        cooldown = {},     -- "id|difficulty" -> os.time() when that fight is available again (saved to the file)
        timerWait = false, -- true while waiting in the lobby for a cooldown to end
        selected = {boss_rimuru = true}, -- selected NPC ids
        diffs = {},        -- selected difficulties (none = normal)
        setAuto = nil,     -- set by the Boss feature (used to restore the saved switch)
        resume = nil,      -- set by the Boss feature (restarts the queue after a raid)
    }
    local Infinite = {
        on = false,        -- "Pop" switch
        minFloor = 1,
        floor = 1,         -- current floor of the run
        lastGiveUp = 0,
        weathers = {},     -- selected weathers, lowercase name -> true (empty = any)
        setPop = nil,      -- set by the Infinite feature (used to restore the saved switch)
    }
    local Raid = {
        auto = false,
        running = false,   -- a raid is in progress: every other automation is paused
        fightStarted = false, -- StartRaidBattle was fired and its BattleEnd is awaited
        fightDone = false, -- the BattleEnd of the current raid fight arrived
        startedAt = 0,     -- os.clock() when the current raid fight was fired
        fights = 0,        -- fights finished in the current raid
        lastSlot = nil,    -- slot number (os.time() // RAID_INTERVAL) of the last raid, one raid per slot
        setAuto = nil,     -- set by the Raid feature (used to restore the saved switch)
        onBattleEnd = nil, -- set by the Raid feature (used by the BattleEnd router)
        isOpen = nil,      -- set by the Raid feature: true while a raid is waiting to be done (Auto Raid ON, window open, not done)
    }
    local Dungeon = {
        auto = false,
        active = false,    -- a dungeon is starting / running: Tower, Boss and Candy leave the player alone
        startedAt = 0,
        lastEnd = -1e9,    -- os.clock() of the last end (the next dungeon waits DUNGEON_COOLDOWN)
        setAuto = nil,     -- set by the Dungeon feature (used to restore the saved switch)
        leave = nil,       -- set by the Dungeon feature (used by Auto Raid: leaves the dungeon when the raid opens)
        resume = nil,      -- set by the Dungeon feature (used by Auto Raid: starts the dungeon again after the raid)
        onBattleEnd = nil, -- set by the Dungeon feature (used by the BattleEnd router)
    }

    -- =====================================================================
    -- == 4. SETTINGS (saved to a file, restored on the next launch)
    -- =====================================================================
    -- Saved: selected bosses, difficulties, weathers, tower stage, min floor
    -- and the state of the Auto / Pop switches (restored a few seconds after launch,
    -- see the end of section 12).
    local Settings = {
        file = "PibbleHub_" .. tostring(player.UserId) .. ".json",
        armed = false,     -- saving only starts once the UI is built and the switches are restored
        queued = false,
        data = {},         -- what was loaded from the file
    }

    local function keysOf(t)
        local out = {}
        for k, v in pairs(t) do
            if v then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end

    -- keeps only the known values of a saved list
    local function toSet(list, valid)
        local set = {}
        if type(list) ~= "table" then return nil end
        for _, v in ipairs(list) do
            if valid[v] then set[v] = true end
        end
        return set
    end

    local function toValidSet(list)
        local s = {}
        for _, v in ipairs(list) do s[v] = true end
        return s
    end

    function Settings.load()
        local ok, data = pcall(function()
            if isfile and readfile and isfile(Settings.file) then
                return HttpService:JSONDecode(readfile(Settings.file))
            end
        end)
        Settings.data = (ok and type(data) == "table") and data or {}
    end

    -- cooldowns that are still running (expired ones are not worth saving)
    local function liveCooldowns()
        local out, now = {}, os.time()
        for k, v in pairs(Boss.cooldown) do
            if type(v) == "number" and v > now then out[k] = v end
        end
        return out
    end

    -- debounced: several changes in a row produce a single write
    function Settings.save()
        if not Settings.armed or Settings.queued then return end
        Settings.queued = true
        task.delay(0.5, function()
            Settings.queued = false
            pcall(function()
                if not writefile then return end
                writefile(Settings.file, HttpService:JSONEncode({
                    bosses = keysOf(Boss.selected),
                    diffs = keysOf(Boss.diffs),
                    weathers = keysOf(Infinite.weathers),
                    stage = Tower.stage,
                    minFloor = Infinite.minFloor,
                    autoCandy = Candy.auto,
                    autoTower = Tower.auto,
                    autoBoss = Boss.auto,
                    autoRaid = Raid.auto,
                    autoDungeon = Dungeon.auto,
                    pop = Infinite.on,
                    raidSlot = Raid.lastSlot,
                    cooldowns = liveCooldowns(),
                }))
            end)
        end)
    end

    -- apply the saved values to the state tables
    Settings.load()
    do
        local d = Settings.data
        local validBosses, validDiffs, validWeathers = {}, toValidSet(DIFFS), {}
        for _, w in ipairs(BOSS_WORLDS) do
            for _, id in ipairs(w[2]) do validBosses[id] = true end
        end
        for _, w in ipairs(WEATHERS) do validWeathers[w:lower()] = true end

        Boss.selected = toSet(d.bosses, validBosses) or Boss.selected
        Boss.diffs = toSet(d.diffs, validDiffs) or Boss.diffs
        Infinite.weathers = toSet(d.weathers, validWeathers) or Infinite.weathers
        if tonumber(d.stage) then
            Tower.stage = math.clamp(math.floor(tonumber(d.stage)), 1, CFG.MAX_STAGE)
        end
        if tonumber(d.minFloor) then
            Infinite.minFloor = math.max(1, math.floor(tonumber(d.minFloor)))
        end
        -- the raid of the slot that was already done / refused is not tried again after a relaunch
        if tonumber(d.raidSlot) then Raid.lastSlot = math.floor(tonumber(d.raidSlot)) end
        -- boss cooldowns still running (absolute times, so they stay valid after a relaunch)
        if type(d.cooldowns) == "table" then
            local now = os.time()
            for k, v in pairs(d.cooldowns) do
                if type(k) == "string" and type(v) == "number" and v > now then Boss.cooldown[k] = v end
            end
        end
    end

    -- =====================================================================
    -- == 5. GENERIC HELPERS
    -- =====================================================================
    local function clean(t) return (tostring(t):gsub("<[^>]+>", "")) end

    -- true when the object and all its parents are visible / enabled
    local function shown(o)
        local x = o
        while x and x ~= game do
            if x:IsA("LayerCollector") then -- ScreenGui, BillboardGui, SurfaceGui
                if not x.Enabled then return false end
            elseif x:IsA("GuiObject") then
                if not x.Visible then return false end
            end
            x = x.Parent
        end
        return true
    end

    -- "boss_rimuru" -> "Rimuru", "hw_seras_integra" -> "Seras Integra"
    local function niceName(id)
        local n = id:gsub("^boss_", ""):gsub("^hw_", ""):gsub("_npc$", ""):gsub("_", " ")
        return (n:gsub("(%a)([%w]*)", function(f, r) return f:upper() .. r end))
    end

    local function getHRP()
        return player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    end

    local function logEnd(tag, data)
        pcall(function()
            print("[PibbleHub] BattleEnd (" .. tag .. "):", HttpService:JSONEncode(data))
        end)
    end

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

    -- =====================================================================
    -- == 6. WINDOW & UI BUILDERS
    -- =====================================================================
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
    for _, n in ipairs({"PibbleHub", "HalloweenUI"}) do
        local old = guiParent:FindFirstChild(n)
        if old then old:Destroy() end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "PibbleHub"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = guiParent

    local win = Instance.new("Frame")
    win.Size = UDim2.fromOffset(250, 770)
    win.Position = UDim2.new(0, 30, 0.3, 0)
    win.BackgroundColor3 = Color3.fromRGB(26, 14, 38)
    win.BorderSizePixel = 0
    win.Active = true
    win.Draggable = true
    win.ZIndex = 1
    win.Parent = gui
    Instance.new("UICorner", win)

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
        l.Parent = win
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
        b.Parent = parentFrame or win
        Instance.new("UICorner", b)
        return b
    end

    local function textbox(placeholder, x, y, w, h, text, size)
        local t = Instance.new("TextBox")
        t.Size = UDim2.fromOffset(w, h)
        t.Position = UDim2.fromOffset(x, y)
        t.BackgroundColor3 = Color3.fromRGB(45, 30, 65)
        t.BorderSizePixel = 0
        t.Font = FONT
        t.TextSize = size or 16
        t.TextColor3 = Color3.new(1, 1, 1)
        t.PlaceholderText = placeholder
        t.PlaceholderColor3 = Color3.fromRGB(150, 140, 170)
        t.ClearTextOnFocus = true
        t.Text = text or ""
        t.ZIndex = 5
        t.Parent = win
        Instance.new("UICorner", t)
        return t
    end

    -- Dropdown panel that opens to the right of the window
    local function sidePanel(className, w, h, y)
        local f = Instance.new(className)
        f.Size = UDim2.fromOffset(w, h)
        f.Position = UDim2.fromOffset(258, y)
        f.BackgroundColor3 = Color3.fromRGB(36, 22, 52)
        f.BorderSizePixel = 0
        f.Visible = false
        f.ZIndex = 20
        f.Parent = win
        Instance.new("UICorner", f)
        return f
    end

    label("PibbleHub", 5, ORANGE, 20)

    -- Open / collapse button (square, rounded corners): the embedded icon, or a "P"
    do
        local iconId = CFG.ICON_ID
        if iconId == "" and ICON_B64 and #ICON_B64 > 100 then
            pcall(function()
                if writefile and getcustomasset then
                    writefile("pibblehub_icon.jpg", b64decode(ICON_B64))
                    iconId = getcustomasset("pibblehub_icon.jpg")
                end
            end)
        end

        local toggle
        if iconId ~= "" then
            toggle = Instance.new("ImageButton")
            toggle.Image = iconId
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
        Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 12)
        local stroke = Instance.new("UIStroke", toggle)
        stroke.Color = ORANGE
        stroke.Thickness = 2
        toggle.MouseButton1Click:Connect(function()
            win.Visible = not win.Visible
        end)
    end

    -- =====================================================================
    -- == 7. GUI AUTOMATION HELPERS (find / press the game's own buttons)
    -- =====================================================================
    local function btnText(o)
        if o:IsA("TextButton") or o:IsA("TextLabel") then return clean(o.Text):lower() end
        return ""
    end

    -- First visible button whose text matches pred (a hidden one is used as a fallback)
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

    -- Fires the button's real click handlers
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

    -- Some games ask "are you sure?": press Yes / Confirm if it appears
    local function confirmDialog()
        local b = findButton(function(t)
            return t == "yes" or t == "confirm" or t == "give up!" or t:find("^yes[%s%p]") ~= nil
        end)
        if b and shown(b) then activateButton(b) end
    end

    -- =====================================================================
    -- == 7b. ANTI-AFK
    -- =====================================================================
    -- Roblox fires Players.LocalPlayer.Idled after ~20 min without input:
    -- we answer with a virtual click so the player is never kicked for being idle.
    do
        local VirtualUser = game:GetService("VirtualUser")
        pcall(function()
            local genv = (getgenv and getgenv()) or _G
            -- if the script is launched again, drop the previous connection (no stacking)
            if genv.PibbleAFK then genv.PibbleAFK:Disconnect() end
            genv.PibbleAFK = player.Idled:Connect(function()
                pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new())
                end)
            end)
        end)
    end

    -- =====================================================================
    -- == 7c. WORLD TELEPORT (Auto Boss: every boss NPC lives in its own world)
    -- =====================================================================
    local Worlds = {}
    do
        local function norm(s) return (tostring(s):lower():gsub("[^%w]+", "")) end

        local function textOf(x)
            if x:IsA("TextButton") then return clean(x.Text) end
            for _, c in ipairs(x:GetDescendants()) do
                if c:IsA("TextLabel") then return clean(c.Text) end
            end
            return ""
        end

        -- The world list has one "World_<id>" card per world (a title + an "Enter" button).
        -- The card is found by its id ("World_namek") or by its title ("Namek"); returns card, id.
        local function findCard(name)
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            local want = norm(name)
            for _, d in ipairs(pg:GetDescendants()) do
                if not d:IsDescendantOf(gui) and d.Name:sub(1, 6) == "World_" then
                    local id = d.Name:sub(7)
                    if norm(id) == want then return d, id end
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel") then
                            local n = norm(c.Text)
                            if n == want or (#want >= 4 and n:find(want, 1, true)) then return d, id end
                        end
                    end
                end
            end
            return nil
        end

        local function enterButton(card)
            local hidden
            for _, x in ipairs(card:GetDescendants()) do
                if (x:IsA("TextButton") or x:IsA("ImageButton")) and textOf(x):lower():find("enter", 1, true) then
                    if shown(x) then return x end
                    hidden = hidden or x
                end
            end
            return hidden
        end

        -- Teleports to a world by its name ("Leaf Village", "Namek"...): presses the Enter button of its card
        -- (opening the worlds menu first if needed), or fires TeleportToWorld with the id read from the card.
        -- useRemote = true tries the remote first. Returns the method used (nil if nothing worked).
        function Worlds.go(name, useRemote)
            local card, id = findCard(name)
            if not card then
                local m = findButton(function(t)
                    return t:find("teleport", 1, true) ~= nil or t == "world" or t == "worlds"
                end)
                if m and activateButton(m) then
                    task.wait(0.35)
                    card, id = findCard(name)
                end
            end
            print("[PibbleHub] world teleport:", name, "| card =", card and card:GetFullName() or "not found")
            local guess = id or (name:lower():gsub("%s+", "_"))
            if useRemote and Remotes.Teleport then
                Remotes.Teleport:FireServer(guess)
                return "remote"
            end
            local b = card and enterButton(card)
            if b and activateButton(b) then
                task.wait(0.35)
                confirmDialog()
                return "button"
            end
            if Remotes.Teleport then
                Remotes.Teleport:FireServer(guess)
                return "remote"
            end
            return nil
        end
    end

    -- =====================================================================
    -- == 8. FEATURE: CANDY COLLECTOR
    -- =====================================================================
    do
        label("Candy Collector", 30, ORANGE)
        local statusL = label("Status: idle", 50)
        local timerL = label("Respawn: -", 70)
        local countL = label("Collected: 0", 90)
        local goBtn = button("Collect now", 10, 114, 105, 26, BLUE)
        local autoBtn = button("Auto: OFF", 125, 114, 115, 26, RED)

        local lastLobbyTp, tpAttempt = 0, 0

        Remotes.CandyState.OnClientEvent:Connect(function(t, now)
            if type(now) == "number" then Candy.offset = now - os.time() end
            Candy.state = type(t) == "table" and t or {}
        end)

        local function serverNow() return os.time() + Candy.offset end

        local function refresh()
            Remotes.RequestCandy:FireServer()
            task.wait(1.5)
        end

        -- Candies only exist in the lobby: if none are loaded around us, we are somewhere else
        local function inLobby()
            return #CS:GetTagged("PickupCandy") > 0
        end

        -- Candies respawn on a timer (10 min): ready when the earliest respawn time has passed
        local function candiesReady()
            if os.clock() - Candy.lastRun < 15 then return false end
            if Candy.nextT == nil then return true end
            return serverNow() >= Candy.nextT
        end

        -- ---- lobby teleport ----
        local function labelOf(x)
            if x:IsA("TextButton") then return clean(x.Text):lower() end
            for _, c in ipairs(x:GetDescendants()) do
                if c:IsA("TextLabel") then return clean(c.Text):lower() end
            end
            return ""
        end

        -- The world list shows one card per world: a "Lobby" title and an "Enter" button.
        local function findLobbyEnter()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            -- the game's world list: PlayerGui.WorldsGui.WorldsFrame.WorldList.World_lobby
            local card = pg:FindFirstChild("World_lobby", true)
            if card then
                local hidden
                for _, x in ipairs(card:GetDescendants()) do
                    if x:IsA("TextButton") or x:IsA("ImageButton") then
                        if labelOf(x):find("enter", 1, true) then
                            if shown(x) then return x end
                            hidden = hidden or x
                        end
                    end
                end
                if hidden then return hidden end
            end
            -- fallback: the smallest container holding a "Lobby" title and an "Enter" button
            for _, d in ipairs(pg:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and not d:IsDescendantOf(gui)
                    and clean(d.Text):lower():match("^%s*lobby%s*$") then
                    local a = d.Parent
                    while a and not a:IsA("ScreenGui") do
                        local hidden
                        for _, x in ipairs(a:GetDescendants()) do
                            if (x:IsA("TextButton") or x:IsA("ImageButton")) and x ~= d
                                and labelOf(x):find("enter", 1, true) then
                                if shown(x) then return x end
                                hidden = hidden or x
                            end
                        end
                        if hidden then return hidden end
                        a = a.Parent
                    end
                end
            end
            return nil
        end

        -- Presses the Enter button of the Lobby card (opening the worlds menu first if needed) and confirms
        -- any popup. Every second attempt fires the TeleportToWorld remote instead. Returns the method used.
        local function teleportLobby()
            tpAttempt += 1
            if tpAttempt % 2 == 0 and Remotes.Teleport then
                print("[PibbleHub] lobby teleport: remote TeleportToWorld('lobby')")
                Remotes.Teleport:FireServer("lobby")
                return "remote"
            end
            local b = findLobbyEnter()
            if not b then
                -- open the menu that lists the worlds, then look again
                local m = findButton(function(t)
                    return t:find("teleport", 1, true) ~= nil or t == "world" or t == "worlds" or t == "lobby"
                end)
                if m and activateButton(m) then
                    task.wait(0.6)
                    b = findLobbyEnter()
                end
            end
            print("[PibbleHub] lobby teleport: Enter button =", b and b:GetFullName() or "not found")
            if b and activateButton(b) then
                task.wait(0.6)
                confirmDialog()
                return "button"
            end
            if Remotes.Teleport then
                Remotes.Teleport:FireServer("lobby")
                return "remote"
            end
            return nil
        end

        -- Makes sure we are in the lobby. Never pulls the player out of a running Auto Tower / Auto Boss / Raid.
        local function goLobby()
            if Raid.running then
                statusL.Text = "Status: raid running"
                return false
            end
            if inLobby() then return true end
            if Tower.auto or Boss.active or Dungeon.active then
                statusL.Text = "Status: not in lobby (tower/boss/dungeon running)"
                return false
            end
            if os.clock() - lastLobbyTp > 15 then
                lastLobbyTp = os.clock()
                statusL.Text = "Status: teleporting to lobby"
                local method = teleportLobby()
                if not method then
                    statusL.Text = "Status: no lobby button found"
                    return false
                end
                statusL.Text = "Status: teleporting (" .. method .. ")"
            end
            -- wait for the lobby (and its candies) to load
            for _ = 1, 20 do
                if inLobby() then
                    for _ = 1, 10 do
                        if getHRP() then break end
                        task.wait(0.5)
                    end
                    task.wait(1)
                    return true
                end
                task.wait(0.5)
            end
            statusL.Text = "Status: lobby not reached"
            return false
        end

        Candy.goLobby = goLobby

        -- ---- collect run ----
        local function run()
            if Candy.busy or Raid.running then return end
            Candy.busy = true
            Candy.lastRun = os.clock()

            -- candies only exist in the lobby: a running dungeon is left first (AFK OFF, Exit -> SAVE & LEAVE),
            -- and started again once the candies are collected (Auto Dungeon ON)
            local leftDungeon = false
            if Dungeon.active and Dungeon.leave then
                statusL.Text = "Status: leaving dungeon"
                if Dungeon.afkOff then pcall(Dungeon.afkOff) end
                Dungeon.leave({ why = "candy" })
                leftDungeon = true
                task.wait(1)
            end
            local function backToDungeon()
                if leftDungeon and Dungeon.auto and Dungeon.resume then Dungeon.resume() end
            end

            if not goLobby() then
                backToDungeon()
                Candy.busy = false
                return
            end
            local hrp = getHRP()
            if not hrp then
                statusL.Text = "Status: character not found"
                backToDungeon()
                Candy.busy = false
                return
            end

            local back = hrp.CFrame
            local tried = {}

            local function confirm()
                for id in pairs(tried) do
                    local ready = Candy.state[id]
                    if ready and ready > serverNow() then
                        Candy.total += 1
                        tried[id] = nil
                    end
                end
                countL.Text = "Collected: " .. Candy.total
            end

            for attempt = 1, 3 do
                statusL.Text = "Status: updating (" .. attempt .. "/3)"
                refresh()
                confirm()
                Candy.nextT = nil
                local pending = 0

                for _, model in ipairs(CS:GetTagged("PickupCandy")) do
                    local id = model:GetAttribute("CandyId")
                    if type(id) == "string" then
                        local ready = Candy.state[id]
                        if ready and ready > serverNow() then
                            Candy.nextT = Candy.nextT and math.min(Candy.nextT, ready) or ready
                        else
                            local okBox, cf = pcall(function() return model:GetBoundingBox() end)
                            if okBox then
                                pending += 1
                                tried[id] = true
                                statusL.Text = "Collecting: " .. id
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
            statusL.Text = Candy.auto and "Status: auto running" or "Status: done"
            backToDungeon()
            Candy.busy = false
        end

        -- Used by Auto Boss between two fights: collect the candies right away if their timer is up
        Candy.runIfReady = function()
            if Candy.auto and not Candy.busy and not Raid.running and candiesReady() then run() end
        end

        local function setAuto(on)
            Candy.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Candy.setAuto = setAuto

        goBtn.MouseButton1Click:Connect(function() task.spawn(run) end)
        autoBtn.MouseButton1Click:Connect(function() setAuto(not Candy.auto) end)

        -- every second: respawn timer + auto collect
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                if Candy.nextT then
                    local left = math.max(0, Candy.nextT - serverNow())
                    timerL.Text = ("Respawn: %dm %02ds"):format(left // 60, left % 60)
                end
                -- never interrupt a boss fight or a raid: they go first, the candies are collected right after
                if Candy.auto and not Candy.busy and not Boss.active and not Raid.running then
                    if candiesReady() then
                        task.spawn(run)
                    elseif not inLobby() and not Boss.auto and not Tower.auto and not Dungeon.auto then
                        task.spawn(run) -- Candy is ON and nothing else is running: stay in the lobby
                    end
                end
            end
        end)
    end

    -- =====================================================================
    -- == 9. FEATURE: HALLOWEEN TOWER
    -- =====================================================================
    do
        label("Halloween Tower", 152, ORANGE)
        local floorLbl = label("Floors 1-5", 172)
        local statusL = label("Tower: idle", 192)
        local minusBtn = button("-", 10, 218, 36, 28, DARK)
        local floorBox = textbox("Floor (1-500)", 52, 218, 122, 28, "1", 16)
        local plusBtn = button("+", 180, 218, 36, 28, DARK)
        local startBtn = button("Start", 10, 258, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 258, 115, 28, RED)

        local hiddenObjs = {}
        local panel, lastScan = nil, 0

        -- ---- floor selection ----
        local function firstFloor(s) return (s - 1) * 5 + 1 end

        local function setStage(s)
            Tower.stage = math.clamp(math.floor(s), 1, CFG.MAX_STAGE)
            local a = firstFloor(Tower.stage)
            floorBox.Text = tostring(a)
            floorLbl.Text = ("Floors %d-%d"):format(a, a + 4)
            Settings.save()
        end

        local function readBox()
            local n = tonumber(floorBox.Text)
            if n then setStage(math.ceil(math.clamp(math.floor(n), 1, CFG.MAX_FLOOR) / 5)) end
        end

        -- ---- start a group of 5 floors ----
        local function fireBind(name, ...)
            local pg = player:FindFirstChild("PlayerGui")
            local b = pg and pg:FindFirstChild(name)
            if b and b:IsA("BindableEvent") then b:Fire(...) end
        end

        local function enterStage(s, isAuto)
            local m = firstFloor(s)
            local suffix = Tower.slot == 2 and "2" or ""
            -- same calls the game's own Enter button makes
            fireBind("ResetBattleFloor" .. suffix, m, "infinite_room")
            fireBind("StartInfiniteRoomBattle" .. suffix, m, "halloween", isAuto or nil)
            Remotes.StartBattle:FireServer("infinite_room", {
                tower = "halloween",
                milestone = m,
                slot = Tower.slot,
            })
            statusL.Text = ("Tower: started %d-%d"):format(m, m + 4)
        end

        local function relaunch()
            task.delay(CFG.AUTO_DELAY, function()
                -- during a raid / dungeon the tower is paused: Raid / Dungeon call Tower.resume when it is over
                if Tower.auto and gui.Parent and not Raid.running and not Dungeon.active then enterStage(Tower.stage, true) end
            end)
        end

        -- ---- hide the game's tower UI while auto runs, so it doesn't pop up again ----
        local function hideObj(o)
            if o:IsA("ScreenGui") then
                if o.Enabled then o.Enabled = false; hiddenObjs[o] = true end
            elseif o:IsA("GuiObject") then
                if o.Visible then o.Visible = false; hiddenObjs[o] = true end
            end
        end

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
                if not (panel and panel.Parent) and os.clock() - lastScan > 1 then
                    lastScan = os.clock()
                    panel = findTowerPanel(pg)
                end
                if panel and panel.Parent then hideObj(panel) end
            end)
        end

        local function restoreTowerGui()
            for o in pairs(hiddenObjs) do
                if o.Parent then
                    pcall(function()
                        if o:IsA("ScreenGui") then o.Enabled = true else o.Visible = true end
                    end)
                end
                hiddenObjs[o] = nil
            end
        end

        local function stopAuto(msg)
            Tower.auto = false
            restoreTowerGui()
            autoBtn.Text = "Auto: OFF"
            autoBtn.BackgroundColor3 = RED
            if msg then statusL.Text = msg end
            Settings.save()
        end

        local function startAuto()
            readBox()
            Tower.auto = true
            autoBtn.Text = "Auto: ON"
            autoBtn.BackgroundColor3 = GREEN
            enterStage(Tower.stage, true)
            Settings.save()
            -- keep the tower UI hidden while auto runs
            task.spawn(function()
                while Tower.auto and gui.Parent do
                    hideTowerGui()
                    task.wait(0.25)
                end
            end)
        end
        Tower.startAuto = startAuto

        -- called by Auto Raid once the raid is over: relaunches the current stage
        Tower.resume = function()
            if Tower.auto and gui.Parent then enterStage(Tower.stage, true) end
        end

        -- ---- wiring ----
        minusBtn.MouseButton1Click:Connect(function() setStage(Tower.stage - 1) end)
        plusBtn.MouseButton1Click:Connect(function() setStage(Tower.stage + 1) end)
        floorBox.FocusLost:Connect(function()
            local n = tonumber(floorBox.Text)
            if n then readBox() else setStage(Tower.stage) end
        end)

        startBtn.MouseButton1Click:Connect(function()
            readBox()
            enterStage(Tower.stage, false)
        end)

        autoBtn.MouseButton1Click:Connect(function()
            if Tower.auto then
                stopAuto("Tower: auto stopped")
            else
                startAuto()
            end
        end)

        -- The server answers OpenHalloweenTower with (clearedFloor, slot, pausedRun):
        -- keeps Tower.slot up to date when the game opens the tower UI
        Remotes.OpenTower.OnClientEvent:Connect(function(cleared, slot)
            Tower.slot = (slot == 2) and 2 or 1
            statusL.Text = ("Tower: UI open (cleared %s, slot %d)"):format(tostring(cleared or 0), Tower.slot)
            if Tower.auto then task.defer(hideTowerGui) end
        end)

        -- called by the BattleEnd router for Halloween Tower results
        Tower.onBattleEnd = function(data)
            statusL.Text = ("Tower: floor %s %s"):format(tostring(data.floor), tostring(data.result))
            if not Tower.auto then return end
            task.defer(hideTowerGui)
            -- loss: relaunch the same stage. milestone_complete: win, relaunch the same stage.
            -- (any other result = a single floor won, the group continues)
            if LOSS[tostring(data.result):lower()] or data.result == "milestone_complete" then
                relaunch()
            end
        end

        setStage(Tower.stage)
    end

    -- =====================================================================
    -- == 10. FEATURE: AUTO BOSS
    -- =====================================================================
    do
        label("Auto Boss", 298, ORANGE)
        local statusL = label("Boss: idle", 318)
        local pickBtn = button("Boss: -", 10, 342, 230, 28, DARK)
        local diffBtn = button("Difficulty: Normal", 10, 376, 230, 28, DARK)
        local startBtn = button("Start", 10, 410, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 410, 115, 28, RED)

        -- ---- boss menu (multi-select, stays open) ----
        local bossMenu = sidePanel("ScrollingFrame", 270, 380, 298)
        bossMenu.ScrollBarThickness = 6

        local bossBtns, bossLabels, y = {}, {}, 6

        local function refreshBossPick()
            local n, last = 0, nil
            for id, btn in pairs(bossBtns) do
                local on = Boss.selected[id] == true
                if on then n += 1; last = id end
                btn.BackgroundColor3 = on and GREEN or DARK
                btn.Text = (on and "[x] " or "[  ] ") .. bossLabels[id]
            end
            if n == 0 then
                pickBtn.Text = "Boss: none selected"
            elseif n == 1 then
                pickBtn.Text = "Boss: " .. niceName(last)
            else
                pickBtn.Text = ("Boss: %d selected"):format(n)
            end
        end

        for _, w in ipairs(BOSS_WORLDS) do
            local h = Instance.new("TextLabel")
            h.Size = UDim2.fromOffset(250, 22)
            h.Position = UDim2.fromOffset(10, y)
            h.BackgroundTransparency = 1
            h.Font = FONT
            h.TextSize = 16
            h.TextColor3 = ORANGE
            h.TextXAlignment = Enum.TextXAlignment.Left
            h.Text = w[1]
            h.ZIndex = 21
            h.Parent = bossMenu
            y += 25
            for i, id in ipairs(w[2]) do
                local txt = ("%s%s   %d/%d   (%s)"):format(niceName(id), i == #w[2] and " [BOSS]" or "",
                    i, #w[2], tostring(FIRST_CLEAR[id] or "?"))
                local btn = button(txt, 8, y, 254, 26, DARK, bossMenu, 21)
                btn.TextSize = 14
                btn.TextXAlignment = Enum.TextXAlignment.Left
                bossBtns[id] = btn
                bossLabels[id] = txt
                btn.MouseButton1Click:Connect(function()
                    if Boss.selected[id] then Boss.selected[id] = nil else Boss.selected[id] = true end
                    refreshBossPick() -- the menu stays open so several bosses can be picked
                    Settings.save()
                end)
                y += 29
            end
        end
        bossMenu.CanvasSize = UDim2.fromOffset(0, y + 6)
        refreshBossPick()

        -- ---- difficulty menu (multi-select) ----
        local diffMenu = sidePanel("Frame", 190, (#DIFFS + 1) * 32 + 4, 330)
        local diffAllBtn = button("All difficulties", 8, 4, 174, 28, DARK, diffMenu, 21)
        local diffBtns = {}
        for i, d in ipairs(DIFFS) do
            diffBtns[d] = button(d, 8, 4 + i * 32, 174, 28, DARK, diffMenu, 21)
        end

        local function refreshDiffPick()
            local n, last = 0, nil
            for _, d in ipairs(DIFFS) do
                local on = Boss.diffs[d] == true
                if on then n += 1; last = d end
                diffBtns[d].BackgroundColor3 = on and GREEN or DARK
                diffBtns[d].Text = (on and "[x] " or "[  ] ") .. niceName(d)
            end
            diffAllBtn.BackgroundColor3 = (n == #DIFFS) and GREEN or DARK
            if n == 0 then
                diffBtn.Text = "Difficulty: Normal"
            elseif n == 1 then
                diffBtn.Text = "Difficulty: " .. niceName(last)
            elseif n == #DIFFS then
                diffBtn.Text = "Difficulty: All (rotating)"
            else
                diffBtn.Text = ("Difficulty: %d selected"):format(n)
            end
        end

        for _, d in ipairs(DIFFS) do
            diffBtns[d].MouseButton1Click:Connect(function()
                if Boss.diffs[d] then Boss.diffs[d] = nil else Boss.diffs[d] = true end
                refreshDiffPick()
                Settings.save()
            end)
        end
        diffAllBtn.MouseButton1Click:Connect(function()
            local all = true
            for _, d in ipairs(DIFFS) do
                if not Boss.diffs[d] then all = false end
            end
            Boss.diffs = {}
            if not all then
                for _, d in ipairs(DIFFS) do Boss.diffs[d] = true end
            end
            refreshDiffPick()
            Settings.save()
        end)
        refreshDiffPick()

        -- only one menu open at a time
        pickBtn.MouseButton1Click:Connect(function()
            bossMenu.Visible = not bossMenu.Visible
            if bossMenu.Visible then diffMenu.Visible = false end
        end)
        diffBtn.MouseButton1Click:Connect(function()
            diffMenu.Visible = not diffMenu.Visible
            if diffMenu.Visible then bossMenu.Visible = false end
        end)

        -- ---- fight queue ----
        -- For each selected boss (progression order), every selected difficulty (none = normal).
        -- peekFight returns the next {boss, difficulty} WITHOUT advancing: the queue only moves on
        -- (advance) when a fight is really over, so a fight that never started doesn't "consume" its slot.
        local function fightList()
            local diffs = {}
            for _, d in ipairs(DIFFS) do
                if Boss.diffs[d] then diffs[#diffs + 1] = d end
            end
            if #diffs == 0 then diffs = {"normal"} end
            local list = {}
            for _, w in ipairs(BOSS_WORLDS) do
                for _, id in ipairs(w[2]) do
                    if Boss.selected[id] then
                        for _, d in ipairs(diffs) do list[#list + 1] = {id, d} end
                    end
                end
            end
            return list
        end

        local function keyOf(f) return f[1] .. "|" .. f[2] end

        local function onCooldown(f)
            local r = Boss.cooldown[keyOf(f)]
            return r ~= nil and r > os.time()
        end

        -- how long a boss stays on cooldown after a win
        local function winCooldown(id)
            return CFG.COOLDOWN_BY_NPC[id] or CFG.WIN_COOLDOWN
        end

        -- next fight to run, skipping the ones that are on a cooldown timer (nil = nothing available now)
        local function peekFight()
            local list = fightList()
            if #list == 0 then return nil end
            -- a lost fight is retried: same boss, same difficulty
            if Boss.current and Boss.retries > 0 then
                for _, f in ipairs(list) do
                    if keyOf(f) == keyOf(Boss.current) and not onCooldown(f) then return f end
                end
            end
            -- otherwise: the first available fight after the last finished one
            -- (still correct if the selection was changed in the meantime)
            local idx = 0
            if Boss.lastDone then
                for i, f in ipairs(list) do
                    if keyOf(f) == Boss.lastDone then idx = i end
                end
            end
            for step = 1, #list do
                local f = list[(idx + step - 1) % #list + 1]
                if not onCooldown(f) then return f end
            end
            return nil
        end

        -- marks the current fight as finished: the queue resumes right after it
        local function advance()
            if Boss.current then Boss.lastDone = keyOf(Boss.current) end
            Boss.retries = 0
        end

        -- ---- NPC lookup & teleport ----
        -- Finds the NPC model in the workspace (by model name or by attribute)
        local npcCache = {} -- id -> model (a full workspace scan is slow, so a found NPC is remembered)
        local function findNPC(id)
            local c = npcCache[id]
            if c and c.Parent and c:IsDescendantOf(workspace) then return c end
            npcCache[id] = nil
            local want, wantNice = id:lower(), niceName(id):lower()
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("Model") and not Players:GetPlayerFromCharacter(d) then
                    local n = d.Name:lower()
                    local a = d:GetAttribute("NPCId") or d:GetAttribute("NpcId") or d:GetAttribute("npcId")
                        or d:GetAttribute("Id") or d:GetAttribute("id")
                    if n == want or n == wantNice or (a and tostring(a):lower() == want) then
                        npcCache[id] = d
                        return d
                    end
                end
            end
        end

        -- Teleports in front of the NPC (retries for ~5 s in case it is streamed in)
        local function tpToNPC(id)
            for _ = 1, 25 do
                local hrp = getHRP()
                local m = findNPC(id)
                if hrp and m then
                    local okP, pivot = pcall(function() return m:GetPivot() end)
                    if okP then
                        hrp.CFrame = CFrame.new(pivot.Position + pivot.LookVector * 5 + Vector3.new(0, 2, 0))
                        return true
                    end
                end
                task.wait(0.2)
            end
            print("[PibbleHub] NPC not found in workspace:", id)
            return false
        end

        -- ---- cooldown timers ----
        -- A boss that was cleared recently shows a timer. It is looked for in two places:
        --   1) on the NPC itself (billboard / surface text), right after teleporting to it
        --   2) in a popup, a few seconds after StartNPCBattle was fired
        local UNITS = {
            h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
            m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
            s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
        }
        local TIMER_WORDS = {"cooldown", "cool down", "available in", "ready in", "try again", "come back", "again in"}

        local function hasWord(t)
            for _, w in ipairs(TIMER_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- "4:32", "1:02:10", "5m 30s", "2 hours" ... -> seconds (nil when the text holds no time)
        local function parseTime(text)
            local h, m, s = text:match("(%d+):(%d+):(%d+)")
            if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
            m, s = text:match("(%d+):(%d+)")
            if m then return tonumber(m) * 60 + tonumber(s) end
            local total, found = 0, false
            for n, u in text:gmatch("(%d+)%s*(%a+)") do
                local mult = UNITS[u]
                if mult then
                    total += tonumber(n) * mult
                    found = true
                end
            end
            return found and total or nil
        end

        local function isText(o) return o:IsA("TextLabel") or o:IsA("TextButton") end

        -- timer written on the NPC (any visible text under the model that reads as a time)
        local function npcTimer(model)
            if not model then return nil end
            for _, d in ipairs(model:GetDescendants()) do
                if isText(d) and shown(d) then
                    local t = clean(d.Text):lower()
                    if t ~= "" then
                        local secs = parseTime(t) or (hasWord(t) and tonumber(t:match("(%d+)")))
                        if secs and secs > 0 then return secs end
                    end
                end
            end
            return nil
        end

        -- timer in a popup: a visible text with a "cooldown"-like word and a time
        -- (the time may be in a sibling label: "Cooldown:" + "4:32")
        local function popupTimer()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            for _, d in ipairs(pg:GetDescendants()) do
                if isText(d) and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text):lower()
                    if t ~= "" and hasWord(t) then
                        local secs = parseTime(t) or tonumber(t:match("(%d+)"))
                        if not secs and d.Parent then
                            for _, sib in ipairs(d.Parent:GetChildren()) do
                                if sib ~= d and isText(sib) then
                                    secs = parseTime(clean(sib.Text):lower())
                                    if secs then break end
                                end
                            end
                        end
                        if secs and secs > 0 then return secs end
                    end
                end
            end
            return nil
        end

        -- debug: prints every visible text found on the NPC, to see what the game shows there
        local function dumpTexts(id)
            if not CFG.DEBUG_TIMER then return end
            local m = findNPC(id)
            if not m then return end
            local out = {}
            for _, d in ipairs(m:GetDescendants()) do
                if isText(d) and shown(d) then
                    local t = clean(d.Text)
                    if t ~= "" then out[#out + 1] = d.Name .. "=" .. t end
                end
            end
            print("[PibbleHub] texts on " .. id .. ": " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
        end

        -- ---- what the server answers to StartNPCBattle ----
        -- Every RemoteEvent the server fires at us is recorded. A refused fight (cooldown) comes back as a
        -- text with the time, or as nothing at all; an accepted fight triggers battle events.
        local Notice = { list = {} } -- {t = os.clock(), name = remote name, text = lowercase text}

        local function collectTexts(v, out, depth)
            if type(v) == "string" then
                out[#out + 1] = v
            elseif type(v) == "table" and depth < 3 then
                for _, x in pairs(v) do collectTexts(x, out, depth + 1) end
            end
        end

        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and not CFG.IGNORE_REMOTES[r.Name] then
                r.OnClientEvent:Connect(function(...)
                    local args, texts = table.pack(...), {}
                    for i = 1, args.n do collectTexts(args[i], texts, 0) end
                    local text = clean(table.concat(texts, " ")):lower()
                    local list = Notice.list
                    list[#list + 1] = { t = os.clock(), name = r.Name, text = text }
                    if #list > 60 then table.remove(list, 1) end
                    if CFG.DEBUG_TIMER and Boss.started and os.clock() - Boss.startedAt < 15 then
                        print("[PibbleHub] server event after StartNPCBattle:", r.Name, text)
                    end
                end)
            end
        end

        -- how many server events arrived since `since`
        local function noticeCount(since)
            local n = 0
            for _, e in ipairs(Notice.list) do
                if e.t >= since then n += 1 end
            end
            return n
        end

        -- a server message about a cooldown, with its time (seconds)
        local function noticeTimer(since)
            for _, e in ipairs(Notice.list) do
                if e.t >= since and e.text ~= ""
                    and (hasWord(e.text) or e.text:find("wait", 1, true) or e.text:find("cool", 1, true)) then
                    local secs = parseTime(e.text)
                    if secs and secs > 0 then return secs end
                end
            end
            return nil
        end

        -- debug: visible texts of the interface that read as a time (to locate where the game shows timers)
        local function dumpGuiTimers()
            if not CFG.DEBUG_TIMER then return end
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return end
            local out = {}
            for _, d in ipairs(pg:GetDescendants()) do
                if #out >= 12 then break end
                if isText(d) and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text)
                    if t ~= "" and parseTime(t:lower()) then out[#out + 1] = d.Name .. "=" .. t end
                end
            end
            print("[PibbleHub] visible timers in the interface: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
        end

        -- Was the fight refused? Looks at server messages, popups and the NPC billboard.
        -- Returns seconds, guessed(bool). A cooldown message without a readable time = UNKNOWN_COOLDOWN.
        local function refusedTimer(id, since)
            local secs = noticeTimer(since) or popupTimer()
            if not secs and CFG.TRUST_NPC_TIMER then secs = npcTimer(findNPC(id)) end
            if secs then return secs, false end
            for _, e in ipairs(Notice.list) do
                if e.t >= since and e.text ~= ""
                    and (hasWord(e.text) or e.text:find("wait", 1, true) or e.text:find("cool", 1, true)) then
                    return CFG.UNKNOWN_COOLDOWN, true
                end
            end
            return nil
        end

        -- ---- per-difficulty timers, read from the NPC dialog ----
        -- Talking to the NPC opens a dialog with one button per difficulty. A difficulty on cooldown shows
        -- its own timer instead of its name ("9m 47s" | Medium | Hard | Extreme | Impossible | ?).
        -- The script "talks" to the NPC, reads the 5 buttons, stores the cooldown of EVERY difficulty, then closes.
        local function promptPos(p)
            local par = p.Parent
            if par and par:IsA("BasePart") then return par.Position end
            if par and par:IsA("Attachment") then return par.WorldPosition end
        end

        -- the "Talk" prompt of the NPC (on its model, otherwise the closest prompt within 25 studs)
        local function findTalkPrompt(id)
            local model = findNPC(id)
            if model then
                for _, d in ipairs(model:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then return d end
                end
            end
            local hrp = getHRP()
            if not hrp then return nil end
            local best, bd = nil, 25
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    local pos = promptPos(d)
                    if pos and (pos - hrp.Position).Magnitude < bd then
                        best, bd = d, (pos - hrp.Position).Magnitude
                    end
                end
            end
            return best
        end

        local function firePrompt(prompt)
            if typeof(fireproximityprompt) == "function" then
                return pcall(fireproximityprompt, prompt)
            end
            return pcall(function()
                prompt:InputHoldBegin()
                task.wait((prompt.HoldDuration or 0) + 0.1)
                prompt:InputHoldEnd()
            end)
        end

        -- the 5 difficulty buttons of the open dialog -> {normal = secs, medium = secs, ...} (0 = available)
        local isDiffName = toValidSet(DIFFS)
        local dialogGrp -- container of the 5 difficulty buttons found last time (checked first: no full scan)

        -- the 5 difficulty buttons of one container -> {normal = secs, medium = secs, ...} (0 = available), or nil
        local function readGroup(parent)
            local btns = {}
            for _, b in ipairs(parent:GetChildren()) do
                if b:IsA("TextButton") and shown(b) then btns[#btns + 1] = b end
            end
            if #btns < #DIFFS then return nil end
            table.sort(btns, function(x, y) return x.AbsolutePosition.X < y.AbsolutePosition.X end)
            local res = {}
            for i, d in ipairs(DIFFS) do
                local t = clean(btns[i].Text):lower():match("^%s*(.-)%s*$")
                if isDiffName[t] then
                    res[d] = 0
                elseif parseTime(t) then
                    res[d] = parseTime(t)
                else
                    return nil
                end
            end
            return res
        end

        -- returns the 5 difficulty timers of the open dialog and their container (nil when no dialog is open)
        local function readDialogDiffs()
            if dialogGrp and dialogGrp.Parent then
                local res = readGroup(dialogGrp)
                if res then return res, dialogGrp end
            end
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            local parents = {}
            for _, b in ipairs(pg:GetDescendants()) do
                if b:IsA("TextButton") and b.Parent and not b:IsDescendantOf(gui) and shown(b) then
                    parents[b.Parent] = true
                end
            end
            for parent in pairs(parents) do
                local res = readGroup(parent)
                if res then
                    dialogGrp = parent
                    return res, parent
                end
            end
            return nil
        end

        -- is the dialog still open? (cheap when its container is known)
        local function dialogOpen()
            if dialogGrp and dialogGrp.Parent then return readGroup(dialogGrp) ~= nil end
            return readDialogDiffs() ~= nil
        end

        -- ---- closing the dialog ----
        -- Not every NPC has an "I'm not ready." button (e.g. Seras Integra), and an open dialog blocks the fight.
        -- 1) press a close-like button of the dialog's own gui  2) press any "not ready" button
        -- 3) last resort: hide the dialog frame (given back before the next talk)
        local CLOSE_WORDS = {"not ready", "not tonight", "goodbye", "bye", "leave", "later", "never mind", "nevermind", "no thanks"}
        local CLOSE_EXACT = {x = true, ["×"] = true, ["✕"] = true, close = true}
        local ACCEPT_WORDS = {"i'll go", "ill go", "let's go", "lets go", "fight", "start", "yes", "accept"} -- would START the fight: never pressed
        local hiddenDialog

        local function isAcceptText(t)
            for _, w in ipairs(ACCEPT_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        local function isCloseText(t)
            if CLOSE_EXACT[t] then return true end
            for _, w in ipairs(CLOSE_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- waits until the dialog is gone (checks every 0.15 s instead of a fixed pause)
        local function waitClosed(maxT)
            local t0 = os.clock()
            repeat
                if not dialogOpen() then return true end
                task.wait(0.15)
            until os.clock() - t0 > maxT
            return false
        end

        local function closeDialog(grp)
            local sg = grp and grp:FindFirstAncestorWhichIsA("ScreenGui")
            if sg and CFG.DEBUG_TIMER then
                local out = {}
                for _, b in ipairs(sg:GetDescendants()) do
                    if b:IsA("TextButton") and shown(b) and b.Parent ~= grp then
                        out[#out + 1] = b.Name .. "=" .. clean(b.Text)
                    end
                end
                print("[PibbleHub] dialog gui '" .. sg.Name .. "', other buttons: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
            end
            -- 1) close-like button inside the dialog's gui
            if sg then
                for _, b in ipairs(sg:GetDescendants()) do
                    if b:IsA("TextButton") and shown(b) and b.Parent ~= grp
                        and not isAcceptText(clean(b.Text):lower())
                        and isCloseText(clean(b.Text):lower():match("^%s*(.-)%s*$")) then
                        if activateButton(b) then break end
                    end
                end
                if waitClosed(0.8) then return true end
            end
            -- 1b) every NPC has its own decline text ("I'm not ready.", ...): press the choice button(s)
            -- shown just under the difficulty buttons, whatever they say
            do
                local pg = player:FindFirstChild("PlayerGui")
                local bottom, left, right = nil, math.huge, 0
                for _, b in ipairs(grp:GetChildren()) do
                    if b:IsA("TextButton") and shown(b) then
                        bottom = math.max(bottom or 0, b.AbsolutePosition.Y + b.AbsoluteSize.Y)
                        left = math.min(left, b.AbsolutePosition.X)
                        right = math.max(right, b.AbsolutePosition.X + b.AbsoluteSize.X)
                    end
                end
                if pg and bottom then
                    local midX, cands = (left + right) / 2, {}
                    for _, b in ipairs(pg:GetDescendants()) do
                        if b:IsA("TextButton") and shown(b) and b.Parent ~= grp and not b:IsDescendantOf(gui)
                            and clean(b.Text):match("%S") and not isAcceptText(clean(b.Text):lower()) then
                            local p, sz = b.AbsolutePosition, b.AbsoluteSize
                            if p.Y >= bottom - 4 and p.Y <= bottom + 120 and math.abs(p.X + sz.X / 2 - midX) <= 450 then
                                cands[#cands + 1] = b
                            end
                        end
                    end
                    table.sort(cands, function(a, b)
                        local ca, cb = isCloseText(clean(a.Text):lower()), isCloseText(clean(b.Text):lower())
                        if ca ~= cb then return ca end -- close-like buttons first
                        if a.AbsolutePosition.Y ~= b.AbsolutePosition.Y then return a.AbsolutePosition.Y < b.AbsolutePosition.Y end
                        return a.AbsolutePosition.X < b.AbsolutePosition.X
                    end)
                    for i = 1, math.min(2, #cands) do
                        if CFG.DEBUG_TIMER then print("[PibbleHub] dialog choice button: " .. clean(cands[i].Text)) end
                        if activateButton(cands[i]) then
                            if waitClosed(0.8) then return true end
                        end
                    end
                end
            end
            -- 2) any "not ready" button of the interface
            local nr = findButton(function(t)
                for _, w in ipairs(CLOSE_WORDS) do
                    if t:find(w, 1, true) then return true end
                end
                return false
            end)
            if nr and activateButton(nr) then
                if waitClosed(0.8) then return true end
            end
            -- 3) hide the dialog frame
            if sg then
                local top = grp
                while top.Parent and top.Parent ~= sg do top = top.Parent end
                if top:IsA("GuiObject") then
                    top.Visible = false
                    hiddenDialog = top
                else
                    sg.Enabled = false
                    hiddenDialog = sg
                end
                if waitClosed(0.8) then return true end
            end
            print("[PibbleHub] could not close the NPC dialog")
            return false
        end

        -- Opens the dialog, stores the cooldown of every difficulty of this NPC, closes the dialog.
        -- Returns true when the dialog could be read.
        local syncedAt = {} -- id -> os.time() of the last dialog read
        local setDiff = {}  -- id -> difficulty last sent with SetNPCDifficulty (no wait when it did not change)
        local function syncTimers(id)
            -- already read recently: the stored cooldowns (dialog + wins) are up to date, no need to talk again
            if syncedAt[id] and os.time() - syncedAt[id] < CFG.RESYNC_SECS then return true end
            for _ = 1, 2 do
                if hiddenDialog then -- give back a dialog we hid last time, so the game can open it again
                    pcall(function()
                        if hiddenDialog:IsA("ScreenGui") then hiddenDialog.Enabled = true else hiddenDialog.Visible = true end
                    end)
                    hiddenDialog = nil
                end
                local prompt = findTalkPrompt(id)
                if prompt and firePrompt(prompt) then
                    task.wait(0.15) -- let the dialog open and its buttons refresh (a stale one would show old timers)
                    local res, grp, t0 = nil, nil, os.clock()
                    while os.clock() - t0 < 3 do
                        res, grp = readDialogDiffs()
                        if res then break end
                        task.wait(0.15)
                    end
                    if res then
                        local now, out = os.time(), {}
                        for _, d in ipairs(DIFFS) do
                            local k = id .. "|" .. d
                            if res[d] > 0 then
                                Boss.cooldown[k] = now + res[d] + CFG.TIMER_MARGIN
                                out[#out + 1] = d .. "=" .. res[d] .. "s"
                            else
                                Boss.cooldown[k] = nil -- available (also corrects an old guess)
                                out[#out + 1] = d .. "=ready"
                            end
                        end
                        Settings.save()
                        if CFG.DEBUG_TIMER then
                            print("[PibbleHub] dialog timers " .. id .. ": " .. table.concat(out, " | "))
                        end
                        syncedAt[id] = os.time()
                        closeDialog(grp)
                        return true
                    end
                end
                task.wait(0.3)
            end
            print("[PibbleHub] could not read the dialog of " .. id)
            return false
        end

        -- ---- fight loop ----
        local nextBoss -- forward declaration (bossFight and nextBoss call each other)

        -- The boss is on a timer: remember when it is available again (saved), move the queue on.
        -- estimated = true: the timer is a guess (the server refused without telling it)
        local function skipOnTimer(id, diff, secs, estimated)
            Boss.cooldown[id .. "|" .. diff] = os.time() + secs + CFG.TIMER_MARGIN
            Settings.save()
            print(("[PibbleHub] %s on %s (%s): %ds"):format(estimated and "assumed cooldown" or "timer", id, diff, secs))
            Boss.active = false
            Boss.started = false
            advance()
            statusL.Text = ("Boss: %s %s %d:%02d"):format(niceName(id), estimated and "refused, retry in" or "on timer", secs // 60, secs % 60)
            if Boss.auto then
                task.delay(0.2, function()
                    if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                end)
            end
        end

        -- Every selected fight is on a timer: go to the lobby and wait for the first one to end
        local function waitForTimers()
            local function soonest()
                local best, now = nil, os.time()
                for _, f in ipairs(fightList()) do
                    local r = Boss.cooldown[keyOf(f)]
                    if not r or r <= now then return 0 end
                    best = best and math.min(best, r - now) or (r - now)
                end
                return best
            end

            if not Boss.auto then -- manual Start: just say so
                local s = math.ceil(soonest() or 0)
                statusL.Text = ("Boss: all on timer (%d:%02d)"):format(s // 60, s % 60)
                return
            end

            Boss.timerWait = true
            task.spawn(function()
                local wentLobby, lastTry = false, 0
                while Boss.auto and gui.Parent and not Boss.active do
                    local s = soonest()
                    if not s or s <= 0 then break end
                    s = math.ceil(s)
                    statusL.Text = ("Boss: all on timer, %d:%02d"):format(s // 60, s % 60)
                    if not wentLobby and not Raid.running and Candy.goLobby and os.clock() - lastTry > 20 then
                        lastTry = os.clock()
                        local okL, inL = pcall(Candy.goLobby)
                        wentLobby = okL and inL == true -- not there yet: try again in 20 s
                    end
                    task.wait(1)
                end
                Boss.timerWait = false
                if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
            end)
        end

        -- npc id -> name of the world it lives in
        local worldOf = {}
        for _, w in ipairs(BOSS_WORLDS) do
            for _, id in ipairs(w[2]) do worldOf[id] = w[1] end
        end

        -- Every NPC lives in its own world: if it is not in the workspace, travel to its world first
        -- (1st attempt: the world's Enter button, 2nd attempt: the TeleportToWorld remote)
        local function ensureWorld(id)
            if findNPC(id) then return true end
            local world = worldOf[id]
            if not world then return true end
            for attempt = 1, 2 do
                statusL.Text = ("Boss: going to %s"):format(world)
                local method = Worlds.go(world, attempt == 2)
                if not method then
                    statusL.Text = "Boss: no teleport for " .. world
                    return false
                end
                -- wait (up to ~15 s) for the world to load and its NPC to appear
                for _ = 1, 60 do
                    task.wait(0.25)
                    if findNPC(id) then
                        task.wait(0.4)
                        return true
                    end
                end
            end
            return false
        end

        local function bossFight()
            -- during a raid the boss queue is paused: Raid calls Boss.resume when it is over
            if Boss.active or Boss.waiting or Boss.timerWait or Raid.running or Dungeon.active then return end
            if not Remotes.StartNPC then
                statusL.Text = "StartNPCBattle not found"
                return
            end
            local pick = peekFight()
            if not pick then
                if #fightList() == 0 then
                    statusL.Text = "Boss: select at least one"
                else
                    waitForTimers() -- everything selected is on a timer: lobby + wait
                end
                return
            end
            local id, diff = pick[1], pick[2]

            Boss.waiting = true
            while Candy.busy do task.wait(0.5) end -- a candy run is in progress: let it finish first
            Boss.waiting = false
            if Raid.running then return end -- a raid started while we were waiting
            Boss.active = true
            Boss.started = false -- BattleEnd events are ignored until StartNPCBattle is really fired
            Boss.current = pick
            Boss.run += 1
            local myRun = Boss.run

            statusL.Text = "Boss: going to " .. niceName(id)
            if not (ensureWorld(id) and tpToNPC(id)) then
                Boss.active = false
                advance() -- skip this NPC so the next selected boss can run
                statusL.Text = "Boss: NPC not found (" .. id .. ")"
                if Boss.auto then
                    task.delay(CFG.AUTO_DELAY * 2, function()
                        if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                    end)
                end
                return
            end
            task.wait(0.1)

            -- 1) talk to the NPC and read the timer of EVERY difficulty (each one has its own cooldown)
            local synced = syncTimers(id)
            if synced and onCooldown(pick) then
                local left = Boss.cooldown[keyOf(pick)] - os.time()
                skipOnTimer(id, diff, math.max(1, left - CFG.TIMER_MARGIN))
                return
            end

            -- 2) set the difficulty, like the game's own menu does
            if Remotes.SetNPCDiff then
                local changed = setDiff[id] ~= diff
                Remotes.SetNPCDiff:FireServer(id, diff)
                setDiff[id] = diff
                -- the server needs a moment to apply a NEW difficulty, otherwise the fight starts on the old one
                if changed then task.wait(CFG.DIFF_DELAY) end
            end

            -- fallback when the dialog could not be read: the timer above the NPC (only if TRUST_NPC_TIMER)
            if not synced then
                dumpTexts(id)
                local pre = CFG.TRUST_NPC_TIMER and npcTimer(findNPC(id)) or nil
                if pre then
                    skipOnTimer(id, diff, pre)
                    return
                end
            end

            Boss.started = true
            Boss.startedAt = os.clock()
            Remotes.StartNPC:FireServer(id)
            statusL.Text = ("Boss: fighting %s (%s)"):format(id, diff)

            -- post-check: poll for a few seconds. A refused fight shows a timer (server message,
            -- popup or NPC billboard), or the server stays completely silent.
            local since = Boss.startedAt
            local deadline = os.clock() + CFG.TIMER_CHECK_DELAY
            while os.clock() < deadline do
                if not (Boss.active and Boss.run == myRun) then return end -- fight already ended/handled
                local secs, guessed = refusedTimer(id, since)
                if secs then
                    skipOnTimer(id, diff, secs, guessed)
                    return
                end
                task.wait(0.25)
            end
            if Boss.active and Boss.run == myRun
                and CFG.REFUSE_IF_SILENT and noticeCount(since) == 0 then
                dumpGuiTimers()
                skipOnTimer(id, diff, CFG.UNKNOWN_COOLDOWN, true) -- refused without a word: put it aside
                return
            end

            task.delay(CFG.BOSS_TIMEOUT, function()
                if Boss.active and Boss.run == myRun and gui.Parent then
                    Boss.active = false
                    advance()
                    statusL.Text = "Boss: no end event (timeout)"
                    if Boss.auto then nextBoss() end
                end
            end)
        end

        -- Bosses have priority. Between two fights, if the candy timer is up, the candies are collected right away.
        nextBoss = function()
            if Candy.runIfReady then Candy.runIfReady() end
            if Boss.auto and gui.Parent and not Boss.active then bossFight() end
        end

        -- called by Auto Raid once the raid is over: restarts the boss queue
        Boss.resume = function()
            if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
        end

        startBtn.MouseButton1Click:Connect(function()
            if not Boss.active then bossFight() end
        end)

        local function setAuto(on)
            Boss.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
            if on and not Boss.active then bossFight() end
        end
        Boss.setAuto = setAuto

        autoBtn.MouseButton1Click:Connect(function() setAuto(not Boss.auto) end)

        -- called by the BattleEnd router: returns true when the result belonged to a boss fight
        Boss.onBattleEnd = function(data)
            if not Boss.active then
                -- duplicate of a result we just handled: swallow it (it must not count as anything else)
                return os.clock() - Boss.lastEnd < 5
            end
            -- not started yet, or too early: stale result of the PREVIOUS fight, it is not ours
            if not Boss.started or os.clock() - Boss.startedAt < CFG.BOSS_MIN_FIGHT then
                logEnd("boss (ignored, stale)", data)
                return true
            end
            Boss.active = false
            Boss.lastEnd = os.clock()
            if LOSS[tostring(data.result):lower()] and Boss.retries < CFG.BOSS_RETRIES then
                -- lost: same boss, same difficulty again (the queue does not move)
                Boss.retries += 1
                statusL.Text = ("Boss: lost, retry %d/%d"):format(Boss.retries, CFG.BOSS_RETRIES)
            else
                -- a win starts the cooldown of that boss + difficulty: remember it, so the rotation
                -- does not come back to it before it is over (saved to the file)
                local cur = Boss.current
                if cur and not LOSS[tostring(data.result):lower()] then
                    Boss.cooldown[keyOf(cur)] = os.time() + winCooldown(cur[1])
                    Settings.save()
                end
                advance() -- move to the next fight only now that this one is really over
                statusL.Text = ("Boss: %s"):format(tostring(data.result))
            end
            logEnd("boss", data)
            if Boss.auto then
                task.delay(CFG.BOSS_DELAY, function()
                    if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                end)
            end
            return true
        end
    end

    -- =====================================================================
    -- == 11. FEATURE: INFINITE TOWER (auto give up when a weather appears)
    -- =====================================================================
    do
        label("Infinite Tower", 450, ORANGE)
        local statusL = label("Auto give up: idle", 470)
        local weatherBtn = button("Weather: Any", 10, 494, 230, 28, DARK)
        local popBtn = button("Pop: OFF", 10, 530, 105, 28, RED)
        local minBox = textbox("Min floor", 125, 530, 115, 28, tostring(Infinite.minFloor), 15)

        -- ---- weather menu (multi-select) ----
        local ITEM_H, ITEM_GAP = 28, 4
        local weatherMenu = sidePanel("Frame", 190, (#WEATHERS + 1) * (ITEM_H + ITEM_GAP) + ITEM_GAP, 456)
        local anyBtn = button("Any weather", 8, ITEM_GAP, 174, ITEM_H, DARK, weatherMenu, 21)
        local weatherBtns = {}
        for i, w in ipairs(WEATHERS) do
            weatherBtns[w] = button(w, 8, ITEM_GAP + i * (ITEM_H + ITEM_GAP), 174, ITEM_H, DARK, weatherMenu, 21)
        end

        local function refreshWeatherPick()
            local n, last = 0, nil
            for _, w in ipairs(WEATHERS) do
                local on = Infinite.weathers[w:lower()] == true
                if on then n += 1; last = w end
                weatherBtns[w].BackgroundColor3 = on and GREEN or DARK
                weatherBtns[w].Text = (on and "[x] " or "[  ] ") .. w
            end
            anyBtn.BackgroundColor3 = (n == 0) and GREEN or DARK
            if n == 0 then
                weatherBtn.Text = "Weather: Any"
            elseif n == 1 then
                weatherBtn.Text = "Weather: " .. last
            else
                weatherBtn.Text = ("Weather: %d selected"):format(n)
            end
        end

        for _, w in ipairs(WEATHERS) do
            weatherBtns[w].MouseButton1Click:Connect(function()
                local k = w:lower()
                if Infinite.weathers[k] then Infinite.weathers[k] = nil else Infinite.weathers[k] = true end
                refreshWeatherPick()
                Settings.save()
            end)
        end
        anyBtn.MouseButton1Click:Connect(function()
            Infinite.weathers = {}
            refreshWeatherPick()
            Settings.save()
        end)
        weatherBtn.MouseButton1Click:Connect(function()
            weatherMenu.Visible = not weatherMenu.Visible
        end)
        refreshWeatherPick()

        -- ---- weather detection ----
        -- Empty selection = any weather triggers the give up
        local function weatherAllowed(name)
            if next(Infinite.weathers) == nil then return true end
            return Infinite.weathers[tostring(name or ""):lower()] == true
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
            if n and n ~= "" and secs and secs > 0 then return n, secs end
            return nil
        end

        -- ---- give up ----
        -- Method 1: press the game's own "Give up" button (fires its real click handlers)
        -- Method 2 (fallback): fire EndTowerRemote directly
        local function giveUp()
            Infinite.lastGiveUp = os.clock()
            Infinite.floor = 1 -- the game restarts the run by itself
            local b = findButton(function(t) return t:find("give up", 1, true) ~= nil end)
            if b and activateButton(b) then
                task.delay(0.6, confirmDialog)
                return "button"
            elseif Remotes.EndTower then
                Remotes.EndTower:FireServer(CFG.END_ARG)
                return "remote"
            end
        end

        -- ---- wiring ----
        local function setPop(on)
            Infinite.on = on
            popBtn.Text = on and "Pop: ON" or "Pop: OFF"
            popBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Infinite.setPop = setPop

        popBtn.MouseButton1Click:Connect(function() setPop(not Infinite.on) end)

        minBox.FocusLost:Connect(function()
            local n = tonumber(minBox.Text)
            if n then Infinite.minFloor = math.max(1, math.floor(n)) end -- no upper limit
            minBox.Text = tostring(Infinite.minFloor)
            Settings.save()
        end)

        -- Every second while Pop is ON (and no raid is running): reads the weather and shows why it does (or doesn't) give up
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                if Infinite.on and not Raid.running then
                    local n, secs = scanWeather()
                    local why
                    if not n then
                        why = "no weather"
                    elseif not weatherAllowed(n) then
                        why = "not selected"
                    elseif Infinite.floor < Infinite.minFloor then
                        why = "floor<min"
                    elseif os.clock() - Infinite.lastGiveUp < 8 then
                        why = "cooldown"
                    elseif secs > CFG.POP_GIVEUP_LEFT then
                        -- wanted weather found: keep playing until only POP_GIVEUP_LEFT seconds remain on it
                        why = ("give up in %ds"):format(secs - CFG.POP_GIVEUP_LEFT)
                    else
                        why = "GIVE UP"
                        giveUp()
                    end
                    statusL.Text = ("%s | F%d | %s"):format(n or "-", Infinite.floor, why)
                end
            end
        end)

        -- called by the BattleEnd router: returns true for every result that is NOT the Halloween Tower.
        -- Only tracks the current floor (needed for the "min floor" check).
        Infinite.onBattleEnd = function(data)
            if data.tower == "halloween" and data.mode == "infinite_room" then return false end
            local fl = tonumber(data.floor)
            if os.clock() - Infinite.lastGiveUp < 10 or LOSS[tostring(data.result):lower()] then
                Infinite.floor = 1 -- run ended (our give up or a loss): the next run starts at floor 1
            elseif fl then
                Infinite.floor = fl + 1
            end
            logEnd("infinite", data)
            return true
        end
    end

    -- =====================================================================
    -- == 11b. FEATURE: AUTO RAID
    -- =====================================================================
    -- A raid slot starts at every xx:00 and xx:30 (real clock). The raid can be done during the first
    -- 15 minutes of the slot (the timer shown in the UI). One raid = teleport to RaidWorld (skipped when
    -- we are already there), stand next to the raid boss (Workspace.NPCs.Yhwach, NPCId raid_soul_king_npc),
    -- then StartRaidBattle fired 4 times (each fight waits for its BattleEnd, or RAID_FIGHT_TIMEOUT).
    -- While a raid runs, Candy / Tower / Boss / Pop are paused, and resumed right after.
    do
        label("Auto Raid", 570, ORANGE)
        local statusL = label("Raid: idle", 590)
        local timerL = label("Next raid: -", 610)
        local startBtn = button("Start now", 10, 636, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 636, 115, 28, RED)

        local function slotOf() return math.floor(os.time() / CFG.RAID_INTERVAL) end
        local function intoSlot() return os.time() % CFG.RAID_INTERVAL end
        local function inWindow() return intoSlot() < CFG.RAID_WINDOW end

        local function mmss(s)
            s = math.max(0, math.floor(s))
            return ("%dm %02ds"):format(s // 60, s % 60)
        end

        -- ---- what the server sends back (to know whether StartRaidBattle was accepted) ----
        local Seen = { list = {} } -- {t = os.clock(), name = lowercase remote name, text = lowercase texts of the event}

        local function collectTexts(v, out, depth)
            if type(v) == "string" then
                out[#out + 1] = v
            elseif type(v) == "table" and depth < 3 then
                for _, x in pairs(v) do collectTexts(x, out, depth + 1) end
            end
        end

        local function isRefusal(text)
            if text == "" then return false end
            for _, w in ipairs(CFG.RAID_REFUSE_WORDS) do
                if text:find(w, 1, true) then return true end
            end
            return false
        end

        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and not CFG.IGNORE_REMOTES[r.Name] then
                r.OnClientEvent:Connect(function(...)
                    local args, texts = table.pack(...), {}
                    for i = 1, args.n do collectTexts(args[i], texts, 0) end
                    local name = r.Name:lower()
                    local text = clean(table.concat(texts, " ")):lower()
                    local list = Seen.list
                    list[#list + 1] = { t = os.clock(), name = name, text = text }
                    if #list > 40 then table.remove(list, 1) end
                    if Raid.running and CFG.DEBUG_TIMER and os.clock() - Raid.startedAt < 15 then
                        local packed = {...}
                        local okJ, txt = pcall(function() return HttpService:JSONEncode(packed) end)
                        print("[PibbleHub] raid: server event", r.Name, okJ and txt or "(not serializable)")
                    end
                    -- fallback end of a raid fight, for when the result does not come through BattleEnd:
                    -- a remote with "raid" in its name and an end-like word (sync / state events never count)
                    if Raid.running and Raid.fightStarted and os.clock() - Raid.startedAt > CFG.RAID_MIN_FIGHT
                        and name:find("raid", 1, true) and not name:find("sync", 1, true) and not name:find("state", 1, true)
                        and not isRefusal(text) then
                        for _, w in ipairs(CFG.RAID_END_EVENTS) do
                            if name:find(w, 1, true) then
                                Raid.fightStarted = false
                                Raid.fightDone = true
                                Raid.fights += 1
                                Raid.lastEndAt = os.clock()
                                print("[PibbleHub] raid: fight end detected from remote " .. r.Name)
                                break
                            end
                        end
                    end
                end)
            end
        end

        -- a server text that refuses the raid (cooldown / already done...) since `since`
        local function refusedText(since)
            for _, e in ipairs(Seen.list) do
                if e.t >= since and isRefusal(e.text) then return e.text end
            end
        end

        -- the fight was accepted: a battle / raid / fight event, that is not a refusal text
        local function accepted(since)
            for _, e in ipairs(Seen.list) do
                if e.t >= since and not isRefusal(e.text) then
                    for _, w in ipairs(CFG.RAID_START_EVENTS) do
                        if e.name:find(w, 1, true) then return true end
                    end
                end
            end
            return false
        end

        -- the game's own start button of the raid (if the raid world shows one)
        local function pressRaidButton()
            local b = findButton(function(t)
                return t == "start" or t == "fight" or t == "begin"
                    or t:find("start raid", 1, true) ~= nil or t:find("start battle", 1, true) ~= nil
                    or t:find("start fight", 1, true) ~= nil
            end)
            if b and shown(b) and activateButton(b) then
                print("[PibbleHub] raid: pressed button", b:GetFullName())
                return true
            end
            return false
        end

        -- Teleports to the raid world and waits until the character has REALLY arrived (it moved), then lets the world settle
        local function goToRaidWorld()
            local hrp0 = getHRP()
            local before = hrp0 and hrp0.Position
            Remotes.Teleport:FireServer(CFG.RAID_WORLD)
            local t0, moved = os.clock(), false
            while os.clock() - t0 < CFG.RAID_TP_TIMEOUT do
                task.wait(0.25)
                local hrp = getHRP()
                if hrp and (not before or (hrp.Position - before).Magnitude > 100) then
                    moved = true
                    break
                end
            end
            if CFG.DEBUG_TIMER then
                print("[PibbleHub] raid: teleport " .. (moved and "done" or "not detected (continuing anyway)")
                    .. " after " .. ("%.1f"):format(os.clock() - t0) .. "s")
            end
            task.wait(CFG.RAID_LOAD_DELAY)
        end

        -- ---- standing next to the raid boss (StartRaidBattle only works when we are close to it) ----
        local function posOf(o)
            if o:IsA("Model") then
                local okP, pv = pcall(function() return o:GetPivot() end)
                return okP and pv or nil
            elseif o:IsA("BasePart") then
                return o.CFrame
            elseif o:IsA("Attachment") then
                return CFrame.new(o.WorldPosition)
            end
        end

        -- The raid boss is the NPC Workspace.NPCs.Yhwach (attribute NPCId = raid_soul_king_npc, prompt "Talk").
        -- It is found by its NPCId first, then by model name, then by the billboard text ("Soul King").
        -- Portals ("Soul King Raid") are never matched. The closest match wins.
        local raidBossCache, raidLastScan = nil, 0
        local function normS(x) return (tostring(x):lower():gsub("[^%w]+", "")) end

        local function isRaidNPC(m)
            if not m:IsA("Model") or Players:GetPlayerFromCharacter(m) then return false end
            if not m:FindFirstChildOfClass("Humanoid") then return false end
            local a = m:GetAttribute("NPCId") or m:GetAttribute("NpcId") or m:GetAttribute("npcId")
            if a then
                local na = normS(a)
                if na == normS(CFG.RAID_NPC_ID) or na:find("raid", 1, true) then return true end
            end
            local nn = normS(m.Name)
            for _, w in ipairs(CFG.RAID_BOSS_NAMES) do
                local nw = normS(w)
                if nw ~= "" and nn == nw then return true end
            end
            return false
        end

        local function findRaidBoss()
            if CFG.RAID_BOSS_POS then return CFrame.new(CFG.RAID_BOSS_POS), "fixed position" end
            -- the boss found last time is reused (no scan of the whole workspace)
            if raidBossCache and raidBossCache.Parent and raidBossCache:IsDescendantOf(workspace) then
                local cf0 = posOf(raidBossCache)
                if cf0 then return cf0, raidBossCache:GetFullName() end
            end
            raidBossCache = nil
            if os.clock() - raidLastScan < 0.5 then return nil end -- at most two full scans per second
            raidLastScan = os.clock()

            local hrp = getHRP()
            local best, bestD, bestObj = nil, math.huge, nil
            local function consider(m)
                local cf = posOf(m)
                if not cf then return end
                local d = hrp and (cf.Position - hrp.Position).Magnitude or 0
                if d < bestD then best, bestD, bestObj = cf, d, m end
            end

            -- 1) Workspace.NPCs (fast)
            local npcs = workspace:FindFirstChild("NPCs")
            if npcs then
                for _, m in ipairs(npcs:GetChildren()) do
                    if isRaidNPC(m) then consider(m) end
                end
            end
            -- 2) the whole workspace
            if not bestObj then
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("Model") and isRaidNPC(d) then consider(d) end
                end
            end
            -- 3) billboard text ("Soul King") -> the NPC model that owns it (never a portal)
            if not bestObj then
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("TextLabel") then
                        local t = normS(clean(d.Text))
                        for _, w in ipairs(CFG.RAID_BOSS_NAMES) do
                            if t == normS(w) then
                                local m = d:FindFirstAncestorWhichIsA("Model")
                                if m and m:FindFirstChildOfClass("Humanoid") and not m.Name:lower():find("portal", 1, true) then
                                    consider(m)
                                end
                            end
                        end
                    end
                end
            end

            if bestObj then raidBossCache = bestObj end
            return best, bestObj and bestObj:GetFullName() or nil
        end

        -- debug: what is around the player in the raid world, to help find the boss
        local function dumpRaidSurroundings()
            local hrp = getHRP()
            if not hrp then return end
            local out = {}
            for _, d in ipairs(workspace:GetDescendants()) do
                if #out >= 20 then break end
                if d:IsA("ProximityPrompt") then
                    local cf = posOf(d.Parent)
                    if cf and (cf.Position - hrp.Position).Magnitude < 400 then
                        out[#out + 1] = "prompt " .. d.Parent:GetFullName() .. " [" .. tostring(d.ActionText) .. "/" .. tostring(d.ObjectText) .. "]"
                    end
                elseif d:IsA("Humanoid") and d.Parent and not Players:GetPlayerFromCharacter(d.Parent) then
                    local cf = posOf(d.Parent)
                    if cf and (cf.Position - hrp.Position).Magnitude < 400 then
                        out[#out + 1] = "npc " .. d.Parent:GetFullName()
                    end
                end
            end
            print("[PibbleHub] raid: boss not found. Nearby (400 studs): " .. (#out > 0 and table.concat(out, " | ") or "(nothing)"))
            print("[PibbleHub] raid: set CFG.RAID_NPC_ID / CFG.RAID_BOSS_NAMES to the boss NPC, or CFG.RAID_BOSS_POS to a position next to it.")
        end

        -- Teleports next to the raid boss (retries for tries * 0.25 s: the boss may still be streaming in)
        local function tpToRaidBoss(tries, dump)
            for _ = 1, tries do
                local hrp = getHRP()
                local cf, what = findRaidBoss()
                if hrp and cf then
                    if CFG.RAID_BOSS_POS then
                        hrp.CFrame = cf
                    else
                        hrp.CFrame = CFrame.new(cf.Position + cf.LookVector * 5 + Vector3.new(0, 2, 0))
                    end
                    if CFG.DEBUG_TIMER and dump then print("[PibbleHub] raid: teleported next to " .. tostring(what)) end
                    task.wait(0.5)
                    return true
                end
                task.wait(0.25)
            end
            if dump then dumpRaidSurroundings() end
            return false
        end

        -- the Fight button of the game's own RaidGui (not the one of the BattleDummyGui)
        local function pressRaidGuiFight()
            local pg = player:FindFirstChild("PlayerGui")
            local rg = pg and pg:FindFirstChild("RaidGui")
            local b = rg and rg:FindFirstChild("FightButton", true)
            if b and activateButton(b) then
                print("[PibbleHub] raid: pressed RaidGui fight button")
                return true
            end
            return false
        end

        -- talks to the raid boss (its "Talk" prompt) to open the RaidGui
        local function talkToRaidBoss()
            local m = raidBossCache
            local prompt = m and m:FindFirstChildWhichIsA("ProximityPrompt", true)
            if not prompt then return false end
            if typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
            else
                pcall(function()
                    prompt:InputHoldBegin()
                    task.wait((prompt.HoldDuration or 0) + 0.1)
                    prompt:InputHoldEnd()
                end)
            end
            task.wait(0.6)
            return true
        end

        -- Fires StartRaidBattle until the server reacts. Try 1: remote only. Try 2+: talk to the boss and press
        -- the RaidGui Fight button too. Try 3: also any generic start button.
        -- Returns true when the server accepted the fight.
        local function launchFight()
            for attempt = 1, CFG.RAID_START_TRIES do
                tpToRaidBoss(8, attempt == 1) -- stay next to the boss (it may have moved / we may have respawned)
                local t = os.clock()
                Raid.startedAt = t
                if attempt >= 2 then
                    talkToRaidBoss()
                    pressRaidGuiFight()
                end
                Remotes.StartRaid:FireServer()
                if attempt >= 3 then pressRaidButton() end
                while os.clock() - t < CFG.RAID_START_CHECK do
                    if Raid.fightDone then return true end
                    local why = refusedText(t)
                    if why then
                        print("[PibbleHub] raid: refused by the server: " .. why)
                        return false, "refused"
                    end
                    if accepted(t) then return true end
                    task.wait(0.2)
                end
                print(("[PibbleHub] raid: no server reaction (try %d/%d)"):format(attempt, CFG.RAID_START_TRIES))
            end
            return false, "silent"
        end

        -- manual = true: "Start now" button, ignores the 15 min window and the Auto switch
        local function run(manual)
            if Raid.running then return end
            if not (Remotes.StartRaid and Remotes.Teleport) then
                statusL.Text = "Raid: remote not found"
                return
            end
            Raid.running = true -- from now on every other automation is paused
            -- (Raid.lastSlot is only set once a fight really started: a failed attempt is retried by Auto)
            Raid.fights = 0
            Raid.fightStarted = false
            Raid.fightDone = false

            -- a running dungeon is left first (the raid teleport below takes us out of it anyway)
            if Dungeon.afkOff then pcall(Dungeon.afkOff) end
            if Dungeon.leave then Dungeon.leave({ noTeleport = true, why = "raid" }) end

            -- let a running boss fight / candy run finish first (they are not started again meanwhile)
            local t0 = os.clock()
            while (Boss.active or Candy.busy) and os.clock() - t0 < CFG.RAID_WAIT_OTHERS do
                statusL.Text = "Raid: waiting for current action"
                task.wait(0.5)
            end

            -- already in the raid world (the boss is close)? then no teleport
            local cf0 = findRaidBoss()
            local hrpN = getHRP()
            if cf0 and hrpN and (cf0.Position - hrpN.Position).Magnitude < CFG.RAID_NEAR then
                statusL.Text = "Raid: already in raid world"
            else
                statusL.Text = "Raid: teleporting"
                goToRaidWorld()
            end
            statusL.Text = "Raid: going to boss"
            local bossFound = tpToRaidBoss(40, true)
            if not bossFound then statusL.Text = "Raid: boss not found (see F9)" end

            for i = 1, CFG.RAID_FIGHTS do
                if not manual and (not Raid.auto or not inWindow()) then break end
                Raid.fightDone = false
                Raid.fightStarted = true
                statusL.Text = ("Raid: starting fight %d/%d"):format(i, CFG.RAID_FIGHTS)
                local okFight, why = launchFight()
                if not okFight then
                    Raid.fightStarted = false
                    if why == "refused" or (CFG.RAID_SILENT_IS_COOLDOWN and bossFound) then
                        -- the raid is on cooldown / already done: skip this slot (also saved, so a relaunch does not retry)
                        Raid.lastSlot = slotOf()
                        Settings.save()
                        statusL.Text = "Raid: on cooldown, skipped until next slot"
                        print("[PibbleHub] raid: " .. (why == "refused" and "refused by the server" or "no reaction from the server")
                            .. " -> slot skipped. Look at the 'raid: server event' lines above if this is wrong.")
                    else
                        statusL.Text = ("Raid: fight %d not accepted (see F9)"):format(i)
                        print("[PibbleHub] raid: the server never reacted to StartRaidBattle (boss not found?). Check the 'server event' lines above:"
                            .. " if the game does answer, add a word of that remote's name to CFG.RAID_START_EVENTS.")
                    end
                    break
                end
                statusL.Text = ("Raid: fight %d/%d"):format(i, CFG.RAID_FIGHTS)
                if Raid.lastSlot ~= slotOf() then
                    Raid.lastSlot = slotOf() -- the raid really started: only one raid per slot (saved)
                    Settings.save()
                end

                -- wait for the end of the fight (BattleEnd), or the timeout, or the end of the window
                local t = os.clock()
                while not Raid.fightDone and os.clock() - t < CFG.RAID_FIGHT_TIMEOUT do
                    if not manual and (not Raid.auto or not inWindow()) then break end
                    task.wait(0.25)
                end
                Raid.fightStarted = false
                task.wait(CFG.RAID_FIGHT_DELAY)
            end

            Raid.fightStarted = false
            Raid.running = false
            if not statusL.Text:find("not accepted", 1, true) and not statusL.Text:find("cooldown", 1, true) then
                statusL.Text = ("Raid: done (%d/%d fights)"):format(Raid.fights, CFG.RAID_FIGHTS)
            end

            -- resume what was paused: tower and boss queue restart by themselves,
            -- otherwise (only candy / nothing) go back to the lobby
            task.spawn(function()
                task.wait(1)
                if Tower.auto and Tower.resume then Tower.resume() end
                if Boss.auto and Boss.resume then
                    Boss.resume()
                elseif not Tower.auto and not Dungeon.auto and Candy.goLobby then
                    pcall(Candy.goLobby)
                end
                -- the dungeon starts again right after the raid
                if Dungeon.auto and Dungeon.resume then Dungeon.resume() end
            end)
        end

        local function setAuto(on)
            Raid.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Raid.setAuto = setAuto
        -- a raid is "open" while Auto Raid is ON, the window is open and the raid of this slot is not done yet
        Raid.isOpen = function()
            return Raid.auto and inWindow() and Raid.lastSlot ~= slotOf()
        end

        startBtn.MouseButton1Click:Connect(function() task.spawn(run, true) end)
        autoBtn.MouseButton1Click:Connect(function() setAuto(not Raid.auto) end)

        -- called by the BattleEnd router, BEFORE the other handlers: returns true when the result is a raid fight
        Raid.onBattleEnd = function(data)
            -- duplicate of a fight end we just handled (e.g. through the remote fallback): swallow it
            if Raid.running and not Raid.fightStarted and os.clock() - (Raid.lastEndAt or 0) < 5 then return true end
            if not (Raid.running and Raid.fightStarted) then return false end
            -- a dungeon result is never a raid fight
            if (tostring(data.mode or "") .. " " .. tostring(data.tower or "")):lower():find("dungeon", 1, true) then return false end
            -- a result of the Halloween Tower is never a raid fight
            if data.tower == "halloween" and data.mode == "infinite_room" then return false end
            -- results of the Infinite Tower (mode "tower") are never raid fights either
            if data.mode == "tower" then return false end
            if os.clock() - Raid.startedAt < CFG.RAID_MIN_FIGHT then
                logEnd("raid (ignored, stale)", data)
                return true
            end
            Raid.fightStarted = false
            Raid.fightDone = true
            Raid.fights += 1
            Raid.lastEndAt = os.clock()
            logEnd("raid", data)
            return true
        end

        -- every second: timer + start of the raid at the beginning of each slot
        -- (if the raid could not start, Auto tries again every RAID_RETRY_EVERY seconds during the window)
        local lastTry = -1e9
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                if inWindow() then
                    timerL.Text = "Raid window: " .. mmss(CFG.RAID_WINDOW - intoSlot()) .. " left"
                    if Raid.auto and not Raid.running and Raid.lastSlot ~= slotOf()
                        and os.clock() - lastTry > CFG.RAID_RETRY_EVERY then
                        lastTry = os.clock()
                        task.spawn(run, false)
                    end
                else
                    timerL.Text = "Next raid in: " .. mmss(CFG.RAID_INTERVAL - intoSlot())
                end
            end
        end)
    end

    -- =====================================================================
    -- == 11c. FEATURE: AUTO DUNGEON
    -- =====================================================================
    -- Enters the dungeon by talking to Workspace.NPCs.DungeonNPC ("Marine Dungeon") and pressing "CONTINUE LAST RUN"
    -- (a remote named *dungeon* + start/enter/join is tried first if one exists). It is left with Exit -> SAVE & LEAVE.
    -- While a dungeon is running, Tower and Boss are paused.
    --  * when the raid opens (Auto Raid ON, window open, raid not done yet) the dungeon is LEFT and not restarted
    --  * once the raid is over the dungeon starts again by itself
    -- The remotes of the game are not known: every server event of a *dungeon* remote is printed in F9
    -- ("dungeon: server event ...") so the CFG.DUNGEON_* settings can be adjusted if the auto-detection is wrong.
    do
        label("Auto Dungeon", 676, ORANGE)
        local statusL = label("Dungeon: idle", 696)
        local startBtn = button("Start now", 10, 722, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 722, 115, 28, RED)

        -- ---- server events of the dungeon remotes ----
        local Seen = { list = {} } -- {t = os.clock(), name = lowercase remote name, text = lowercase json}
        local lastSeenExit = 0   -- os.clock() of the last sign that we are inside the dungeon (Exit button, dungeon event / fight)
        local leaving = false    -- the leave sequence is running (AFK must stay OFF)

        local function textOfBtn(b)
            if b:IsA("TextButton") then return clean(b.Text):lower() end
            for _, c in ipairs(b:GetDescendants()) do
                if c:IsA("TextLabel") and clean(c.Text):match("%S") then return clean(c.Text):lower() end
            end
            return ""
        end

        -- the AFK toggle of the dungeon ("AFK: ON" / "AFK: OFF"): returns the button and whether it is ON
        local function afkButton()
            local b = findButton(function(t) return t:find("^%s*afk%s*:") ~= nil end)
            if b and shown(b) then
                local t = textOfBtn(b)
                return b, (t:find("off", 1, true) == nil and t:find("on", 1, true) ~= nil)
            end
        end

        -- puts the AFK toggle in the wanted state (the dungeon cannot be left while AFK is ON)
        local function setAfk(want)
            for _ = 1, 3 do
                local b, on = afkButton()
                if not b then return false end
                if on == want then return true end
                activateButton(b)
                task.wait(0.5)
            end
            local b, on = afkButton()
            return b ~= nil and on == want
        end

        local function finish(why)
            if not Dungeon.active then return end
            Dungeon.active = false
            leaving = false
            Dungeon.lastEnd = os.clock()
            statusL.Text = "Dungeon: " .. why
            -- give the paused features their turn back (during a raid, the raid resumes everything itself)
            task.spawn(function()
                task.wait(1.5)
                if Raid.running or Dungeon.active then return end
                if Tower.auto and Tower.resume then Tower.resume() end
                if Boss.auto and Boss.resume then Boss.resume() end
            end)
        end

        local dungeonRemotes = {}
        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and r.Name:lower():find("dungeon", 1, true) then
                dungeonRemotes[#dungeonRemotes + 1] = r.Name
                r.OnClientEvent:Connect(function(...)
                    local args = {...}
                    local okJ, txt = pcall(function() return HttpService:JSONEncode(args) end)
                    txt = (okJ and txt or "(not serializable)"):lower()
                    local name = r.Name:lower()
                    local list = Seen.list
                    list[#list + 1] = { t = os.clock(), name = name, text = txt }
                    if #list > 40 then table.remove(list, 1) end
                    if CFG.DEBUG_TIMER then print("[PibbleHub] dungeon: server event", r.Name, txt:sub(1, 300)) end
                    -- server events only prove we are still inside: they NEVER end the dungeon.
                    -- The only ways out are: manual leave (detected below), the raid, or the Stop of Auto.
                    if Dungeon.active then lastSeenExit = os.clock() end
                end)
            end
        end
        print("[PibbleHub] dungeon remotes found: " .. (#dungeonRemotes > 0 and table.concat(dungeonRemotes, ", ") or "(none)"))

        -- a remote called *dungeon* whose name contains one of the words (or the exact name from the CFG)
        local function pickRemote(exact, words)
            if exact ~= "" then
                local r = R:FindFirstChild(exact, true)
                if r then return r end
            end
            for _, r in ipairs(R:GetDescendants()) do
                if r:IsA("RemoteEvent") then
                    local n = r.Name:lower()
                    if n:find("dungeon", 1, true) then
                        for _, w in ipairs(words) do
                            if n:find(w, 1, true) then return r end
                        end
                    end
                end
            end
        end

        local function pivotOf(o)
            if o:IsA("Model") then
                local okP, pv = pcall(function() return o:GetPivot() end)
                return okP and pv or nil
            elseif o:IsA("BasePart") then
                return o.CFrame
            end
        end

        -- ---- the dungeon NPC (Workspace.NPCs.DungeonNPC) ----
        local function dungeonNPC()
            local npcs = workspace:FindFirstChild("NPCs")
            local m = npcs and npcs:FindFirstChild(CFG.DUNGEON_NPC)
            if m then return m end
            for _, p in ipairs(workspace:GetDescendants()) do
                if p:IsA("ProximityPrompt") and tostring(p.ObjectText):lower():find("dungeon", 1, true) then
                    return p:FindFirstAncestorWhichIsA("Model") or p.Parent
                end
            end
        end

        -- teleports next to the NPC (goes to the lobby first when the NPC is not loaded)
        local function goToNPC()
            local askedLobby = false
            for i = 1, 60 do
                if Raid.running then return nil end
                local npc = dungeonNPC()
                local hrp = getHRP()
                local cf = npc and pivotOf(npc)
                if npc and hrp and cf then
                    hrp.CFrame = CFrame.new(cf.Position + cf.LookVector * 5 + Vector3.new(0, 2, 0))
                    task.wait(0.5)
                    return npc
                end
                if not npc and not askedLobby and i >= 4 and Remotes.Teleport then
                    askedLobby = true
                    statusL.Text = "Dungeon: going to lobby"
                    Remotes.Teleport:FireServer("lobby")
                end
                task.wait(0.25)
            end
            return nil
        end

        -- did the server react (a dungeon event) or did the character move (teleported inside)?
        local function waitAccepted(since, before)
            local t0 = os.clock()
            while os.clock() - t0 < CFG.DUNGEON_START_CHECK do
                if Raid.running then return false end
                for _, e in ipairs(Seen.list) do
                    if e.t >= since then return true end
                end
                local hrp = getHRP()
                if hrp and before and (hrp.Position - before).Magnitude > 100 then return true end
                task.wait(0.25)
            end
            return false
        end

        local function startViaRemote()
            local r = pickRemote(CFG.DUNGEON_START_REMOTE, {"start", "enter", "join", "begin", "queue"})
            if not r then return false end
            local hrp0 = getHRP()
            local since = os.clock()
            print("[PibbleHub] dungeon: firing remote " .. r.Name)
            r:FireServer(table.unpack(CFG.DUNGEON_ARGS))
            return waitAccepted(since, hrp0 and hrp0.Position)
        end

        local function startViaNPC()
            local npc = goToNPC()
            if not npc then return false end
            local prompt = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
            if not prompt then
                print("[PibbleHub] dungeon: no prompt on " .. npc:GetFullName())
                return false
            end
            local hrp0 = getHRP()
            local since = os.clock()
            if typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
            else
                pcall(function()
                    prompt:InputHoldBegin()
                    task.wait((prompt.HoldDuration or 0) + 0.1)
                    prompt:InputHoldEnd()
                end)
            end
            task.wait(0.8)
            -- debug: what the dialog shows
            if CFG.DEBUG_TIMER then
                local pg = player:FindFirstChild("PlayerGui")
                local out = {}
                if pg then
                    for _, b in ipairs(pg:GetDescendants()) do
                        if #out >= 15 then break end
                        if b:IsA("TextButton") and not b:IsDescendantOf(gui) and shown(b) and clean(b.Text):match("%S") then
                            out[#out + 1] = clean(b.Text)
                        end
                    end
                end
                print("[PibbleHub] dungeon: buttons after talking: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
            end
            -- the dialog shows a blue button "CONTINUE LAST RUN - STAGE 34 (3 LIVES)" (stage / lives change): wait for it, press it
            local b
            local t1 = os.clock()
            while os.clock() - t1 < 4 and not b do
                b = findButton(function(t) return t:find("continue last run", 1, true) ~= nil end)
                if b and not shown(b) then b = nil end
                if not b then task.wait(0.25) end
            end
            if not b then -- fallback: a "new run" / start button
                b = findButton(function(t)
                    return t:find("new run", 1, true) ~= nil or t:find("start run", 1, true) ~= nil
                        or t:find("start dungeon", 1, true) ~= nil or t:find("enter dungeon", 1, true) ~= nil
                end)
                if b and not shown(b) then b = nil end
            end
            if b then
                print("[PibbleHub] dungeon: pressed " .. btnText(b) .. " (" .. b:GetFullName() .. ")")
                activateButton(b)
            else
                print("[PibbleHub] dungeon: no start button found after talking to the NPC")
            end
            return waitAccepted(since, hrp0 and hrp0.Position)
        end

        local function startDungeon()
            for round = 1, CFG.DUNGEON_START_TRIES do
                if Raid.running then return false end
                statusL.Text = ("Dungeon: starting (%d/%d)"):format(round, CFG.DUNGEON_START_TRIES)
                if startViaRemote() then return true end
                if Raid.running then return false end
                if startViaNPC() then return true end
            end
            return false
        end

        -- ---- leaving ----
        -- opts.noTeleport = true: the caller teleports somewhere else right after (the raid does)
        local function leave(opts)
            opts = opts or {}
            if not Dungeon.active then return end
            statusL.Text = "Dungeon: leaving"
            leaving = true
            local done = false
            -- 0) the dungeon cannot be left while AFK is ON: turn it OFF first
            if setAfk(false) then
                print("[PibbleHub] dungeon: AFK turned OFF")
            else
                print("[PibbleHub] dungeon: AFK button not found / still ON (continuing anyway)")
            end
            -- 1) the game's own way: the "Exit" button (X), then "SAVE & LEAVE"
            local ex = findButton(function(t) return t == "exit" end)
            if ex and shown(ex) and activateButton(ex) then
                print("[PibbleHub] dungeon: pressed Exit " .. ex:GetFullName())
                local sl
                local t1 = os.clock()
                while os.clock() - t1 < 3 and not sl do
                    task.wait(0.25)
                    sl = findButton(function(t) return t:find("save", 1, true) ~= nil and t:find("leave", 1, true) ~= nil end)
                    if sl and not shown(sl) then sl = nil end
                end
                if sl and activateButton(sl) then
                    print("[PibbleHub] dungeon: pressed Save & Leave " .. sl:GetFullName())
                    done = true
                    task.wait(0.8)
                else
                    print("[PibbleHub] dungeon: Save & Leave button not found after Exit")
                end
            else
                print("[PibbleHub] dungeon: Exit button not found")
            end
            -- 2) fallbacks: a leave remote, then the lobby teleport
            if not done then
                local r = pickRemote(CFG.DUNGEON_LEAVE_REMOTE, {"leave", "exit", "quit", "abandon", "forfeit", "giveup"})
                if r then
                    print("[PibbleHub] dungeon: firing remote " .. r.Name)
                    r:FireServer(table.unpack(CFG.DUNGEON_LEAVE_ARGS))
                    task.wait(0.5)
                end
                if not opts.noTeleport and Remotes.Teleport then
                    Remotes.Teleport:FireServer("lobby")
                end
            end
            finish(opts.why and ("left (" .. opts.why .. ")") or "left")
        end
        Dungeon.leave = leave
        -- used by Auto Raid: AFK OFF whatever the state of the script (the raid teleport / Exit need it OFF)
        Dungeon.afkOff = function() return setAfk(false) end

        -- ---- one dungeon run ----
        local function runOnce()
            if Dungeon.active or Raid.running then return end
            Dungeon.active = true -- from now on Tower / Boss / Candy leave the player alone
            Dungeon.startedAt = os.clock()
            while Candy.busy and not Raid.running do task.wait(0.5) end
            if Raid.running then
                Dungeon.active = false
                return
            end
            if startDungeon() then
                Dungeon.startedAt = os.clock()
                lastSeenExit = os.clock()
                leaving = false
                statusL.Text = "Dungeon: running"
                -- once inside, turn AFK ON (the button shows up after the teleport / loading)
                task.spawn(function()
                    for _ = 1, 15 do
                        if not Dungeon.active or leaving then return end
                        local b, on = afkButton()
                        if b then
                            if not on then
                                setAfk(true)
                                print("[PibbleHub] dungeon: AFK turned ON")
                            end
                            return
                        end
                        task.wait(1)
                    end
                end)
            else
                Dungeon.active = false
                Dungeon.lastEnd = os.clock()
                if not Raid.running then
                    statusL.Text = "Dungeon: could not start (see F9)"
                    print("[PibbleHub] dungeon: could not start. Look at the 'dungeon: server event' / 'buttons after talking' lines,"
                        .. " then set CFG.DUNGEON_START_REMOTE / CFG.DUNGEON_ARGS.")
                    if Tower.auto and Tower.resume then Tower.resume() end
                    if Boss.auto and Boss.resume then Boss.resume() end
                end
            end
        end

        -- called by Auto Raid once the raid is over
        Dungeon.resume = function()
            Dungeon.lastEnd = -1e9 -- no cooldown: start again right away
        end

        local function setAuto(on)
            Dungeon.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Dungeon.setAuto = setAuto

        startBtn.MouseButton1Click:Connect(function() task.spawn(runOnce) end)
        autoBtn.MouseButton1Click:Connect(function()
            setAuto(not Dungeon.auto)
            -- turning Auto ON starts the dungeon right away, without any check (cooldown, boss / candy, raid window).
            -- Only a raid in progress or a dungeon already running prevents it (runOnce checks that itself).
            if Dungeon.auto then
                Dungeon.lastEnd = -1e9
                task.spawn(runOnce)
            end
        end)

        -- called by the BattleEnd router: returns true for the results of a dungeon fight
        Dungeon.onBattleEnd = function(data)
            local m = (tostring(data.mode or "") .. " " .. tostring(data.tower or "")):lower()
            if not m:find("dungeon", 1, true) then return false end
            logEnd("dungeon", data)
            -- a dungeon fight result never ends the run (the dungeon goes on stage after stage)
            if Dungeon.active then lastSeenExit = os.clock() end
            return true
        end

        -- every 2 s: timeout of a running dungeon + automatic start
        task.spawn(function()
            while gui.Parent do
                task.wait(2)
                if Dungeon.active then
                    if CFG.DUNGEON_TIMEOUT > 0 and not Raid.running and os.clock() - Dungeon.startedAt > CFG.DUNGEON_TIMEOUT then
                        leave({ why = "timeout" })
                    elseif not leaving and not Raid.running and os.clock() - Dungeon.startedAt > 15 then
                        -- did we leave the dungeon by hand? (no Exit button for a while, or back next to the dungeon NPC)
                        local ex = findButton(function(t) return t == "exit" end)
                        if ex and shown(ex) then lastSeenExit = os.clock() end
                        local npc = dungeonNPC()
                        local hrp, cf = getHRP(), nil
                        if npc then cf = pivotOf(npc) end
                        local nearNpc = hrp and cf and (cf.Position - hrp.Position).Magnitude < CFG.DUNGEON_NEAR_NPC
                        if nearNpc or os.clock() - lastSeenExit > CFG.DUNGEON_GONE_AFTER then
                            print("[PibbleHub] dungeon: left manually (" .. (nearNpc and "next to the NPC" or "no Exit button") .. ")")
                            finish("left manually")
                        else
                            -- still inside: keep AFK ON
                            local b, on = afkButton()
                            if b and not on then setAfk(true) end
                        end
                    end
                elseif Dungeon.auto and not Raid.running then
                    local raidOpen = Raid.isOpen and Raid.isOpen()
                    if raidOpen then
                        statusL.Text = "Dungeon: waiting (raid open)"
                    elseif Boss.active or (Boss.auto and not Boss.timerWait) or Candy.busy then
                        statusL.Text = "Dungeon: waiting (boss/candy)"
                    elseif os.clock() - Dungeon.lastEnd >= CFG.DUNGEON_COOLDOWN then
                        task.spawn(runOnce)
                    end
                end
            end
        end)
    end

    -- =====================================================================
    -- == 12. BATTLEEND ROUTER + RESTORE OF THE SAVED SWITCHES
    -- =====================================================================
    -- 1) a raid fight  2) a boss fight started by Auto Boss  3) a dungeon fight  4) the Infinite Tower  5) the Halloween Tower
    Remotes.BattleEnd.OnClientEvent:Connect(function(data)
        if type(data) ~= "table" then return end
        if Raid.onBattleEnd(data) then return end
        if Boss.onBattleEnd(data) then return end
        if Dungeon.onBattleEnd(data) then return end
        if Infinite.onBattleEnd(data) then return end
        Tower.onBattleEnd(data)
    end)

    -- Restore the Auto / Pop switches a few seconds after launch (the game needs to be loaded),
    -- then start saving. Saving only starts after the restore, so a click made during
    -- the delay cannot overwrite the saved state.
    task.delay(CFG.RESTORE_DELAY, function()
        if not gui.Parent then return end
        local d = Settings.data
        if d.autoCandy == true and not Candy.auto then Candy.setAuto(true) end
        if d.autoTower == true and not Tower.auto then Tower.startAuto() end
        if d.autoBoss == true and not Boss.auto then Boss.setAuto(true) end
        if d.autoRaid == true and not Raid.auto then Raid.setAuto(true) end
        if d.autoDungeon == true and not Dungeon.auto then Dungeon.setAuto(true) end
        if d.pop == true and not Infinite.on then Infinite.setPop(true) end
        Settings.armed = true
        Settings.save()
        print("[PibbleHub] loaded")
    end)
end

-- =========================================================================
-- == 13. START-UP + EMBEDDED ICON
-- =========================================================================
-- Puppy icon (base64 JPEG). It is written to a local file and loaded with getcustomasset.
-- Optional. To change the icon, replace ONLY the base64 text (the long line starting with /9j/) between the
-- two double brackets below. Left empty, the toggle button simply shows a "P" instead of the icon.
ICON_B64 = [[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
]]

local ok, err = xpcall(runHub, debug.traceback)

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
