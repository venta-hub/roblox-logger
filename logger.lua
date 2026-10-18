-- Join/Leave/Chat/Announcement Logger + Credits Viewer + Free Camera (v29, server version)
-- After the key is accepted, the Logger Panel opens (Right Ctrl hides/shows it unless you change
-- the key): put your own Discord webhooks in it (one box per log type), switch each channel on/off,
-- control the free camera, change keybinds, or terminate the whole script. Logs go through the Cloudflare Worker, which checks the key on every log and only
-- forwards to Discord webhook URLs, so without a valid key nothing gets sent.
local SERVER_URL = "https://logger.vanta-node-7.workers.dev" -- your Worker URL

print("[Logger] Starting...")

-- Re-executing the script stops the copy that's already running, so logs aren't sent twice
local genv = (getgenv and getgenv()) or _G
if genv.LoggerStop then
	pcall(genv.LoggerStop)
	print("[Logger] Stopped the previous copy.")
end
local alive = true
local conns = {}
local stopHooks = {}
local function track(conn)
	table.insert(conns, conn)
	return conn
end
-- runs fn when this copy is stopped (re-executed, terminated, or the key is removed)
local function onStop(fn)
	table.insert(stopHooks, fn)
end
-- stops everything this copy is doing and removes its windows, straight away
genv.LoggerStop = function()
	if not alive then return end
	alive = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)
	for _, fn in ipairs(stopHooks) do pcall(fn) end
	table.clear(stopHooks)
end

-- Executors often hide script errors from F9, so everything below runs inside main()
-- and any error is printed with a [Logger] tag instead of failing silently.
local function main()
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")
	local MarketplaceService = game:GetService("MarketplaceService")
	local TextChatService = game:GetService("TextChatService")

	local request = (syn and syn.request) or (http and http.request) or http_request or request
	if not request then
		warn("[Logger] Your executor doesn't support HTTP requests.")
		return
	end

	-- The moderation section below is shown to anyone whose key includes the logger (bundle or
	-- logger keys), since the Logger Panel itself only opens for those keys. It's a convenience
	-- gate on the UI; the actual kick only works if the game's server treats you as an admin,
	-- which the server checks.

	-- Sends a message into the game's chat, the same as typing it. Admin commands like "/kick name"
	-- go through here; the server decides whether to act on them.
	local function sendChat(message)
		local okNew = pcall(function()
			local channels = TextChatService:FindFirstChild("TextChannels")
			local general = channels and (channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildWhichIsA("TextChannel"))
			if not general then error("no channel") end
			general:SendAsync(message)
		end)
		if okNew then return true end
		-- older games still use the legacy chat system
		return pcall(function()
			game:GetService("ReplicatedStorage")
				.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(message, "All")
		end)
	end

	---------------------------------------------------------------- key system
	-- The logger only starts once the server accepts the key. The server also checks the key on
	-- every single log, so removing this check from the script doesn't help: logs without a valid
	-- key are refused. A key that works is saved, so it isn't asked for again.
	local KEY_FILE = "logger_key.txt"

	if SERVER_URL == "" then
		warn("[Logger] SERVER_URL is blank. Paste your Worker URL at the top of the script (see SETUP.md).")
		return
	end
	SERVER_URL = SERVER_URL:gsub("/+$", "")

	local function trim(s)
		return (s:match("^%s*(.-)%s*$"))
	end

	-- runs an HTTP request, giving up after 15 seconds so a stuck request can't freeze the script
	-- returns the response, or nil and a reason
	local function httpRequest(options)
		local done, ok, res = false, false, nil
		task.spawn(function()
			ok, res = pcall(request, options)
			done = true
		end)
		local start = os.clock()
		while not done and os.clock() - start < 15 do task.wait(0.1) end
		if not done then return nil, "no answer in time" end
		if not ok then return nil, tostring(res) end
		if not res or not res.StatusCode then return nil, "empty response" end
		return res
	end

	-- sends JSON to the server, returns (statusCode, decodedBody) or (nil)
	local function callServer(path, data)
		local res, reason = httpRequest({
			Url = SERVER_URL .. path,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(data),
		})
		if not res then
			warn("[Logger] Request to the key server failed (" .. path .. "):", reason)
			return nil
		end
		local okBody, body = pcall(function() return HttpService:JSONDecode(res.Body) end)
		return res.StatusCode, okBody and body or {}
	end

	-- For one-time keys the server hands out a session ID when the script starts; every later
	-- request has to carry it. (Normal keys don't use one.)
	local SESSION
	-- what the key unlocks, as told by the server: "bundle", "logger" or "credits"
	local PRODUCT = "bundle"

	-- starts a run with this key: returns (true) if it's valid, or (false, reason)
	local function checkKey(key)
		key = trim(key or "")
		if key == "" then return false, "Enter a key." end
		local status, body = callServer("/check", { key = key, userId = Players.LocalPlayer.UserId, start = true })
		if status == 200 then
			SESSION = body.session
			if body.product == "logger" or body.product == "credits" then PRODUCT = body.product end
			return true
		end
		if status == nil then return false, "Couldn't reach the key server. Try again." end
		return false, body.error or "Invalid key."
	end

	local function savedKey()
		local ok, key = pcall(function() return isfile and isfile(KEY_FILE) and readfile(KEY_FILE) end)
		return ok and key or nil
	end

	local function saveKey(key)
		pcall(function() if writefile then writefile(KEY_FILE, trim(key)) end end)
	end

	---------------------------------------------------------------- UI helpers
	local TweenService = game:GetService("TweenService")

	local function new(className, props)
		local obj = Instance.new(className)
		for k, v in pairs(props) do obj[k] = v end
		return obj
	end
	local function round(obj, r) new("UICorner", { CornerRadius = UDim.new(0, r), Parent = obj }) end

	-- Gives one button a high-end hover/press feel: a soft glow outline that fades in, and a
	-- springy scale "pop". The pop is skipped for buttons inside a list so it never nudges layout.
	local function hookButton(btn)
		if btn:GetAttribute("fxHooked") then return end
		btn:SetAttribute("fxHooked", true)
		local glow = new("UIStroke", {
			Color = Color3.fromRGB(175, 190, 225),
			Thickness = 0,
			Transparency = 0.1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = btn,
		})
		local scale
		if not (btn.Parent and btn.Parent:FindFirstChildOfClass("UIListLayout")) then
			scale = new("UIScale", { Parent = btn })
		end
		local hovering = false
		local function pop(s, style)
			if not scale then return end
			TweenService:Create(scale, TweenInfo.new(0.16, style or Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = s }):Play()
		end
		btn.MouseEnter:Connect(function()
			hovering = true
			TweenService:Create(glow, TweenInfo.new(0.14), { Thickness = 1.6 }):Play()
			pop(1.06)
		end)
		btn.MouseLeave:Connect(function()
			hovering = false
			TweenService:Create(glow, TweenInfo.new(0.18), { Thickness = 0 }):Play()
			pop(1, Enum.EasingStyle.Quad)
		end)
		btn.MouseButton1Down:Connect(function() pop(0.94, Enum.EasingStyle.Quad) end)
		btn.MouseButton1Up:Connect(function() pop(hovering and 1.06 or 1) end)
	end
	-- Hooks every button already in a window, and any added later (list rows, dropdowns, etc.).
	local function applyHoverFX(root)
		for _, obj in ipairs(root:GetDescendants()) do
			if obj:IsA("TextButton") or obj:IsA("ImageButton") then hookButton(obj) end
		end
		root.DescendantAdded:Connect(function(obj)
			if obj:IsA("TextButton") or obj:IsA("ImageButton") then task.defer(hookButton, obj) end
		end)
	end

	-- makes a ScreenGui, replacing one with the same name left over from an earlier run
	local function makeGui(name)
		local gui = Instance.new("ScreenGui")
		gui.Name = name
		gui.ResetOnSpawn = false
		local okParent = pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
		if not okParent or not gui.Parent then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end
		for _, old in ipairs(gui.Parent:GetChildren()) do
			if old ~= gui and old.Name == name then old:Destroy() end
		end
		applyHoverFX(gui) -- every window gets interactive buttons automatically
		return gui
	end

	local function shake(frame)
		local start = frame.Position
		for _, x in ipairs({ -8, 8, -5, 5, 0 }) do
			TweenService:Create(frame, TweenInfo.new(0.04), { Position = start + UDim2.fromOffset(x, 0) }):Play()
			task.wait(0.04)
		end
		frame.Position = start
	end

	local function askForKey()
		local gui = makeGui("LoggerKey")

		local frame = new("Frame", {
			Size = UDim2.fromOffset(320, 180),
			Position = UDim2.new(0.5, -160, 0.5, -90),
			BackgroundColor3 = Color3.fromRGB(6, 6, 9),
			Parent = gui,
		})
		round(frame, 14)
		new("UIStroke", { Color = Color3.fromRGB(74, 76, 90), Thickness = 1.5, Parent = frame })
		new("TextLabel", {
			Text = "Enter Key",
			Size = UDim2.new(1, -60, 0, 40),
			Position = UDim2.fromOffset(16, 8),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 17,
			TextColor3 = Color3.fromRGB(240, 240, 245),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = frame,
		})
		local close = new("TextButton", {
			Text = "X",
			Size = UDim2.fromOffset(30, 30),
			Position = UDim2.new(1, -40, 0, 13),
			BackgroundColor3 = Color3.fromRGB(22, 22, 28),
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = Color3.fromRGB(150, 150, 165),
			Parent = frame,
		})
		round(close, 8)
		local box = new("TextBox", {
			Text = "",
			PlaceholderText = "Paste your key here...",
			PlaceholderColor3 = Color3.fromRGB(150, 150, 165),
			ClearTextOnFocus = false,
			Size = UDim2.new(1, -32, 0, 38),
			Position = UDim2.fromOffset(16, 56),
			BackgroundColor3 = Color3.fromRGB(14, 14, 18),
			Font = Enum.Font.Gotham,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(240, 240, 245),
			Parent = frame,
		})
		round(box, 9)
		local submit = new("TextButton", {
			Text = "Unlock",
			Size = UDim2.new(1, -32, 0, 36),
			Position = UDim2.fromOffset(16, 104),
			BackgroundColor3 = Color3.fromRGB(205, 212, 228),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(14, 14, 18),
			Parent = frame,
		})
		round(submit, 9)
		local status = new("TextLabel", {
			Text = "",
			Size = UDim2.new(1, -32, 0, 24),
			Position = UDim2.fromOffset(16, 148),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(240, 90, 90),
			Parent = frame,
		})

		local result -- nil while waiting, then the accepted key, or false if closed
		local checking = false
		local function try()
			if checking then return end
			checking = true
			status.TextColor3 = Color3.fromRGB(150, 150, 165)
			status.Text = "Checking..."
			local valid, reason = checkKey(box.Text)
			if valid then
				saveKey(box.Text)
				status.TextColor3 = Color3.fromRGB(80, 220, 120)
				status.Text = "Key accepted!"
				task.wait(0.6)
				result = trim(box.Text)
			else
				status.TextColor3 = Color3.fromRGB(240, 90, 90)
				status.Text = reason
				shake(frame) -- little shake on a wrong key
			end
			checking = false
		end
		submit.MouseButton1Click:Connect(try)
		box.FocusLost:Connect(function(enter) if enter then try() end end)
		close.MouseButton1Click:Connect(function() result = false end)

		while result == nil and alive and gui.Parent do task.wait() end
		gui:Destroy()
		return result
	end

	local KEY
	local stored = savedKey()
	if stored and trim(stored) ~= "" then
		print("[Logger] Checking saved key...")
		local valid, reason = checkKey(stored)
		if valid then
			KEY = trim(stored)
		else
			warn("[Logger] Saved key wasn't accepted:", reason)
		end
	end
	if not KEY then
		print("[Logger] Waiting for a key in the key box...")
		KEY = askForKey()
	end
	if not KEY then
		warn("[Logger] No valid key entered, logger not started.")
		return
	end
	print("[Logger] Key accepted.")

	-- which parts of the script this key unlocks
	local HAS_LOGGER = PRODUCT == "bundle" or PRODUCT == "logger"
	local HAS_CREDITS = PRODUCT == "bundle" or PRODUCT == "credits"
	local HAS_FLY = PRODUCT == "bundle"
	local PRODUCT_NAMES = { bundle = "Bundle", logger = "Logger", credits = "Credits & Hours" }
	print("[Logger] " .. PRODUCT_NAMES[PRODUCT] .. " key: logger " .. (HAS_LOGGER and "on" or "off")
		.. ", credits window " .. (HAS_CREDITS and "on" or "off") .. ", free camera " .. (HAS_FLY and "on" or "off") .. ".")

	---------------------------------------------------------------- channels and settings
	-- Your Discord webhooks (one per log type) and the on/off toggles are set in the Logger Panel
	-- (built at the bottom of this script). Both are saved to files, so they're remembered next time.
	-- An empty Announcements box sends announcements to the chat channel.
	local WEBHOOK_FILE = "logger_webhooks.json"
	local SETTINGS_FILE = "logger_settings.json"
	local CHANNELS = {
		{ kind = "join", label = "Join logs" },
		{ kind = "leave", label = "Leave logs" },
		{ kind = "chat", label = "Chat logs" },
		{ kind = "announcement", label = "Announcements" },
	}
	local WEBHOOK_HOSTS = {
		["discord.com"] = true,
		["discordapp.com"] = true,
		["canary.discord.com"] = true,
		["ptb.discord.com"] = true,
	}

	local function isWebhook(url)
		local host = url:match("^https://([%w%.]+)/api/webhooks/%d+/[%w_%-]+$")
		return host ~= nil and WEBHOOK_HOSTS[host] == true
	end

	local function readJson(file)
		local ok, data = pcall(function()
			return isfile and isfile(file) and HttpService:JSONDecode(readfile(file))
		end)
		return (ok and type(data) == "table") and data or {}
	end

	local function writeJson(file, data)
		pcall(function() if writefile then writefile(file, HttpService:JSONEncode(data)) end end)
	end

	-- asks Discord whether the webhook exists; returns (true) or (false, reason)
	local function webhookWorks(url)
		local res, reason = httpRequest({ Url = url, Method = "GET" })
		if not res then return false, "couldn't reach Discord (" .. reason .. ")" end
		if res.StatusCode == 200 then return true end
		if res.StatusCode == 401 or res.StatusCode == 404 then return false, "that webhook was deleted or is wrong." end
		return false, "Discord said " .. res.StatusCode
	end

	-- urls[kind] = webhook URL; only valid-looking URLs are loaded
	local urls = {}
	for kind, url in pairs(readJson(WEBHOOK_FILE)) do
		if type(url) == "string" and isWebhook(url) then urls[kind] = url end
	end

	-- settings.enabled[kind] = false when that channel's toggle is off; settings.flyKey = key name
	local settings = readJson(SETTINGS_FILE)
	if type(settings.enabled) ~= "table" then settings.enabled = {} end
	-- keybinds (KeyCode names), all changeable in the Logger Panel
	local KEY_DEFAULTS = {
		panelKey = "RightControl",
		creditsKey = "LeftControl",
		flyKey = "P",
		flyForward = "W",
		flyBack = "S",
		flyLeft = "A",
		flyRight = "D",
		flyUp = "E",
		flyDown = "Q",
		flyFast = "LeftShift",
	}
	for name, default in pairs(KEY_DEFAULTS) do
		local value = settings[name]
		if type(value) ~= "string" or not pcall(function() return Enum.KeyCode[value] end) then
			settings[name] = default
		end
	end
	local function saveSettings() writeJson(SETTINGS_FILE, settings) end
	local function keyIs(input, name) return input.KeyCode.Name == settings[name] end
	-- true while the panel waits for you to press a new key, so that press doesn't also do something
	local keybinds = { listening = false }

	-- the webhook a log of this kind should go to right now, or nil if it's off / not set
	-- (always nil when the key doesn't include the logger, which switches all logging off)
	local function activeWebhook(kind)
		if not HAS_LOGGER then return nil end
		if settings.enabled[kind] == false then return nil end
		local url = urls[kind]
		if not url and kind == "announcement" then url = urls.chat end
		return url
	end

	local function describeChannels()
		local on = {}
		for _, channel in ipairs(CHANNELS) do
			if activeWebhook(channel.kind) then table.insert(on, channel.kind) end
		end
		return #on > 0 and table.concat(on, ", ") or "nothing (set webhooks in the Logger Panel)"
	end
	if HAS_LOGGER then print("[Logger] Logging to Discord:", describeChannels()) end

	local gameName = "Unknown"
	pcall(function()
		gameName = MarketplaceService:GetProductInfo(game.PlaceId).Name
	end)

	-- Saves each join/leave to a text file in your executor's workspace folder
	local LOG_FILE = "join_leave_log.txt"
	local function saveToFile(action, player)
		if not (writefile and appendfile and isfile) then return end
		local line = string.format("[%s] %s: %s (@%s) ID %d\n",
			os.date("%Y-%m-%d %H:%M:%S"), action, player.DisplayName, player.Name, player.UserId)
		pcall(function()
			if isfile(LOG_FILE) then appendfile(LOG_FILE, line) else writefile(LOG_FILE, line) end
		end)
	end

	-- Called when the server stops accepting the key (it was deleted, expired, or this account was
	-- removed from it): forgets the saved key and shuts the logger down.
	local function lostAccess(reason)
		if not alive then return end
		warn("[Logger] Access removed:", reason or "key no longer valid", "- logger stopped.")
		pcall(function() if delfile and isfile and isfile(KEY_FILE) then delfile(KEY_FILE) end end)
		genv.LoggerStop()
	end

	-- re-checks the key every minute, so removing access stops the script even if nothing is logged
	task.spawn(function()
		while alive do
			task.wait(60)
			if not alive then break end
			local status, body = callServer("/check", { key = KEY, userId = Players.LocalPlayer.UserId, session = SESSION })
			if status == 403 then lostAccess(body.error) end
		end
	end)

	-- kind is "join", "leave", "chat" or "announcement"; sent to that channel's webhook from the panel
	local function post(kind, payload)
		if not alive then return end
		local webhook = activeWebhook(kind)
		if not webhook then return end -- this log is off in the panel
		local status, body = callServer("/log", {
			key = KEY,
			userId = Players.LocalPlayer.UserId,
			kind = kind,
			webhook = webhook,
			payload = payload,
			session = SESSION,
		})
		if status == nil then
			warn("[Logger] Couldn't reach the server.")
		elseif status == 403 then
			lostAccess(body.error)
		elseif status >= 400 then
			warn("[Logger] Server refused the", kind, "log:", status, body.error or "")
		end
	end

	-- Records a moderation action or announcement into the shared ACTIONS feed on the server, so
	-- everyone running the logger in this game sees it in the panel. kind is "kick", "ban" or
	-- "announcement"; target is the affected player (blank for announcements); text is the message.
	-- Runs in its own thread so it never blocks the UI, and failures are quiet (the feed is a nicety).
	local function recordAction(kind, target, text)
		if not alive or not HAS_LOGGER then return end
		task.spawn(function()
			callServer("/action", {
				key = KEY,
				userId = Players.LocalPlayer.UserId,
				session = SESSION,
				placeId = game.PlaceId,
				game = gameName,
				kind = kind,
				moderator = Players.LocalPlayer.Name,
				moderatorDisplay = Players.LocalPlayer.DisplayName,
				target = target or "",
				text = text or "",
			})
		end)
	end

	-- Avatar headshots: looks up image URLs for any users we don't have yet (one request for all of them)
	local avatarCache = {}
	local function fetchAvatars(userIds)
		local missing = {}
		for id in pairs(userIds) do
			if not avatarCache[id] then table.insert(missing, id) end
		end
		if #missing == 0 then return end
		pcall(function()
			local res = request({
				Url = "https://thumbnails.roblox.com/v1/users/avatar-headshot?size=150x150&format=Png&userIds="
					.. table.concat(missing, ","),
				Method = "GET",
			})
			for _, thumb in ipairs(HttpService:JSONDecode(res.Body).data) do
				if thumb.state == "Completed" then
					avatarCache[thumb.targetId] = thumb.imageUrl
				end
			end
		end)
	end

	-- Builds the shared top part of every card: avatar + name linked to profile, big avatar on the right
	local function playerCard(title, color, userId, displayName, username)
		local profile = "https://www.roblox.com/users/" .. userId .. "/profile"
		local avatar = avatarCache[userId]
		return {
			title = title,
			color = color,
			author = { name = displayName .. " (@" .. username .. ")", url = profile, icon_url = avatar },
			thumbnail = avatar and { url = avatar } or nil,
			fields = {
				{ name = "Display Name", value = displayName, inline = true },
				{ name = "Username", value = username, inline = true },
				{ name = "User ID", value = tostring(userId), inline = true },
			},
			footer = { text = gameName .. " | JobId: " .. game.JobId },
		}, profile
	end

	local function send(kind, title, color, player)
		if not HAS_LOGGER then return end
		saveToFile(kind == "join" and "JOINED" or "LEFT", player)
		if not activeWebhook(kind) then return end
		fetchAvatars({ [player.UserId] = true })
		local embed, profile = playerCard(title, color, player.UserId, player.DisplayName, player.Name)
		table.insert(embed.fields, { name = "Account Age", value = player.AccountAge .. " days", inline = true })
		table.insert(embed.fields, { name = "Players In Server", value = tostring(#Players:GetPlayers()), inline = true })
		table.insert(embed.fields, { name = "Profile", value = profile })
		embed.timestamp = DateTime.now():ToIsoDate()
		post(kind, { embeds = { embed } })
	end

	track(Players.PlayerAdded:Connect(function(player)
		send("join", "Player Joined", 0x2ECC71, player)
	end))

	track(Players.PlayerRemoving:Connect(function(player)
		-- player count still includes the leaver at this point, so it's 1 higher
		send("leave", "Player Left", 0xE74C3C, player)
	end))

	-- Backslash Discord formatting characters so names like cool_guy_123 don't turn italic
	local function escape(text)
		return (text:gsub("[\\*_~`|>]", "\\%0"))
	end

	-- Returns (translatedText, languageCode), or nil if the message is already English or translation failed
	-- (uses Google Translate's free endpoint)
	local function translate(text)
		local ok, translated, lang = pcall(function()
			local res = request({
				Url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q="
					.. HttpService:UrlEncode(text),
				Method = "GET",
			})
			local data = HttpService:JSONDecode(res.Body)
			local parts = {}
			for _, chunk in ipairs(data[1]) do
				table.insert(parts, chunk[1])
			end
			return table.concat(parts), data[3]
		end)
		if not ok or type(lang) ~= "string" or lang:sub(1, 2) == "en" or translated == "" then return nil end
		if translated:lower() == text:lower() then return nil end -- names, emojis, "lol", etc.
		return translated, lang
	end

	-- Adds the "Message" field, plus original-language + English fields when it isn't English
	local function addMessageFields(embed, text)
		local translated, lang = translate(text)
		if translated then
			table.insert(embed.fields, { name = "Message (" .. lang .. ")", value = escape(text):sub(1, 1024) })
			table.insert(embed.fields, { name = "Translated (English)", value = escape(translated):sub(1, 1024) })
		else
			table.insert(embed.fields, { name = "Message", value = escape(text):sub(1, 1024) })
		end
	end

	-- Chat logs
	-- Each message gets its own card, styled like the join/leave ones.
	-- Cards are sent in batches every 3 seconds (up to 10 per post), because Discord
	-- limits how often a webhook can post and a busy chat would get messages dropped.
	do
		local chatQueue = {}

		track(TextChatService.MessageReceived:Connect(function(msg)
			if not activeWebhook("chat") then return end -- chat logs are off
			if not msg.TextSource then return end -- skip system messages
			if not msg.Text or msg.Text == "" then return end
			local userId = msg.TextSource.UserId
			local player = Players:GetPlayerByUserId(userId)
			table.insert(chatQueue, {
				userId = userId,
				displayName = player and player.DisplayName or msg.TextSource.Name,
				username = player and player.Name or msg.TextSource.Name,
				text = msg.Text,
				timestamp = DateTime.now():ToIsoDate(),
			})
		end))

		task.spawn(function()
			while alive do
				task.wait(3)
				if chatQueue[1] then
					local ok, err = pcall(function()
						local ids = {}
						for i = 1, math.min(#chatQueue, 10) do
							ids[chatQueue[i].userId] = true
						end
						fetchAvatars(ids)

						-- Discord allows 10 embeds and ~6000 characters per post; anything left waits for the next round
						local embeds, total = {}, 0
						while chatQueue[1] and #embeds < 10 do
							local m = chatQueue[1]
							local embed = playerCard("Chat", 0x3498DB, m.userId, m.displayName, m.username)
							embed.timestamp = m.timestamp
							addMessageFields(embed, m.text)

							local size = #embed.author.name + #embed.footer.text + #embed.title
							for _, field in ipairs(embed.fields) do
								size += #field.name + #field.value
							end
							if total + size > 5500 then break end
							total += size
							table.insert(embeds, embed)
							table.remove(chatQueue, 1)
						end
						post("chat", { embeds = embeds })
					end)
					if not ok then
						-- drop the message that caused the error so the log doesn't get stuck on it
						warn("[Logger] Chat log error:", err)
						table.remove(chatQueue, 1)
					end
				end
			end
		end)
	end

	-- Announcement logs
	-- Catches the on-screen "Message from <name>" popups (admin message commands) and logs
	-- who sent it and what it said. It reads the popup from your own screen, so you only
	-- catch announcements that are shown to you.
	-- (If the Announcements box is empty, these go to the chat channel instead.)
	do
		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
		local recent = {} -- stops the same popup getting logged twice
		local busy = setmetatable({}, { __mode = "k" })
		local watched = setmetatable({}, { __mode = "k" })

		local function isText(obj)
			return obj:IsA("TextLabel") or obj:IsA("TextBox") or obj:IsA("TextButton")
		end

		local function clean(text)
			return (text:gsub("<[^>]->", ""):match("^%s*(.-)%s*$"))
		end

		-- "Message from Xylryx" / "Message From @Xylryx:" / "Message from Xylryx (@xylryx)" -> "Xylryx"
		local function getSender(text)
			local name = clean(text):match("[Mm][Ee][Ss][Ss][Aa][Gg][Ee]%s+[Ff][Rr][Oo][Mm]%s+(.+)$")
			if not name then return nil end
			name = name:gsub("%s*%(.-%)%s*$", ""):gsub("^@", ""):gsub("[:%s]+$", "")
			return name ~= "" and name or nil
		end

		-- Finds the player in this server whose name is exactly the one in the popup.
		-- Nothing else is guessed: if nobody matches, the card just shows the popup's name.
		local function findSender(name)
			-- display names first, since that's what popups usually show
			local lower = name:lower()
			for _, p in ipairs(Players:GetPlayers()) do
				if p.DisplayName:lower() == lower then return p.UserId, p.DisplayName, p.Name end
			end
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name:lower() == lower then return p.UserId, p.DisplayName, p.Name end
			end
		end

		-- The message text is another label in the same popup: check the title's nearest
		-- containers first, moving outward, and take the longest text found there
		local function findBody(title)
			local container = title.Parent
			while container and container ~= playerGui do
				local best = ""
				for _, d in ipairs(container:GetDescendants()) do
					if d ~= title and isText(d) and d.Visible then
						local text = clean(d.Text)
						if #text > #best and not getSender(text) then best = text end
					end
				end
				if best ~= "" then return best end
				if container:IsA("LayerCollector") then break end
				container = container.Parent
			end
		end

		local function check(label)
			if not HAS_LOGGER then return end -- credits-only keys don't detect announcements
			if busy[label] then return end
			if not getSender(label.Text) then return end
			busy[label] = true

			-- wait until the popup has finished filling in (up to 6 seconds). The popup first shows
			-- a placeholder name and then switches to the real sender, so the name is read again
			-- at the end instead of using the first one seen.
			local body, last
			for _ = 1, 12 do
				task.wait(0.5)
				local now = label.Text .. "\0" .. (findBody(label) or "")
				body = findBody(label)
				if body and now == last then break end
				last = now
			end
			busy[label] = nil
			local senderName = getSender(label.Text)
			if not senderName then return end
			if not body then
				warn("[Logger] Saw an announcement from", senderName, "but couldn't find its message text.")
				return
			end

			local key = senderName .. "\0" .. body
			if recent[key] and os.clock() - recent[key] < 15 then return end
			recent[key] = os.clock()

			-- Always feed the shared ACTIONS panel, whether or not the Discord announcement channel is on.
			recordAction("announcement", senderName, body)

			-- The rest is the Discord card; skip it if that channel's toggle is off.
			if not activeWebhook("announcement") then return end
			-- The card's title is the sender's name exactly as the popup shows it ("Message from Xylryx").
			-- If that name belongs to someone in this server, their avatar, username and ID are added too.
			local title = "Message from " .. senderName
			local userId, displayName, username = findSender(senderName)
			print("[Logger] Announcement |", title, "| matched user ID:", userId or "none", "|", body)
			local embed
			if userId then
				fetchAvatars({ [userId] = true })
				embed = playerCard(title, 0xF1C40F, userId, displayName, username)
			else
				embed = {
					title = title,
					color = 0xF1C40F,
					author = { name = senderName },
					fields = {},
					footer = { text = gameName .. " | JobId: " .. game.JobId },
				}
			end
			table.insert(embed.fields, 1, { name = "From", value = escape(senderName) })
			addMessageFields(embed, body)
			embed.timestamp = DateTime.now():ToIsoDate()
			post("announcement", { embeds = { embed } })
		end

		local function watch(obj)
			if watched[obj] or not isText(obj) then return end
			watched[obj] = true
			task.spawn(check, obj)
			track(obj:GetPropertyChangedSignal("Text"):Connect(function()
				task.spawn(check, obj)
			end))
		end

		for _, obj in ipairs(playerGui:GetDescendants()) do
			watch(obj)
		end
		track(playerGui.DescendantAdded:Connect(watch))
	end

	---------------------------------------------------------------- credits viewer
	-- A window listing every player in the server and how many credits they have (this was
	-- credits.lua). Search to filter, click the sort button, click a player to copy their name,
	-- the credits key (Left Ctrl unless changed in the Logger Panel) or "X" hides it, the key shows
	-- it again, drag the corner to resize, "-" shrinks it to the title bar.
	local function startCreditsViewer()
		local Players = game:GetService("Players")
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local UserInputService = game:GetService("UserInputService")
		local TweenService = game:GetService("TweenService")

		local REFRESH = 2 -- seconds between updates
		local MIN_WIDTH, MIN_HEIGHT = 290, 260
		local MAX_WIDTH, MAX_HEIGHT = 900, 900

		local LocalPlayer = Players.LocalPlayer

		local THEME = {
			bg = Color3.fromRGB(6, 6, 9),
			panel = Color3.fromRGB(14, 14, 18),
			row = Color3.fromRGB(22, 22, 28),
			rowHover = Color3.fromRGB(32, 32, 40),
			stroke = Color3.fromRGB(74, 76, 90),
			text = Color3.fromRGB(240, 240, 245),
			subtext = Color3.fromRGB(150, 150, 165),
			accent = Color3.fromRGB(205, 212, 228), -- credit gold
			accent2 = Color3.fromRGB(150, 156, 172),
			you = Color3.fromRGB(90, 160, 255),
			up = Color3.fromRGB(80, 220, 120),
			down = Color3.fromRGB(240, 90, 90),
			warn = Color3.fromRGB(240, 180, 80),
		}
		local MEDALS = {
			Color3.fromRGB(255, 205, 60), -- 1st gold
			Color3.fromRGB(200, 205, 215), -- 2nd silver
			Color3.fromRGB(210, 140, 80), -- 3rd bronze
		}

		---------------------------------------------------------------- finding stats

		-- What the window can show; the tabs at the top switch between them. Neighbors keeps credits
		-- in a "Credits" attribute and playtime in leaderstats.Minutes. If those are missing, values
		-- whose name contains one of the keywords are used (case, spaces and _ ignored).
		local MODES = {
			{
				key = "credits",
				tab = "Credits",
				title = "Player Credits",
				unit = "credits",
				keywords = { "credit" }, -- "Credits", "TotalCredits", ...
			},
			{
				key = "hours",
				tab = "Hours played",
				title = "Hours Played",
				unit = "hours",
				keywords = { "hour", "playtime", "timeplayed", "minutesplayed", "secondsplayed" },
			},
		}
		local mode = MODES[1]

		local function matches(name)
			local simple = name:lower():gsub("[%s_]", "")
			for _, keyword in ipairs(mode.keywords) do
				if simple:find(keyword, 1, true) then return true end
			end
			return false
		end

		-- prints where each player's stat was found, once per player per tab
		local reported = {}
		local function report(player, where)
			reported[mode.key] = reported[mode.key] or {}
			if reported[mode.key][player] == where then return end
			reported[mode.key][player] = where
			print("[Stats]", mode.title .. ":", player.Name, "->", where)
		end

		-- shown instead of a number when a player has hidden their hours in the game's settings
		local HIDDEN = "Hidden"

		-- returns (value, name of the stat) for the current tab, or nil if the game doesn't send it
		local function findStat(player)
			if mode.key == "credits" then
				local credits = player:GetAttribute("Credits")
				if type(credits) == "number" then
					report(player, player:GetFullName() .. " attribute Credits")
					return credits, "Credits"
				end
			elseif mode.key == "hours" then
				local leaderstats = player:FindFirstChild("leaderstats")
				local minutes = leaderstats and leaderstats:FindFirstChild("Minutes")
				if minutes and minutes:IsA("ValueBase") and type(minutes.Value) == "number" then
					report(player, minutes:GetFullName())
					return minutes.Value, "Minutes"
				end
				-- players who turned on Hide Hours don't have their playtime sent at all
				if player:GetAttribute("HideHours") == true then return HIDDEN, "HideHours" end
			end

			-- otherwise search by name, but only for actual numbers
			-- 1. values inside the player (leaderstats, Data folders, etc.)
			for _, d in ipairs(player:GetDescendants()) do
				if d:IsA("ValueBase") and type(d.Value) == "number" and matches(d.Name) then
					report(player, d:GetFullName())
					return d.Value, d.Name
				end
			end
			-- 2. attributes on the player
			for name, value in pairs(player:GetAttributes()) do
				if type(value) == "number" and matches(name) then
					report(player, player:GetFullName() .. " attribute " .. name)
					return value, name
				end
			end
			-- 3. per-player folders elsewhere, named after the player or their user ID
			local id = tostring(player.UserId)
			for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
				if d:IsA("ValueBase") and type(d.Value) == "number" and matches(d.Name) then
					local parent = d.Parent
					while parent and parent ~= ReplicatedStorage do
						if parent.Name == player.Name or parent.Name == id then
							report(player, d:GetFullName())
							return d.Value, d.Name
						end
						parent = parent.Parent
					end
				end
			end
			return nil
		end

		-- playtime stats come in seconds, minutes or hours; the stat's name says which
		local function toHours(value, statName)
			local n = tonumber(value)
			if not n then return nil end
			local lower = statName:lower()
			if lower:find("hour") then return n end
			if lower:find("min") then return n / 60 end
			return n / 3600 -- "Playtime", "TimePlayed", "SecondsPlayed": games usually store seconds
		end

		-- the current tab's value for a player (hours are converted to hours), or nil
		local function readStat(player)
			local value, statName = findStat(player)
			if value == nil or value == HIDDEN then return value end
			if mode.key == "hours" then return toHours(value, statName) end
			return value
		end

		local function format(n)
			if type(n) ~= "number" then return tostring(n) end
			local s = tostring(math.floor(math.abs(n)))
			s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
			return (n < 0 and "-" or "") .. s
		end

		-- how a value looks in the current tab: "12,345" for credits, "3.5 h" for hours
		local function formatStat(n)
			if mode.key == "hours" and type(n) == "number" then
				return (n >= 100 and format(n) or string.format("%.1f", n)) .. " h"
			end
			return format(n)
		end

		---------------------------------------------------------------- ui helpers

		local function make(className, props, children)
			local obj = Instance.new(className)
			for k, v in pairs(props or {}) do
				if k ~= "Parent" then obj[k] = v end
			end
			for _, child in ipairs(children or {}) do
				child.Parent = obj
			end
			if props and props.Parent then obj.Parent = props.Parent end
			return obj
		end

		local function corner(radius)
			return make("UICorner", { CornerRadius = UDim.new(0, radius) })
		end

		local function stroke(color, thickness, transparency)
			return make("UIStroke", {
				Color = color,
				Thickness = thickness or 1,
				Transparency = transparency or 0,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			})
		end

		local function tween(obj, time, props)
			local t = TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
			t:Play()
			return t
		end

		---------------------------------------------------------------- window

		local gui = makeGui("CreditsViewer")
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		local WIDTH, HEIGHT, BAR = 340, 460, 52

		local frame = make("Frame", {
			Size = UDim2.fromOffset(WIDTH, HEIGHT),
			Position = UDim2.new(1, -WIDTH - 24, 0.5, -HEIGHT / 2),
			BackgroundColor3 = THEME.bg,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Parent = gui,
		}, { corner(14), stroke(THEME.stroke, 1.5) })
		local scale = make("UIScale", { Scale = 0.85, Parent = frame })

		-- title bar with a gold glow along the top
		local bar = make("Frame", {
			Size = UDim2.new(1, 0, 0, BAR),
			BackgroundColor3 = THEME.panel,
			BorderSizePixel = 0,
			Parent = frame,
		}, {
			corner(14),
			make("UIGradient", {
				Color = ColorSequence.new(Color3.fromRGB(40, 40, 50), THEME.panel),
				Rotation = 90,
			}),
		})
		-- square off the bar's bottom corners
		make("Frame", {
			Size = UDim2.new(1, 0, 0, 14),
			Position = UDim2.new(0, 0, 1, -14),
			BackgroundColor3 = THEME.panel,
			BorderSizePixel = 0,
			Parent = bar,
		})
		make("Frame", {
			Size = UDim2.new(1, 0, 0, 2),
			Position = UDim2.new(0, 0, 1, -2),
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = bar,
		}, {
			make("UIGradient", { Color = ColorSequence.new(THEME.accent, THEME.accent2) }),
		})

		local icon = make("TextLabel", {
			Text = "$",
			Size = UDim2.fromOffset(36, 36),
			Position = UDim2.fromOffset(10, 8),
			BackgroundColor3 = Color3.fromRGB(26, 26, 32),
			Font = Enum.Font.GothamBold,
			TextSize = 20,
			Parent = bar,
		}, { corner(10), stroke(THEME.accent, 1, 0.5) })

		local title = make("TextLabel", {
			Text = "Player Credits",
			Size = UDim2.new(1, HAS_LOGGER and -140 or -176, 0, 20),
			Position = UDim2.fromOffset(54, 9),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = THEME.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = bar,
		})
		local subtitle = make("TextLabel", {
			Text = "Loading...",
			Size = UDim2.new(1, HAS_LOGGER and -140 or -176, 0, 16),
			Position = UDim2.fromOffset(54, 28),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = THEME.subtext,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = bar,
		})

		local function barButton(text, x, hoverColor)
			local b = make("TextButton", {
				Text = text,
				Size = UDim2.fromOffset(30, 30),
				Position = UDim2.new(1, x, 0, 11),
				BackgroundColor3 = THEME.row,
				AutoButtonColor = false,
				Font = Enum.Font.GothamBold,
				TextSize = 16,
				TextColor3 = THEME.subtext,
				Parent = bar,
			}, { corner(8) })
			b.MouseEnter:Connect(function() tween(b, 0.15, { BackgroundColor3 = hoverColor, TextColor3 = THEME.text }) end)
			b.MouseLeave:Connect(function() tween(b, 0.15, { BackgroundColor3 = THEME.row, TextColor3 = THEME.subtext }) end)
			return b
		end
		local minimizeBtn = barButton("-", -76, THEME.rowHover)
		local closeBtn = barButton("X", -40, THEME.down)

		-- Credits-only keys don't get the Logger Panel, so this window has its own Terminate
		-- button (Off). It needs two clicks so it isn't hit by accident.
		if not HAS_LOGGER then
			local terminateBtn = barButton("Off", -112, THEME.down)
			local armed = false
			terminateBtn.MouseButton1Click:Connect(function()
				if not armed then
					armed = true
					terminateBtn.Text = "?"
					subtitle.Text = "Click Off again to terminate the script"
					task.delay(3, function()
						if armed and terminateBtn.Parent then
							armed = false
							terminateBtn.Text = "Off"
						end
					end)
					return
				end
				print("[Logger] Terminated. Run the loadstring to relaunch.")
				genv.LoggerStop()
				genv.LoggerStop = nil
			end)
		end

		-- body
		local body = make("Frame", {
			Size = UDim2.new(1, 0, 1, -BAR),
			Position = UDim2.fromOffset(0, BAR),
			BackgroundTransparency = 1,
			Parent = frame,
		})

		-- tabs: switch the numbers between credits and hours played
		local TOP = 54 -- everything below the tabs starts here
		local tabBar = make("Frame", {
			Size = UDim2.new(1, -24, 0, 32),
			Position = UDim2.fromOffset(12, 12),
			BackgroundColor3 = THEME.panel,
			Parent = body,
		}, {
			corner(9),
			stroke(THEME.stroke, 1),
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			make("UIPadding", {
				PaddingLeft = UDim.new(0, 3),
				PaddingRight = UDim.new(0, 3),
				PaddingTop = UDim.new(0, 3),
				PaddingBottom = UDim.new(0, 3),
			}),
		})
		local tabButtons = {}
		for i, m in ipairs(MODES) do
			tabButtons[m.key] = make("TextButton", {
				Text = m.tab,
				LayoutOrder = i,
				Size = UDim2.new(1 / #MODES, -4 * (#MODES - 1) / #MODES, 1, 0),
				BackgroundColor3 = THEME.panel,
				AutoButtonColor = false,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = THEME.subtext,
				Parent = tabBar,
			}, { corner(7) })
		end

		-- search box + sort button
		local searchHolder = make("Frame", {
			Size = UDim2.new(1, -126, 0, 34),
			Position = UDim2.fromOffset(12, TOP),
			BackgroundColor3 = THEME.panel,
			Parent = body,
		}, { corner(9) })
		local searchStroke = stroke(THEME.stroke, 1)
		searchStroke.Parent = searchHolder
		make("TextLabel", {
			Text = "",
			Size = UDim2.fromOffset(30, 34),
			BackgroundTransparency = 1,
			TextSize = 14,
			Font = Enum.Font.Gotham,
			Parent = searchHolder,
		})
		local search = make("TextBox", {
			Text = "",
			PlaceholderText = "Search player...",
			PlaceholderColor3 = THEME.subtext,
			Size = UDim2.new(1, -56, 1, 0),
			Position = UDim2.fromOffset(28, 0),
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = Enum.Font.Gotham,
			TextSize = 13,
			TextColor3 = THEME.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = searchHolder,
		})
		local clearBtn = make("TextButton", {
			Text = "X",
			Visible = false,
			Size = UDim2.fromOffset(26, 34),
			Position = UDim2.new(1, -26, 0, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = THEME.subtext,
			Parent = searchHolder,
		})
		search.Focused:Connect(function() tween(searchStroke, 0.15, { Color = THEME.accent }) end)
		search.FocusLost:Connect(function() tween(searchStroke, 0.15, { Color = THEME.stroke }) end)
		clearBtn.MouseButton1Click:Connect(function() search.Text = "" end)

		local SORTS = {
			{ label = "Most", key = "most" },
			{ label = "Least", key = "least" },
			{ label = "A-Z", key = "name" },
		}
		local sortIndex = 1
		local sortBtn = make("TextButton", {
			Text = SORTS[1].label,
			Size = UDim2.fromOffset(94, 34),
			Position = UDim2.new(1, -106, 0, TOP),
			BackgroundColor3 = THEME.panel,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = THEME.accent,
			Parent = body,
		}, { corner(9), stroke(THEME.stroke, 1) })
		sortBtn.MouseEnter:Connect(function() tween(sortBtn, 0.15, { BackgroundColor3 = THEME.rowHover }) end)
		sortBtn.MouseLeave:Connect(function() tween(sortBtn, 0.15, { BackgroundColor3 = THEME.panel }) end)

		-- player list
		local list = make("ScrollingFrame", {
			Size = UDim2.new(1, -16, 1, -(TOP + 80)),
			Position = UDim2.fromOffset(12, TOP + 44),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = THEME.stroke,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			Parent = body,
		}, {
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
			make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6) }),
		})

		local emptyLabel = make("TextLabel", {
			Text = "",
			Visible = false,
			Size = UDim2.new(1, 0, 0, 60),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 13,
			TextColor3 = THEME.subtext,
			TextWrapped = true,
			LayoutOrder = 100000,
			Parent = list,
		})

		-- footer
		local footer = make("TextLabel", {
			Text = "Click a player to copy their name",
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, -24, 0, 24),
			Position = UDim2.new(0, 12, 1, -30),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = THEME.subtext,
			Parent = body,
		})
		local footerDefault = footer.Text
		local footerToken = 0
		local function flashFooter(text, color)
			footerToken += 1
			local token = footerToken
			footer.Text, footer.TextColor3 = text, color
			task.delay(1.6, function()
				if footerToken == token then
					footer.Text, footer.TextColor3 = footerDefault, THEME.subtext
				end
			end)
		end

		---------------------------------------------------------------- player rows

		local rows = {} -- [player] = { frame, credits label, rank label, last value }

		local function makeRow(player)
			local isYou = player == LocalPlayer
			local card = make("TextButton", {
				Text = "",
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, 52),
				BackgroundColor3 = THEME.row,
				Parent = list,
			}, { corner(10) })
			local cardStroke = stroke(isYou and THEME.you or THEME.stroke, 1, isYou and 0.2 or 0.6)
			cardStroke.Parent = card

			local rank = make("TextLabel", {
				Text = "",
				Size = UDim2.fromOffset(28, 52),
				Position = UDim2.fromOffset(4, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = THEME.subtext,
				Parent = card,
			})

			local avatarRing = make("Frame", {
				Size = UDim2.fromOffset(38, 38),
				Position = UDim2.fromOffset(34, 7),
				BackgroundColor3 = THEME.panel,
				Parent = card,
			}, { corner(19) })
			local ringStroke = stroke(THEME.stroke, 2)
			ringStroke.Parent = avatarRing
			make("ImageLabel", {
				Image = "rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Parent = avatarRing,
			}, { corner(19) })

			make("TextLabel", {
				Text = player.DisplayName .. (isYou and "  (you)" or ""),
				Size = UDim2.new(1, -190, 0, 18),
				Position = UDim2.fromOffset(80, 9),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = isYou and THEME.you or THEME.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = card,
			})
			make("TextLabel", {
				Text = "@" .. player.Name,
				Size = UDim2.new(1, -190, 0, 14),
				Position = UDim2.fromOffset(80, 28),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = THEME.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = card,
			})

			local pill = make("Frame", {
				Size = UDim2.fromOffset(100, 28),
				Position = UDim2.new(1, -108, 0.5, -14),
				BackgroundColor3 = Color3.fromRGB(26, 26, 32),
				Parent = card,
			}, { corner(14), stroke(THEME.accent, 1, 0.6) })
			local creditsLabel = make("TextLabel", {
				Text = "...",
				Size = UDim2.new(1, -12, 1, 0),
				Position = UDim2.fromOffset(6, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = THEME.accent,
				TextScaled = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = pill,
			})

			card.MouseEnter:Connect(function() tween(card, 0.15, { BackgroundColor3 = THEME.rowHover }) end)
			card.MouseLeave:Connect(function() tween(card, 0.15, { BackgroundColor3 = THEME.row }) end)
			card.MouseButton1Click:Connect(function()
				if setclipboard then
					setclipboard(player.Name)
					flashFooter("Copied @" .. player.Name, THEME.up)
				else
					flashFooter("Your executor can't copy to clipboard", THEME.warn)
				end
				tween(card, 0.08, { BackgroundColor3 = THEME.accent }).Completed:Connect(function()
					tween(card, 0.3, { BackgroundColor3 = THEME.row })
				end)
			end)

			local row = { card = card, credits = creditsLabel, pill = pill, rank = rank, ring = ringStroke, value = nil }
			rows[player] = row
			return row
		end

		track(Players.PlayerRemoving:Connect(function(player)
			local row = rows[player]
			if row then
				rows[player] = nil
				row.card:Destroy()
			end
		end))

		---------------------------------------------------------------- refresh

		local running = true

		-- rescan = look the stat up again (every 2 seconds); typing/sorting just reuses the last values
		local function refresh(rescan)
			local query = search.Text:lower():match("^%s*(.-)%s*$")
			clearBtn.Visible = search.Text ~= ""

			local all, shown, unknown, total = {}, 0, 0, 0
			for _, player in ipairs(Players:GetPlayers()) do
				local row = rows[player] or makeRow(player)
				local value = row.value
				if rescan or value == nil then value = readStat(player) end
				local number = tonumber(value)

				-- flash green/red when someone's number changes
				if row.value ~= nil and number and tonumber(row.value) and number ~= tonumber(row.value) then
					local color = number > tonumber(row.value) and THEME.up or THEME.down
					row.credits.TextColor3 = color
					tween(row.credits, 1.2, { TextColor3 = THEME.accent })
				end
				row.value = value
				row.credits.Text = value == nil and "?" or formatStat(value)

				if value == nil then unknown += 1 else total += number or 0 end
				table.insert(all, { player = player, row = row, n = number })
			end

			-- ranks always go by the highest number, whatever the sort order
			table.sort(all, function(a, b) return (a.n or -math.huge) > (b.n or -math.huge) end)
			for i, entry in ipairs(all) do
				local medal = entry.n and MEDALS[i]
				entry.row.rank.Text = entry.n and ("#" .. i) or "-"
				entry.row.rank.TextColor3 = medal or THEME.subtext
				entry.row.ring.Color = medal or THEME.stroke
			end

			local sortKey = SORTS[sortIndex].key
			table.sort(all, function(a, b)
				if sortKey == "name" then
					return a.player.DisplayName:lower() < b.player.DisplayName:lower()
				elseif sortKey == "least" then
					return (a.n or math.huge) < (b.n or math.huge)
				end
				return (a.n or -math.huge) > (b.n or -math.huge)
			end)

			for i, entry in ipairs(all) do
				local p = entry.player
				local visible = query == ""
					or p.DisplayName:lower():find(query, 1, true) ~= nil
					or p.Name:lower():find(query, 1, true) ~= nil
				entry.row.card.Visible = visible
				entry.row.card.LayoutOrder = i
				if visible then shown += 1 end
			end

			local count = #all
			subtitle.Text = string.format("%d player%s  -  %s total", count, count == 1 and "" or "s",
				mode.key == "hours" and formatStat(total) or (format(total) .. " " .. mode.unit))

			if shown == 0 and query ~= "" then
				emptyLabel.Text = "No players match \"" .. search.Text .. "\""
				emptyLabel.TextColor3 = THEME.subtext
				emptyLabel.Visible = true
			elseif count > 0 and unknown == count then
				emptyLabel.Text = "Couldn't find " .. mode.unit .. " for anyone.\nThe game may not send them to your client."
				emptyLabel.TextColor3 = THEME.warn
				emptyLabel.Visible = true
			else
				emptyLabel.Visible = false
			end
		end

		search:GetPropertyChangedSignal("Text"):Connect(function()
			if running then refresh() end
		end)
		sortBtn.MouseButton1Click:Connect(function()
			sortIndex = sortIndex % #SORTS + 1
			sortBtn.Text = SORTS[sortIndex].label
			refresh()
		end)

		-- switching tabs: highlight the chosen one, forget the old numbers and look the new stat up
		local function setMode(newMode)
			mode = newMode
			for key, button in pairs(tabButtons) do
				local selected = key == mode.key
				tween(button, 0.15, {
					BackgroundColor3 = selected and THEME.accent or THEME.panel,
					TextColor3 = selected and Color3.fromRGB(14, 14, 18) or THEME.subtext,
				})
			end
			title.Text = mode.title
			icon.Text = mode.key == "hours" and "H" or "$"
			for _, row in pairs(rows) do row.value = nil end -- no green/red flash when switching
			refresh(true)
		end
		for _, m in ipairs(MODES) do
			tabButtons[m.key].MouseButton1Click:Connect(function()
				if m ~= mode then setMode(m) end
			end)
		end


		---------------------------------------------------------------- window controls

		-- drag by the title bar
		local dragging, dragStart, startPos
		bar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, dragStart, startPos = true, input.Position, frame.Position
			end
		end)
		track(UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))

		-- resize by dragging the grip in the bottom-right corner
		local grip = make("TextButton", {
			Text = "/",
			Size = UDim2.fromOffset(22, 22),
			Position = UDim2.new(1, -22, 1, -22),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = THEME.stroke,
			ZIndex = 10,
			Parent = frame,
		})
		grip.MouseEnter:Connect(function() tween(grip, 0.15, { TextColor3 = THEME.accent }) end)
		grip.MouseLeave:Connect(function() tween(grip, 0.15, { TextColor3 = THEME.stroke }) end)

		local resizing, resizeStart, startSize
		grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing, resizeStart, startSize = true, input.Position, Vector2.new(WIDTH, HEIGHT)
			end
		end)
		track(UserInputService.InputChanged:Connect(function(input)
			if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - resizeStart
				WIDTH = math.clamp(startSize.X + delta.X, MIN_WIDTH, MAX_WIDTH)
				HEIGHT = math.clamp(startSize.Y + delta.Y, MIN_HEIGHT, MAX_HEIGHT)
				frame.Size = UDim2.fromOffset(WIDTH, HEIGHT)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing = false
			end
		end))

		local minimized = false
		minimizeBtn.MouseButton1Click:Connect(function()
			minimized = not minimized
			minimizeBtn.Text = minimized and "+" or "-"
			grip.Visible = not minimized
			tween(frame, 0.3, { Size = UDim2.fromOffset(WIDTH, minimized and BAR or HEIGHT) })
		end)

		local shownWindow = true
		local function setShown(show)
			shownWindow = show
			if show then
				frame.Visible = true
				scale.Scale = 0.85
				tween(scale, 0.25, { Scale = 1 })
			else
				tween(scale, 0.15, { Scale = 0.85 }).Completed:Connect(function()
					if not shownWindow then frame.Visible = false end
				end)
			end
		end

		-- the credits key (Left Ctrl unless changed in the Logger Panel) hides and shows the window
		track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or keybinds.listening then return end
			if keyIs(input, "creditsKey") then setShown(not shownWindow) end
		end))

		-- X hides the window; the credits key brings it back
		closeBtn.MouseButton1Click:Connect(function()
			setShown(false)
			print("[Logger] Credits window hidden. Press " .. settings.creditsKey .. " to bring it back.")
		end)

		-- terminating, re-executing or losing the key removes the window
		onStop(function()
			running = false
			gui:Destroy()
		end)

		---------------------------------------------------------------- start

		setMode(MODES[1]) -- start on the Credits tab
		setShown(true)
		while running and alive do
			if shownWindow then refresh(true) end -- no need to scan while it's hidden
			task.wait(REFRESH)
		end
	end
	if HAS_CREDITS then
		task.spawn(function()
			local ok, err = xpcall(startCreditsViewer, debug.traceback)
			if not ok then warn("[Logger] Credits viewer crashed: " .. tostring(err)) end
		end)
	end

	---------------------------------------------------------------- free camera
	-- Press the fly key (P unless you change it in the Logger Panel) or use the panel's Fly toggle
	-- to fly the camera anywhere on the map while your character stays put.
	-- WASD to move, E up, Q down (all changeable in the panel), hold right mouse to look around,
	-- Shift to go faster, scroll to change speed, fly key again to snap back to your character.
	local freecam = {
		onChange = nil, -- the panel sets this so its Fly toggle follows the key
	}
	do
		local RunService = game:GetService("RunService")
		local UserInputService = game:GetService("UserInputService")
		local ContextActionService = game:GetService("ContextActionService")

		local LOOK_SPEED = 0.005 -- radians per pixel of mouse movement
		-- the fly controls (all changeable in the Logger Panel's keybinds)
		local FLY_CONTROLS = { "flyForward", "flyBack", "flyLeft", "flyRight", "flyUp", "flyDown", "flyFast" }
		-- Roblox's own walk/jump keys, swallowed while flying so your character stays still
		local CHARACTER_KEYS = {
			Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space,
			Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
		}

		local flying = false
		local speed = 40 -- studs per second
		local position, pitch, yaw
		local saved -- the camera settings to put back afterwards

		-- is the key set for this fly control held down? Always no while you're typing in chat or
		-- any text box, so typing doesn't move the camera
		local function down(control)
			if UserInputService:GetFocusedTextBox() then return false end
			return UserInputService:IsKeyDown(Enum.KeyCode[settings[control]])
		end

		-- swallows the character keys plus the current fly keys, so nothing else reacts to them
		local function sinkKeys()
			ContextActionService:UnbindAction("LoggerFreecam")
			local keys = table.clone(CHARACTER_KEYS)
			for _, control in ipairs(FLY_CONTROLS) do
				table.insert(keys, Enum.KeyCode[settings[control]])
			end
			ContextActionService:BindActionAtPriority("LoggerFreecam", function()
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value + 1, table.unpack(keys))
		end

		local function update(dt)
			local camera = workspace.CurrentCamera
			if not alive or not camera then return end

			-- look around while the right mouse button is held
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
				local delta = UserInputService:GetMouseDelta()
				yaw -= delta.X * LOOK_SPEED
				pitch = math.clamp(pitch - delta.Y * LOOK_SPEED, -1.55, 1.55)
			else
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end

			local move = Vector3.zero
			if down("flyForward") then move += Vector3.new(0, 0, -1) end
			if down("flyBack") then move += Vector3.new(0, 0, 1) end
			if down("flyLeft") then move += Vector3.new(-1, 0, 0) end
			if down("flyRight") then move += Vector3.new(1, 0, 0) end
			local rise = 0
			if down("flyUp") then rise += 1 end
			if down("flyDown") then rise -= 1 end

			local rotation = CFrame.fromOrientation(pitch, yaw, 0)
			local velocity = rotation:VectorToWorldSpace(move) + Vector3.new(0, rise, 0)
			if velocity.Magnitude > 0 then
				local boost = down("flyFast") and 3 or 1
				position += velocity.Unit * speed * boost * dt
			end

			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.new(position) * rotation
		end

		local function stopFlying()
			if not flying then return end
			flying = false
			RunService:UnbindFromRenderStep("LoggerFreecam")
			ContextActionService:UnbindAction("LoggerFreecam")
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			local camera = workspace.CurrentCamera
			if camera and saved then
				camera.CameraType = saved.type
				camera.CameraSubject = saved.subject
				camera.CFrame = saved.cframe
			end
		end

		local function startFlying()
			local camera = workspace.CurrentCamera
			if flying or not camera then return end
			flying = true
			saved = { type = camera.CameraType, subject = camera.CameraSubject, cframe = camera.CFrame }
			position = camera.CFrame.Position
			pitch, yaw = camera.CFrame:ToOrientation()
			sinkKeys()
			RunService:BindToRenderStep("LoggerFreecam", Enum.RenderPriority.Camera.Value + 1, update)
		end

		function freecam.set(on)
			if on and not HAS_FLY then return end -- only bundle keys include the free camera
			if on then startFlying() else stopFlying() end
			if freecam.onChange then freecam.onChange(flying) end
		end
		function freecam.isOn() return flying end

		-- Finds a player in this server by the start of their username or display name.
		-- Returns the player, or nil and a reason.
		function freecam.findPlayer(text)
			local query = trim(text or ""):lower():gsub("^@", "")
			if query == "" then return nil, "Type a player's name." end
			local exact, partial = nil, {}
			for _, p in ipairs(Players:GetPlayers()) do
				local name, display = p.Name:lower(), p.DisplayName:lower()
				if name == query or display == query then
					exact = p
					break
				end
				if name:sub(1, #query) == query or display:sub(1, #query) == query then
					table.insert(partial, p)
				end
			end
			if exact then return exact end
			if #partial == 1 then return partial[1] end
			if #partial > 1 then return nil, #partial .. " players match \"" .. query .. "\". Type more of the name." end
			return nil, "No player in this server matches \"" .. query .. "\"."
		end

		-- Flies the camera to a player (starting free camera if it's off), just behind and above them,
		-- looking at them. Returns true, or false and a reason.
		function freecam.goTo(player)
			if not HAS_FLY then return false, "Your key doesn't include the free camera." end
			local character = player.Character
			local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
			if not root then return false, player.DisplayName .. " hasn't loaded in yet." end
			if not flying then freecam.set(true) end
			if not flying then return false, "Couldn't start the free camera." end
			local target = root.Position
			local behind = root.CFrame.LookVector * -12 -- 12 studs behind them
			position = target + Vector3.new(behind.X, 6, behind.Z)
			pitch, yaw = CFrame.lookAt(position, target):ToOrientation()
			return true
		end
		-- called when a fly key is changed in the panel, so it works straight away mid-flight
		function freecam.keysChanged()
			if flying then sinkKeys() end
		end

		track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or not alive or keybinds.listening then return end -- ignore chat typing
			if HAS_FLY and keyIs(input, "flyKey") then
				freecam.set(not flying)
			end
		end))
		-- scroll wheel changes fly speed
		track(UserInputService.InputChanged:Connect(function(input)
			if flying and input.UserInputType == Enum.UserInputType.MouseWheel then
				speed = math.clamp(speed * (input.Position.Z > 0 and 1.25 or 0.8), 5, 500)
			end
		end))
		-- terminating, re-executing or losing the key puts the camera back
		onStop(stopFlying)
		if HAS_FLY then
			print("[Logger] Free camera ready: press " .. settings.flyKey .. " to fly, again to come back.")
		end
	end

	---------------------------------------------------------------- logger panel
	-- One window for your settings: a webhook box and an on/off toggle for each log channel, plus
	-- the free camera's toggle and key. Drag the title bar to move it, drag the bottom-right corner
	-- to make it bigger or smaller, the panel key (Right Ctrl unless changed) hides it and brings it
	-- back (X hides it too). Keybinds can be changed here, and Terminate stops the whole script.
	-- Only keys that include the logger get this panel (credits-only keys just get Player Credits).
	if HAS_LOGGER then
		local UserInputService = game:GetService("UserInputService")
		local MIN_W, MIN_H, MAX_W, MAX_H = 300, 160, 900, 900
		local W, H, BAR = 484, 560, 54
		local C = {
			bg = Color3.fromRGB(6, 6, 9),
			panel = Color3.fromRGB(14, 14, 18),
			row = Color3.fromRGB(22, 22, 28),
			stroke = Color3.fromRGB(74, 76, 90),
			text = Color3.fromRGB(240, 240, 245),
			subtext = Color3.fromRGB(150, 150, 165),
			accent = Color3.fromRGB(205, 212, 228),
			on = Color3.fromRGB(80, 200, 120),
			off = Color3.fromRGB(70, 70, 86),
			bad = Color3.fromRGB(240, 90, 90),
		}

		local gui = makeGui("LoggerPanel")
		local frame = new("Frame", {
			Size = UDim2.fromOffset(W, H),
			Position = UDim2.new(0, 24, 0.5, -H / 2),
			BackgroundColor3 = C.bg,
			BackgroundTransparency = 1, -- the wave backdrop below is the real fill, so it isn't hidden
			ClipsDescendants = true,
			Parent = gui,
		})
		round(frame, 14)
		new("UIStroke", { Color = C.stroke, Thickness = 1.5, Parent = frame })

		-- real obsidian water texture that slowly drifts, a soft light that follows the cursor, and
		-- a ripple that expands from wherever you click: the water reacts to the mouse.
		do
			local UIS = game:GetService("UserInputService")
			local RunService = game:GetService("RunService")
			local guiInset = game:GetService("GuiService"):GetGuiInset()
			local backdrop = new("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				BorderSizePixel = 0,
				ZIndex = 0,
				ClipsDescendants = true,
				Parent = frame,
			})
			round(backdrop, 14)
			-- animated dark water gradient: the base layer, and a graceful fallback if the photo
			-- can't load (e.g. the number is a Decal id rather than the underlying Image id)
			local baseGrad = new("UIGradient", {
				Rotation = 100,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0.00, Color3.fromRGB(8, 9, 13)),
					ColorSequenceKeypoint.new(0.22, Color3.fromRGB(30, 36, 50)),
					ColorSequenceKeypoint.new(0.46, Color3.fromRGB(10, 12, 17)),
					ColorSequenceKeypoint.new(0.68, Color3.fromRGB(26, 32, 45)),
					ColorSequenceKeypoint.new(0.88, Color3.fromRGB(34, 40, 55)),
					ColorSequenceKeypoint.new(1.00, Color3.fromRGB(8, 9, 13)),
				}),
				Parent = backdrop,
			})
			TweenService:Create(baseGrad, TweenInfo.new(14, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
				Offset = Vector2.new(0, 1),
			}):Play()
			-- extra drifting gradient layers over the base; overlapping at different angles/speeds
			-- they interfere into a shifting dark texture that reads as moving obsidian water
			local function waterLayer(rotation, speed, dir, trans, crest)
				local layer = new("Frame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Color3.fromRGB(255, 255, 255),
					BackgroundTransparency = trans,
					BorderSizePixel = 0,
					ZIndex = 0,
					Parent = backdrop,
				})
				round(layer, 14)
				local g = new("UIGradient", {
					Rotation = rotation,
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0.00, Color3.fromRGB(5, 6, 9)),
						ColorSequenceKeypoint.new(0.25, crest),
						ColorSequenceKeypoint.new(0.50, Color3.fromRGB(5, 6, 9)),
						ColorSequenceKeypoint.new(0.75, crest),
						ColorSequenceKeypoint.new(1.00, Color3.fromRGB(5, 6, 9)),
					}),
					Parent = layer,
				})
				TweenService:Create(g, TweenInfo.new(speed, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
					Offset = Vector2.new(0, dir),
				}):Play()
			end
			waterLayer(92, 13, 1, 0.35, Color3.fromRGB(32, 38, 52))
			waterLayer(107, 19, -1, 0.5, Color3.fromRGB(24, 30, 44))
			-- The REAL water photo, shown for everyone: downloaded from the repo into the executor's
			-- folder once, then loaded locally (getcustomasset), which bypasses Roblox asset
			-- permissions. If an executor can't do this, the procedural water above stays instead.
			local water = new("ImageLabel", {
				Size = UDim2.fromScale(1.18, 1.18),
				Position = UDim2.fromScale(-0.09, -0.09),
				BackgroundTransparency = 1,
				ImageTransparency = 1,
				-- Tile zooms the texture out (natural scale, not a blown-up crop) and fills the whole
				-- panel with more water; keeps the image sharp since it isn't being upscaled.
				ScaleType = Enum.ScaleType.Tile,
				TileSize = UDim2.fromOffset(300, 200),
				ZIndex = 0,
				Parent = backdrop,
			})
			TweenService:Create(water, TweenInfo.new(20, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
				Position = UDim2.fromScale(-0.03, -0.02),
			}):Play()
			-- light veil so panel text stays legible over the photo
			new("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(0, 0, 0),
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				ZIndex = 0,
				Parent = backdrop,
			})
			task.spawn(function()
				local ok, asset = pcall(function()
					local loadAsset = getcustomasset or getsynasset or (syn and syn.getcustomasset)
					if not (writefile and loadAsset) then return nil end
					local file = "venta_obsidian_water.png"
					if not (isfile and isfile(file)) then
						writefile(file, game:HttpGet("https://raw.githubusercontent.com/venta-hub/roblox-logger/main/water.png"))
					end
					return loadAsset(file)
				end)
				if ok and asset and water and water.Parent then
					water.Image = asset
					water.ImageTransparency = 0
				end
			end)
			local function within(v)
				local p, s = backdrop.AbsolutePosition, backdrop.AbsoluteSize
				return v.X >= p.X and v.X <= p.X + s.X and v.Y >= p.Y and v.Y <= p.Y + s.Y
			end
			-- one expanding, fading ring = a disturbance spreading across the water
			local function spawnRipple(cx, cy, maxSize, life, thick, alpha)
				local ring = new("Frame", {
					Size = UDim2.fromOffset(10, 10),
					Position = UDim2.fromOffset(cx, cy),
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					ZIndex = 0,
					Parent = backdrop,
				})
				new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ring })
				local rs = new("UIStroke", { Color = Color3.fromRGB(190, 210, 245), Thickness = thick, Transparency = alpha, Parent = ring })
				TweenService:Create(ring, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(maxSize, maxSize),
				}):Play()
				local ft = TweenService:Create(rs, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Transparency = 1, Thickness = 0,
				})
				ft:Play()
				ft.Completed:Connect(function() ring:Destroy() end)
			end
			-- as the cursor moves it leaves a trail of ripples, like something gliding through water
			local lastPos
			track(RunService.RenderStepped:Connect(function()
				if not alive then return end
				local m = UIS:GetMouseLocation() - guiInset
				if not within(m) then lastPos = nil return end
				local lx, ly = m.X - backdrop.AbsolutePosition.X, m.Y - backdrop.AbsolutePosition.Y
				local p = Vector2.new(lx, ly)
				if not lastPos or (p - lastPos).Magnitude > 20 then
					lastPos = p
					spawnRipple(lx, ly, 80, 0.9, 1.5, 0.4)
				end
			end))
			-- a bigger, layered splash where you click, like dropping a ball in
			track(UIS.InputBegan:Connect(function(input)
				if not alive or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
				local m = UIS:GetMouseLocation() - guiInset
				if within(m) then
					local lx, ly = m.X - backdrop.AbsolutePosition.X, m.Y - backdrop.AbsolutePosition.Y
					spawnRipple(lx, ly, 250, 0.85, 3, 0.1)
					spawnRipple(lx, ly, 150, 0.6, 2, 0.25)
				end
			end))
		end

		-- title bar: drag it to move the window
		local bar = new("Frame", { Size = UDim2.new(1, 0, 0, BAR), BackgroundColor3 = C.panel, Parent = frame })
		round(bar, 14)
		new("Frame", { -- squares off the bar's bottom corners
			Size = UDim2.new(1, 0, 0, 14),
			Position = UDim2.new(0, 0, 1, -14),
			BackgroundColor3 = C.panel,
			BorderSizePixel = 0,
			Parent = bar,
		})
		new("TextLabel", {
			Text = "Logger Panel",
			Size = UDim2.new(1, -60, 1, 0),
			Position = UDim2.fromOffset(14, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = C.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = bar,
		})
		local hideBtn = new("TextButton", {
			Text = "X",
			Size = UDim2.fromOffset(28, 28),
			Position = UDim2.new(1, -36, 0, 8),
			BackgroundColor3 = C.row,
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = C.subtext,
			Parent = bar,
		})
		round(hideBtn, 8)

		-- the body scrolls, so everything is still reachable when the window is made small
		local body = new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -BAR),
			Position = UDim2.fromOffset(0, BAR),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = C.stroke,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			Parent = frame,
		})
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), Parent = body })
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 24),
			PaddingRight = UDim.new(0, 24),
			PaddingTop = UDim.new(0, 18),
			PaddingBottom = UDim.new(0, 34),
			Parent = body,
		})

		local order = 0
		local function nextOrder()
			order += 1
			return order
		end

		local function heading(text)
			-- breathing room above, the title, and a hairline divider below: clean section breaks
			local holder = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 40),
				BackgroundTransparency = 1,
				Parent = body,
			})
			new("TextLabel", {
				Text = text,
				Size = UDim2.new(1, 0, 0, 20),
				Position = UDim2.fromOffset(0, 14),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = C.accent,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = holder,
			})
			new("Frame", {
				Size = UDim2.new(1, 0, 0, 1),
				Position = UDim2.new(0, 0, 1, -1),
				BackgroundColor3 = C.stroke,
				BackgroundTransparency = 0.45,
				BorderSizePixel = 0,
				Parent = holder,
			})
		end

		local function label(parent, text, rightGap)
			return new("TextLabel", {
				Text = text,
				Size = UDim2.new(1, -rightGap, 0, 24),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamMedium,
				TextSize = 15,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = parent,
			})
		end

		-- an on/off switch in the top-right of parent; onToggle(newValue) runs when it's clicked
		local function makeSwitch(parent, value, onToggle)
			local back = new("TextButton", {
				Text = "",
				AutoButtonColor = false,
				Size = UDim2.fromOffset(44, 22),
				Position = UDim2.new(1, -44, 0, 0),
				BackgroundColor3 = value and C.on or C.off,
				Parent = parent,
			})
			round(back, 11)
			local knob = new("Frame", {
				Size = UDim2.fromOffset(18, 18),
				Position = UDim2.fromOffset(value and 24 or 2, 2),
				BackgroundColor3 = Color3.new(1, 1, 1),
				Parent = back,
			})
			round(knob, 9)
			local switch = { value = value }
			function switch.set(v)
				switch.value = v
				TweenService:Create(back, TweenInfo.new(0.15), { BackgroundColor3 = v and C.on or C.off }):Play()
				TweenService:Create(knob, TweenInfo.new(0.15), { Position = UDim2.fromOffset(v and 24 or 2, 2) }):Play()
			end
			back.MouseButton1Click:Connect(function()
				switch.set(not switch.value)
				onToggle(switch.value)
			end)
			return switch
		end

		---------------- log channels: a toggle and a webhook box each
		if HAS_LOGGER then -- only keys that include the logger get the channel settings
			heading("LOG CHANNELS")
			local boxes = {}
			for _, channel in ipairs(CHANNELS) do
				local row = new("Frame", {
					LayoutOrder = nextOrder(),
					Size = UDim2.new(1, 0, 0, 62),
					BackgroundTransparency = 1,
					Parent = body,
				})
				label(row, channel.label .. (channel.kind == "announcement" and "  (empty = chat channel)" or ""), 54)
				makeSwitch(row, settings.enabled[channel.kind] ~= false, function(on)
					settings.enabled[channel.kind] = on
					saveSettings()
					print("[Logger]", channel.label, on and "ON." or "OFF.", "Logging to Discord:", describeChannels())
				end)
				local box = new("TextBox", {
					Text = urls[channel.kind] or "",
					PlaceholderText = "https://discord.com/api/webhooks/...",
					PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
					ClearTextOnFocus = false,
					ClipsDescendants = true,
					Size = UDim2.new(1, 0, 0, 32),
					Position = UDim2.fromOffset(0, 28),
					BackgroundColor3 = C.panel,
					Font = Enum.Font.Gotham,
					TextSize = 13,
					TextColor3 = C.text,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = row,
				})
				round(box, 8)
				new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = box })
				boxes[channel.kind] = box
			end

			local saveBtn = new("TextButton", {
				Text = "Save webhooks",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 34),
				BackgroundColor3 = C.accent,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Color3.fromRGB(14, 14, 18),
				Parent = body,
			})
			round(saveBtn, 9)
			local status = new("TextLabel", {
				Text = next(urls) and "Toggles work straight away. Press Save after changing a webhook."
					or "Paste your Discord webhooks above and press Save.",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})
			local function setStatus(text, color)
				status.Text = text
				status.TextColor3 = color or C.subtext
			end

			local saving = false
			saveBtn.MouseButton1Click:Connect(function()
				if saving then return end
				saving = true
				local newUrls, problem = {}, nil
				for _, channel in ipairs(CHANNELS) do
					local url = trim(boxes[channel.kind].Text)
					if url ~= "" then
						if not isWebhook(url) then
							problem = channel.label .. ": that isn't a Discord webhook URL."
							break
						end
						newUrls[channel.kind] = url
					end
				end
				if not problem then
					setStatus("Checking webhooks...")
					for _, channel in ipairs(CHANNELS) do
						local url = newUrls[channel.kind]
						if url and url ~= urls[channel.kind] then -- only check the ones that changed
							local works, reason = webhookWorks(url)
							if not works then
								problem = channel.label .. ": " .. reason
								break
							end
						end
					end
				end
				if problem then
					setStatus(problem, C.bad)
					shake(frame)
				else
					urls = newUrls
					writeJson(WEBHOOK_FILE, urls)
					setStatus("Saved! Logging to Discord: " .. describeChannels(), C.on)
					print("[Logger] Webhooks saved. Logging to Discord:", describeChannels())
				end
				saving = false
			end)
		end

		---------------- free camera: on/off toggle and the key that toggles it
		if HAS_FLY then -- only bundle keys include the free camera
			heading("FREE CAMERA")
			local flyRow = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundTransparency = 1,
				Parent = body,
			})
			label(flyRow, "Fly", 54)
			local flySwitch = makeSwitch(flyRow, freecam.isOn(), function(on)
				freecam.set(on)
			end)
			-- keep the toggle in step when flying is switched with the key
			freecam.onChange = function(on)
				if flySwitch.value ~= on then flySwitch.set(on) end
			end

			new("TextLabel", {
				Text = "Hold right mouse to look around, scroll to change speed. Movement keys are in KEYBINDS below.",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = body,
			})

			-- go to a player: type their name (or the start of it) and the camera flies to them
			label(new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundTransparency = 1,
				Parent = body,
			}), "Go to player", 0)
			local goRow = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				Parent = body,
			})
			local nameBox = new("TextBox", {
				Text = "",
				PlaceholderText = "Username or display name...",
				PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Size = UDim2.new(1, -74, 1, 0),
				BackgroundColor3 = C.panel,
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = goRow,
			})
			round(nameBox, 8)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = nameBox })
			local goBtn = new("TextButton", {
				Text = "Go",
				Size = UDim2.new(0, 66, 1, 0),
				Position = UDim2.new(1, -66, 0, 0),
				BackgroundColor3 = C.accent,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = Color3.fromRGB(14, 14, 18),
				Parent = goRow,
			})
			round(goBtn, 8)
			local goStatus = new("TextLabel", {
				Text = "",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 18),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})

			-- dropdown of players that appears when you click the box or type (click one to go to them);
			-- your Roblox friends are listed first
			local MAX_SUGGESTIONS = 8
			local friendCache = {} -- [userId] = true/false once known
			local refreshSuggestions -- set below; re-run once friend checks finish
			local suggestBox = new("Frame", {
				LayoutOrder = goStatus.LayoutOrder, -- sits between the name box and the status line
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = C.panel,
				Visible = false,
				Parent = body,
			})
			goStatus.LayoutOrder = nextOrder()
			round(suggestBox, 9)
			new("UIStroke", { Color = C.stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = suggestBox })
			new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = suggestBox })
			new("UIPadding", {
				PaddingLeft = UDim.new(0, 4),
				PaddingRight = UDim.new(0, 4),
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
				Parent = suggestBox,
			})

			local function goToPlayer(player)
				local ok, problem = freecam.goTo(player)
				if ok then
					goStatus.TextColor3 = C.on
					goStatus.Text = "Camera moved to " .. player.DisplayName .. " (@" .. player.Name .. ")."
				else
					goStatus.TextColor3 = C.bad
					goStatus.Text = problem
				end
			end

			local function goToTyped()
				local player, problem = freecam.findPlayer(nameBox.Text)
				if player then
					goToPlayer(player)
				else
					goStatus.TextColor3 = C.bad
					goStatus.Text = problem
				end
			end

			-- is this player your Roblox friend? Asks Roblox once per player in the background;
			-- until the answer arrives they count as not a friend
			local function isFriend(player)
				if player == Players.LocalPlayer then return false end
				local known = friendCache[player.UserId]
				if known ~= nil then return known end
				friendCache[player.UserId] = false
				task.spawn(function()
					local ok, result = pcall(function() return Players.LocalPlayer:IsFriendsWith(player.UserId) end)
					if ok and result then
						friendCache[player.UserId] = true
						if refreshSuggestions then refreshSuggestions() end
					end
				end)
				return false
			end

			-- one row per matching player: avatar, display name and @username
			local function suggestionRow(player, order)
				local row = new("TextButton", {
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = order,
					Size = UDim2.new(1, 0, 0, 40),
					BackgroundColor3 = C.row,
					Parent = suggestBox,
				})
				round(row, 7)
				local avatar = new("ImageLabel", {
					Image = "rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150",
					Size = UDim2.fromOffset(30, 30),
					Position = UDim2.fromOffset(6, 5),
					BackgroundColor3 = C.bg,
					Parent = row,
				})
				round(avatar, 15)
				new("TextLabel", {
					Text = player.DisplayName .. (player == Players.LocalPlayer and "  (you)" or "")
						.. (friendCache[player.UserId] and "  Friend" or ""),
					Size = UDim2.new(1, -50, 0, 18),
					Position = UDim2.fromOffset(44, 4),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					TextSize = 13,
					TextColor3 = C.text,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				new("TextLabel", {
					Text = "@" .. player.Name,
					Size = UDim2.new(1, -50, 0, 14),
					Position = UDim2.fromOffset(44, 21),
					BackgroundTransparency = 1,
					Font = Enum.Font.Gotham,
					TextSize = 11,
					TextColor3 = C.subtext,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				row.MouseEnter:Connect(function()
					TweenService:Create(row, TweenInfo.new(0.12), { BackgroundColor3 = C.stroke }):Play()
				end)
				row.MouseLeave:Connect(function()
					TweenService:Create(row, TweenInfo.new(0.12), { BackgroundColor3 = C.row }):Play()
				end)
				row.MouseButton1Click:Connect(function()
					nameBox.Text = player.Name
					suggestBox.Visible = false
					goToPlayer(player)
				end)
			end

			-- friends first, then A-Z by display name
			local function byFriendThenName(a, b)
				local fa, fb = isFriend(a), isFriend(b)
				if fa ~= fb then return fa end
				return a.DisplayName:lower() < b.DisplayName:lower()
			end

			-- rebuilds the dropdown: an empty box lists everyone in the server; otherwise names that
			-- start with what's typed come first, then ones containing it (friends on top in each)
			local function updateSuggestions()
				for _, child in ipairs(suggestBox:GetChildren()) do
					if child:IsA("TextButton") or child:IsA("TextLabel") then child:Destroy() end
				end
				if not nameBox:IsFocused() then
					suggestBox.Visible = false
					return
				end
				local query = trim(nameBox.Text):lower():gsub("^@", "")
				local starts, contains = {}, {}
				for _, p in ipairs(Players:GetPlayers()) do
					local name, display = p.Name:lower(), p.DisplayName:lower()
					if query == "" or name:sub(1, #query) == query or display:sub(1, #query) == query then
						table.insert(starts, p)
					elseif name:find(query, 1, true) or display:find(query, 1, true) then
						table.insert(contains, p)
					end
				end
				table.sort(starts, byFriendThenName)
				table.sort(contains, byFriendThenName)
				for _, p in ipairs(contains) do table.insert(starts, p) end

				if #starts == 0 then
					new("TextLabel", {
						Text = "No one in this server matches \"" .. query .. "\"",
						Size = UDim2.new(1, 0, 0, 26),
						BackgroundTransparency = 1,
						Font = Enum.Font.Gotham,
						TextSize = 12,
						TextColor3 = C.subtext,
						Parent = suggestBox,
					})
				else
					for i = 1, math.min(#starts, MAX_SUGGESTIONS) do suggestionRow(starts[i], i) end
					if #starts > MAX_SUGGESTIONS then
						new("TextLabel", {
							Text = "+" .. (#starts - MAX_SUGGESTIONS) .. " more, type to narrow it down",
							LayoutOrder = MAX_SUGGESTIONS + 1,
							Size = UDim2.new(1, 0, 0, 18),
							BackgroundTransparency = 1,
							Font = Enum.Font.Gotham,
							TextSize = 11,
							TextColor3 = C.subtext,
							Parent = suggestBox,
						})
					end
				end
				suggestBox.Visible = true
			end
			refreshSuggestions = function()
				if suggestBox.Visible then updateSuggestions() end
			end

			nameBox:GetPropertyChangedSignal("Text"):Connect(updateSuggestions)
			nameBox.Focused:Connect(updateSuggestions)
			goBtn.MouseButton1Click:Connect(function()
				suggestBox.Visible = false
				goToTyped()
			end)
			nameBox.FocusLost:Connect(function(enterPressed)
				if enterPressed then
					suggestBox.Visible = false
					goToTyped()
				else
					-- clicking a suggestion also takes focus away, so give that click a moment first
					task.delay(0.25, function()
						if not nameBox:IsFocused() then suggestBox.Visible = false end
					end)
				end
			end)
		end

		---------------- moderation: shown to all logger/bundle keys; kicks one chosen player via /kick
		-- The server decides whether the kick happens (it only works if you're an admin there).
		do
			heading("MODERATION (moderator only)")
			local kickRow = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				Parent = body,
			})
			local kickBox = new("TextBox", {
				Text = "",
				PlaceholderText = "Player to kick / ban...",
				PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Size = UDim2.new(1, -140, 1, 0),
				BackgroundColor3 = C.panel,
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = kickRow,
			})
			round(kickBox, 8)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = kickBox })
			local kickBtn = new("TextButton", {
				Text = "Kick",
				Size = UDim2.new(0, 66, 1, 0),
				Position = UDim2.new(1, -136, 0, 0),
				BackgroundColor3 = Color3.fromRGB(120, 36, 36),
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = C.text,
				Parent = kickRow,
			})
			round(kickBtn, 8)
			local banBtn = new("TextButton", {
				Text = "Ban",
				Size = UDim2.new(0, 66, 1, 0),
				Position = UDim2.new(1, -66, 0, 0),
				BackgroundColor3 = Color3.fromRGB(150, 28, 28),
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = C.text,
				Parent = kickRow,
			})
			round(banBtn, 8)
			-- optional reason, saved with a ban and shown next to the name in the banned list
			local reasonBox = new("TextBox", {
				LayoutOrder = nextOrder(),
				Text = "",
				PlaceholderText = "Ban reason (optional)...",
				PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundColor3 = C.panel,
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})
			round(reasonBox, 8)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = reasonBox })
			-- dropdown of players to pick from without typing (click the box to open it)
			local kickList = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = C.panel,
				Visible = false,
				Parent = body,
			})
			round(kickList, 9)
			new("UIStroke", { Color = C.stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = kickList })
			new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = kickList })
			new("UIPadding", {
				PaddingLeft = UDim.new(0, 4),
				PaddingRight = UDim.new(0, 4),
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
				Parent = kickList,
			})

			local kickStatus = new("TextLabel", {
				Text = "Click a name to fill the box, or type one, then press Enter or Kick.",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})

			-- finds the one player the typed text refers to (exact, else a single prefix match)
			local function matchPlayer(text)
				local query = trim(text or ""):lower():gsub("^@", "")
				if query == "" then return nil, "Type a player's name." end
				local exact, partial = nil, {}
				for _, p in ipairs(Players:GetPlayers()) do
					local name, display = p.Name:lower(), p.DisplayName:lower()
					if name == query or display == query then exact = p break end
					if name:sub(1, #query) == query or display:sub(1, #query) == query then
						table.insert(partial, p)
					end
				end
				if exact then return exact end
				if #partial == 1 then return partial[1] end
				if #partial > 1 then return nil, "Several players match. Type the full name." end
				return nil, "No player in this server matches \"" .. query .. "\"."
			end

			-- Sends the game's /kick or /ban for the player named in the box (one specific player).
			-- No confirm step: the button, or pressing Enter, sends the command for that one name,
			-- and logs it to the shared ACTIONS feed. The server only acts on it if you're an admin.
			local function moderate(action) -- action is "kick" or "ban"
				local player, problem = matchPlayer(kickBox.Text)
				if not player then
					kickStatus.TextColor3 = C.bad
					kickStatus.Text = problem
					return
				end
				if player == Players.LocalPlayer then
					kickStatus.TextColor3 = C.bad
					kickStatus.Text = "That's you."
					return
				end
				kickBox.Text = ""
				-- Always log the action to the shared ACTIONS feed the moment it's clicked, so it
				-- shows in the panel even when this game's chat won't accept a /kick command.
				-- A ban carries the optional reason; it's saved with the ban and shown in the list.
				local reason = action == "ban" and trim(reasonBox.Text) or ""
				reasonBox.Text = ""
				recordAction(action, player.Name, reason)
				local sent = sendChat("/" .. action .. " " .. player.Name)
				if sent then
					kickStatus.TextColor3 = C.on
					kickStatus.Text = "Sent /" .. action .. " for " .. player.Name
						.. ". The server acts on it only if you're an admin."
				else
					kickStatus.TextColor3 = C.accent
					kickStatus.Text = "Logged " .. action .. " for " .. player.Name
						.. ", but this game's chat wouldn't take the /" .. action .. " command."
				end
			end
			local function kickTyped() moderate("kick") end
			kickBtn.MouseButton1Click:Connect(kickTyped)
			banBtn.MouseButton1Click:Connect(function() moderate("ban") end)

			-- one row in the picker: avatar, display name and @username; click to put it in the box
			local function kickRowFor(player, order)
				local row = new("TextButton", {
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = order,
					Size = UDim2.new(1, 0, 0, 40),
					BackgroundColor3 = C.row,
					Parent = kickList,
				})
				round(row, 7)
				local avatar = new("ImageLabel", {
					Image = "rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150",
					Size = UDim2.fromOffset(30, 30),
					Position = UDim2.fromOffset(6, 5),
					BackgroundColor3 = C.bg,
					Parent = row,
				})
				round(avatar, 15)
				new("TextLabel", {
					Text = player.DisplayName,
					Size = UDim2.new(1, -50, 0, 18),
					Position = UDim2.fromOffset(44, 4),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					TextSize = 13,
					TextColor3 = C.text,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				new("TextLabel", {
					Text = "@" .. player.Name,
					Size = UDim2.new(1, -50, 0, 14),
					Position = UDim2.fromOffset(44, 21),
					BackgroundTransparency = 1,
					Font = Enum.Font.Gotham,
					TextSize = 11,
					TextColor3 = C.subtext,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				row.MouseEnter:Connect(function()
					TweenService:Create(row, TweenInfo.new(0.12), { BackgroundColor3 = C.stroke }):Play()
				end)
				row.MouseLeave:Connect(function()
					TweenService:Create(row, TweenInfo.new(0.12), { BackgroundColor3 = C.row }):Play()
				end)
				-- clicking a row just fills the box; the Kick -> Confirm step still does the kick
				row.MouseButton1Click:Connect(function()
					kickBox.Text = player.Name
					kickList.Visible = false
				end)
			end

			-- rebuild the picker: everyone in the server (minus you), filtered by what's typed, A-Z
			local function updateKickList()
				for _, child in ipairs(kickList:GetChildren()) do
					if child:IsA("TextButton") or child:IsA("TextLabel") then child:Destroy() end
				end
				if not kickBox:IsFocused() then
					kickList.Visible = false
					return
				end
				local query = trim(kickBox.Text):lower():gsub("^@", "")
				local list = {}
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= Players.LocalPlayer then
						local name, display = p.Name:lower(), p.DisplayName:lower()
						if query == "" or name:find(query, 1, true) or display:find(query, 1, true) then
							table.insert(list, p)
						end
					end
				end
				table.sort(list, function(a, b) return a.DisplayName:lower() < b.DisplayName:lower() end)
				if #list == 0 then
					new("TextLabel", {
						Text = query == "" and "No other players in this server." or "No one matches \"" .. query .. "\"",
						Size = UDim2.new(1, 0, 0, 26),
						BackgroundTransparency = 1,
						Font = Enum.Font.Gotham,
						TextSize = 12,
						TextColor3 = C.subtext,
						Parent = kickList,
					})
				else
					for i, p in ipairs(list) do kickRowFor(p, i) end
				end
				kickList.Visible = true
			end

			kickBox:GetPropertyChangedSignal("Text"):Connect(updateKickList)
			kickBox.Focused:Connect(updateKickList)
			kickBox.FocusLost:Connect(function(enterPressed)
				if enterPressed then
					-- pressing Enter kicks the player whose name is in the box
					kickList.Visible = false
					kickTyped()
					return
				end
				-- a click on a row takes focus away, so wait a moment before hiding the list
				task.delay(0.25, function()
					if not kickBox:IsFocused() then kickList.Visible = false end
				end)
			end)
		end

		---------------- banned members: the shared ban list; click a name then Unban to remove it
		-- Banning adds to this list for everyone; Unban sends /unban, logs it, and removes the name.
		do
			heading("BANNED (click a name, then Unban)")
			local banSearch = new("TextBox", {
				LayoutOrder = nextOrder(),
				Text = "",
				PlaceholderText = "Search banned players...",
				PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundColor3 = C.panel,
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})
			round(banSearch, 8)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = banSearch })
			local banRow = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 150),
				BackgroundTransparency = 1,
				Parent = body,
			})
			local banScroll = new("ScrollingFrame", {
				Size = UDim2.new(1, -86, 1, 0),
				BackgroundColor3 = C.panel,
				BorderSizePixel = 0,
				ScrollBarThickness = 4,
				ScrollBarImageColor3 = C.stroke,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				Parent = banRow,
			})
			round(banScroll, 9)
			new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = banScroll })
			new("UIPadding", {
				PaddingLeft = UDim.new(0, 6),
				PaddingRight = UDim.new(0, 6),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
				Parent = banScroll,
			})
			local banEmpty = new("TextLabel", {
				Text = "No bans yet.",
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = C.subtext,
				Parent = banScroll,
			})
			local unbanBtn = new("TextButton", {
				Text = "Unban",
				Size = UDim2.fromOffset(74, 34),
				Position = UDim2.new(1, -74, 0, 0),
				BackgroundColor3 = C.off,
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextColor3 = C.text,
				Parent = banRow,
			})
			round(unbanBtn, 8)
			local banStatus = new("TextLabel", {
				Text = "",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = body,
			})

			local selected, selectedName = nil, nil -- lowercased key + display name of the picked row
			local rowByKey = {}
			local allBans = {} -- the full list from the server; the search box filters it

			-- "just now" / "5m ago" / "3h ago" from the ban's unix timestamp
			local function banAgo(t)
				local secs = os.time() - (tonumber(t) or os.time())
				if secs < 60 then return "just now" end
				if secs < 3600 then return math.floor(secs / 60) .. "m ago" end
				if secs < 86400 then return math.floor(secs / 3600) .. "h ago" end
				return math.floor(secs / 86400) .. "d ago"
			end

			local function renderBans(bans)
				for _, child in ipairs(banScroll:GetChildren()) do
					if child:IsA("TextButton") then child:Destroy() end
				end
				rowByKey = {}
				if #bans == 0 then
					banEmpty.Visible = true
					selected, selectedName = nil, nil
					unbanBtn.BackgroundColor3 = C.off
					return
				end
				banEmpty.Visible = false
				local stillThere = false
				for i, b in ipairs(bans) do
					if type(b) == "table" and type(b.name) == "string" then
						local key = b.name:lower()
						if key == selected then stillThere = true end
						local row = new("TextButton", {
							Text = "",
							AutoButtonColor = false,
							LayoutOrder = i,
							Size = UDim2.new(1, 0, 0, 42),
							BackgroundColor3 = (key == selected) and C.stroke or C.row,
							Parent = banScroll,
						})
						round(row, 7)
						new("TextLabel", {
							Text = b.name,
							Size = UDim2.new(1, -16, 0, 20),
							Position = UDim2.fromOffset(10, 4),
							BackgroundTransparency = 1,
							Font = Enum.Font.GothamBold,
							TextSize = 15,
							TextColor3 = C.text,
							TextXAlignment = Enum.TextXAlignment.Left,
							TextTruncate = Enum.TextTruncate.AtEnd,
							Parent = row,
						})
						new("TextLabel", {
							Text = "by " .. ((type(b.by) == "string" and b.by ~= "") and b.by or "someone")
								.. " - " .. banAgo(b.at)
								.. ((type(b.reason) == "string" and b.reason ~= "") and (" - " .. b.reason) or ""),
							Size = UDim2.new(1, -16, 0, 14),
							Position = UDim2.fromOffset(10, 23),
							BackgroundTransparency = 1,
							Font = Enum.Font.Gotham,
							TextSize = 12,
							TextColor3 = C.subtext,
							TextXAlignment = Enum.TextXAlignment.Left,
							TextTruncate = Enum.TextTruncate.AtEnd,
							Parent = row,
						})
						rowByKey[key] = row
						row.MouseButton1Click:Connect(function()
							selected, selectedName = key, b.name
							for k, r in pairs(rowByKey) do
								r.BackgroundColor3 = (k == key) and C.stroke or C.row
							end
							unbanBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 70)
							banStatus.TextColor3 = C.subtext
							banStatus.Text = "Selected " .. b.name .. ". Click Unban to remove them."
						end)
					end
				end
				-- the picked player may have been unbanned by someone else since the last refresh
				if selected and not stillThere then
					selected, selectedName = nil, nil
					unbanBtn.BackgroundColor3 = C.off
				elseif selected then
					unbanBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 70)
				end
			end

			-- draw the list through the search box: everything, or just the names that match
			local function applyFilter()
				local query = trim(banSearch.Text):lower()
				if query == "" then
					banEmpty.Text = "No bans yet."
					renderBans(allBans)
					return
				end
				local filtered = {}
				for _, b in ipairs(allBans) do
					if type(b) == "table" and type(b.name) == "string" and b.name:lower():find(query, 1, true) then
						table.insert(filtered, b)
					end
				end
				banEmpty.Text = (#filtered == 0) and "No banned players match your search." or "No bans yet."
				renderBans(filtered)
			end
			banSearch:GetPropertyChangedSignal("Text"):Connect(applyFilter)

			unbanBtn.MouseButton1Click:Connect(function()
				if not selected then
					banStatus.TextColor3 = C.bad
					banStatus.Text = "Pick a name from the list first."
					return
				end
				local name = selectedName
				sendChat("/unban " .. name)
				recordAction("unban", name)
				banStatus.TextColor3 = C.on
				banStatus.Text = "Unbanned " .. name .. ". The server acts on it only if you're an admin."
				selected, selectedName = nil, nil
				unbanBtn.BackgroundColor3 = C.off
				for _, r in pairs(rowByKey) do r.BackgroundColor3 = C.row end
			end)

			-- poll the shared ban list while the script is alive (every 6s)
			task.spawn(function()
				while alive do
					local status, resp = callServer("/bans", {
						key = KEY,
						userId = Players.LocalPlayer.UserId,
						session = SESSION,
						placeId = game.PlaceId,
					})
					if not alive then break end
					if status == 200 and type(resp) == "table" and type(resp.bans) == "table" then
						allBans = resp.bans
						applyFilter()
					end
					task.wait(6)
				end
			end)
		end

		---------------- actions feed: kicks, bans and announcements from everyone running the
		-- logger in this game, pulled from the server's shared feed and refreshed every few seconds.
		do
			heading("ACTIONS (everyone)")
			new("TextLabel", {
				Text = "Kicks, bans and announcements from everyone running the logger in this game.",
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextColor3 = C.subtext,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = body,
			})
			local actionsList = new("ScrollingFrame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 190),
				BackgroundColor3 = C.panel,
				BorderSizePixel = 0,
				ScrollBarThickness = 4,
				ScrollBarImageColor3 = C.stroke,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				Parent = body,
			})
			round(actionsList, 9)
			new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = actionsList })
			new("UIPadding", {
				PaddingLeft = UDim.new(0, 6),
				PaddingRight = UDim.new(0, 6),
				PaddingTop = UDim.new(0, 6),
				PaddingBottom = UDim.new(0, 6),
				Parent = actionsList,
			})
			local actionsEmpty = new("TextLabel", {
				Text = "Loading actions...",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextColor3 = C.subtext,
				Parent = actionsList,
			})

			-- text tags instead of emoji (Roblox doesn't render all emoji glyphs reliably)
			local ACTION_META = {
				kick = { tag = "KICK", verb = "kicked", color = C.accent },
				ban = { tag = "BAN", verb = "banned", color = C.bad },
				unban = { tag = "UNBAN", verb = "unbanned", color = C.on },
				announcement = { tag = "NOTICE", color = Color3.fromRGB(180, 185, 200) },
			}

			-- short "2m" / "3h" style age from the action's unix timestamp
			local function timeAgo(t)
				local secs = os.time() - (tonumber(t) or os.time())
				if secs < 5 then return "now" end
				if secs < 60 then return secs .. "s" end
				if secs < 3600 then return math.floor(secs / 60) .. "m" end
				if secs < 86400 then return math.floor(secs / 3600) .. "h" end
				return math.floor(secs / 86400) .. "d"
			end

			-- "Mod kicked Target" / "Mod banned Target" / "Sender: message" (the tag shows the type)
			local function actionText(a)
				if a.kind == "announcement" then
					local sender = (type(a.target) == "string" and a.target ~= "") and a.target or "Someone"
					local msg = (type(a.text) == "string" and a.text ~= "") and a.text or "(no message)"
					return sender .. ": " .. msg
				end
				local meta = ACTION_META[a.kind]
				local who = (type(a.moderatorDisplay) == "string" and a.moderatorDisplay ~= "")
					and a.moderatorDisplay or (a.moderator or "Someone")
				local target = (type(a.target) == "string" and a.target ~= "") and a.target or "someone"
				return who .. " " .. meta.verb .. " " .. target
			end

			local function renderActions(actions)
				for _, child in ipairs(actionsList:GetChildren()) do
					if child:IsA("Frame") then child:Destroy() end
				end
				if #actions == 0 then
					actionsEmpty.Text = "No actions yet."
					actionsEmpty.Visible = true
					return
				end
				actionsEmpty.Visible = false
				for i, a in ipairs(actions) do
					if type(a) == "table" and ACTION_META[a.kind] then
						local meta = ACTION_META[a.kind]
						local row = new("Frame", {
							LayoutOrder = i,
							Size = UDim2.new(1, 0, 0, 40),
							BackgroundColor3 = C.row,
							Parent = actionsList,
						})
						round(row, 7)
						new("TextLabel", { -- colored type tag in place of an emoji
							Text = meta.tag,
							Size = UDim2.new(0, 56, 1, 0),
							Position = UDim2.fromOffset(8, 0),
							BackgroundTransparency = 1,
							Font = Enum.Font.GothamBold,
							TextSize = 13,
							TextColor3 = meta.color,
							TextXAlignment = Enum.TextXAlignment.Left,
							Parent = row,
						})
						new("TextLabel", {
							Text = actionText(a),
							Size = UDim2.new(1, -116, 1, 0),
							Position = UDim2.fromOffset(66, 0),
							BackgroundTransparency = 1,
							Font = Enum.Font.GothamMedium,
							TextSize = 14,
							TextColor3 = C.text,
							TextXAlignment = Enum.TextXAlignment.Left,
							TextTruncate = Enum.TextTruncate.AtEnd,
							Parent = row,
						})
						new("TextLabel", {
							Text = timeAgo(a.t),
							Size = UDim2.new(0, 42, 1, 0),
							Position = UDim2.new(1, -48, 0, 0),
							BackgroundTransparency = 1,
							Font = Enum.Font.Gotham,
							TextSize = 12,
							TextColor3 = C.subtext,
							TextXAlignment = Enum.TextXAlignment.Right,
							Parent = row,
						})
					end
				end
			end

			-- poll the shared feed while the script is alive (every 6s)
			task.spawn(function()
				while alive do
					local status, resp = callServer("/actions", {
						key = KEY,
						userId = Players.LocalPlayer.UserId,
						session = SESSION,
						placeId = game.PlaceId,
					})
					if not alive then break end
					if status == 200 and type(resp) == "table" and type(resp.actions) == "table" then
						renderActions(resp.actions)
					elseif status == 403 then
						lostAccess(resp.error)
						break
					else
						-- don't sit silently on "Loading..."; show what the server actually said
						actionsEmpty.Visible = true
						if status == nil then
							actionsEmpty.Text = "Can't reach the server."
						else
							local why = (type(resp) == "table" and type(resp.error) == "string") and (": " .. resp.error) or ""
							actionsEmpty.Text = "Server error " .. tostring(status) .. why
						end
					end
					task.wait(6)
				end
			end)
		end

		---------------- keybinds: click a key button, then press the key you want (Esc cancels)
		heading("KEYBINDS")
		-- only the keybinds for parts this key unlocks are shown
		local KEYBIND_ROWS = {}
		for _, bind in ipairs({
			{ name = "panelKey", text = "Open/close this panel", on = true },
			{ name = "creditsKey", text = "Open/close credits window", on = HAS_CREDITS },
			{ name = "flyKey", text = "Fly on/off", on = HAS_FLY },
			{ name = "flyForward", text = "Fly forward", on = HAS_FLY },
			{ name = "flyBack", text = "Fly back", on = HAS_FLY },
			{ name = "flyLeft", text = "Fly left", on = HAS_FLY },
			{ name = "flyRight", text = "Fly right", on = HAS_FLY },
			{ name = "flyUp", text = "Fly up", on = HAS_FLY },
			{ name = "flyDown", text = "Fly down", on = HAS_FLY },
			{ name = "flyFast", text = "Fly faster (hold)", on = HAS_FLY },
		}) do
			if bind.on then table.insert(KEYBIND_ROWS, bind) end
		end
		local function keybindRow(bind)
			local row = new("Frame", {
				LayoutOrder = nextOrder(),
				Size = UDim2.new(1, 0, 0, 30),
				BackgroundTransparency = 1,
				Parent = body,
			})
			label(row, bind.text, 140).Position = UDim2.fromOffset(0, 4)
			local button = new("TextButton", {
				Text = settings[bind.name],
				Size = UDim2.fromOffset(130, 28),
				Position = UDim2.new(1, -130, 0, 0),
				BackgroundColor3 = C.panel,
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = C.accent,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			round(button, 8)
			new("UIStroke", { Color = C.stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })

			button.MouseButton1Click:Connect(function()
				if keybinds.listening then return end
				keybinds.listening = true
				button.Text = "Press a key..."
				local conn
				conn = track(UserInputService.InputBegan:Connect(function(input)
					if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
					conn:Disconnect()
					local key = input.KeyCode.Name
					local takenBy
					for _, other in ipairs(KEYBIND_ROWS) do
						if other.name ~= bind.name and settings[other.name] == key then takenBy = other.text end
					end
					if input.KeyCode == Enum.KeyCode.Escape then
						button.Text = settings[bind.name]
					elseif takenBy then
						-- one key can't do two things
						button.Text = "Already used"
						button.TextColor3 = C.bad
						task.delay(1, function()
							button.Text = settings[bind.name]
							button.TextColor3 = C.accent
						end)
					else
						settings[bind.name] = key
						saveSettings()
						freecam.keysChanged()
						button.Text = key
						print("[Logger] " .. bind.text .. " key set to " .. key)
					end
					-- wait a frame so this same key press doesn't also trigger the old/new binding
					task.defer(function() keybinds.listening = false end)
				end))
			end)
		end
		for _, bind in ipairs(KEYBIND_ROWS) do keybindRow(bind) end

		---------------- terminate: stops everything and removes all windows (run the loadstring to relaunch)
		heading("SCRIPT")
		local terminateBtn = new("TextButton", {
			Text = "Terminate script",
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = Color3.fromRGB(120, 36, 36),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = C.text,
			Parent = body,
		})
		round(terminateBtn, 9)
		new("UIStroke", { Color = C.bad, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = terminateBtn })
		-- needs two clicks so it isn't hit by accident
		local armed = false
		terminateBtn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				terminateBtn.Text = "Click again to terminate"
				task.delay(3, function()
					if armed and terminateBtn.Parent then
						armed = false
						terminateBtn.Text = "Terminate script"
					end
				end)
				return
			end
			print("[Logger] Terminated: logging, credits window, free camera and panel all stopped. Run the loadstring to relaunch.")
			genv.LoggerStop()
			genv.LoggerStop = nil
		end)

		---------------- moving, resizing, hiding
		local grip = new("TextButton", {
			Text = "/",
			Size = UDim2.fromOffset(22, 22),
			Position = UDim2.new(1, -22, 1, -22),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = C.subtext,
			ZIndex = 10,
			Parent = frame,
		})

		local function isPress(input)
			return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
		end
		local dragging, resizing, startInput, startPos, startSize
		bar.InputBegan:Connect(function(input)
			if isPress(input) then
				dragging, startInput, startPos = true, input.Position, frame.Position
			end
		end)
		grip.InputBegan:Connect(function(input)
			if isPress(input) then
				resizing, startInput, startSize = true, input.Position, frame.AbsoluteSize
			end
		end)
		track(UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local delta = input.Position - (startInput or input.Position)
			if dragging then
				frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			elseif resizing then
				frame.Size = UDim2.fromOffset(
					math.clamp(startSize.X + delta.X, MIN_W, MAX_W),
					math.clamp(startSize.Y + delta.Y, MIN_H, MAX_H)
				)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(input)
			if isPress(input) then
				dragging, resizing = false, false
			end
		end))

		hideBtn.MouseButton1Click:Connect(function()
			frame.Visible = false
			print("[Logger] Panel hidden. Press " .. settings.panelKey .. " to bring it back.")
		end)
		-- the panel key (Right Ctrl unless changed above) hides and shows the panel
		track(UserInputService.InputBegan:Connect(function(input)
			if alive and not keybinds.listening and keyIs(input, "panelKey") then
				frame.Visible = not frame.Visible
			end
		end))

		-- terminating, re-executing or losing the key removes the panel
		onStop(function() gui:Destroy() end)
		print("[Logger] Logger Panel open. " .. settings.panelKey .. " hides/shows it.")
	end

	print("[Logger] v29 running (" .. PRODUCT_NAMES[PRODUCT] .. " key).")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
	warn("[Logger] Crashed: " .. tostring(err))
end
