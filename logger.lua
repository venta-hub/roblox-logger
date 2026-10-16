-- Join/Leave/Chat/Announcement Logger (v11, server version)
-- After the key is accepted, a Log Channels panel asks for your own Discord webhooks (one box per
-- log type). Logs go through the Cloudflare Worker, which checks the key on every log and only
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
local function track(conn)
	table.insert(conns, conn)
	return conn
end
genv.LoggerStop = function()
	alive = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)
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

	-- returns (true) if the key is valid, or (false, reason)
	local function checkKey(key)
		key = trim(key or "")
		if key == "" then return false, "Enter a key." end
		local status, body = callServer("/check", { key = key, userId = Players.LocalPlayer.UserId })
		if status == 200 then return true end
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
			BackgroundColor3 = Color3.fromRGB(18, 18, 24),
			Parent = gui,
		})
		round(frame, 14)
		new("UIStroke", { Color = Color3.fromRGB(60, 60, 78), Thickness = 1.5, Parent = frame })
		new("TextLabel", {
			Text = "🔑  Enter Key",
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
			Text = "×",
			Size = UDim2.fromOffset(30, 30),
			Position = UDim2.new(1, -40, 0, 13),
			BackgroundColor3 = Color3.fromRGB(34, 34, 44),
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
			BackgroundColor3 = Color3.fromRGB(28, 28, 36),
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
			BackgroundColor3 = Color3.fromRGB(255, 196, 64),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(30, 24, 10),
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

	---------------------------------------------------------------- channels panel
	-- Every time the script runs, a panel asks for your Discord webhooks: one box per log type.
	-- They're saved to a file so the boxes are already filled in next time. Leave a box empty to
	-- turn that log off (an empty Announcements box sends announcements to the chat channel).
	local WEBHOOK_FILE = "logger_webhooks.json"
	local CHANNELS = {
		{ kind = "join", label = "Join logs" },
		{ kind = "leave", label = "Leave logs" },
		{ kind = "chat", label = "Chat logs" },
		{ kind = "announcement", label = "Announcements (empty = chat channel)" },
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

	local function loadWebhooks()
		local ok, saved = pcall(function()
			return isfile and isfile(WEBHOOK_FILE) and HttpService:JSONDecode(readfile(WEBHOOK_FILE))
		end)
		return (ok and type(saved) == "table") and saved or {}
	end

	local function saveWebhooks(hooks)
		pcall(function() if writefile then writefile(WEBHOOK_FILE, HttpService:JSONEncode(hooks)) end end)
	end

	-- asks Discord whether the webhook exists; returns (true) or (false, reason)
	local function webhookWorks(url)
		local res, reason = httpRequest({ Url = url, Method = "GET" })
		if not res then return false, "couldn't reach Discord (" .. reason .. ")" end
		if res.StatusCode == 200 then return true end
		if res.StatusCode == 401 or res.StatusCode == 404 then return false, "that webhook was deleted or is wrong." end
		return false, "Discord said " .. res.StatusCode
	end

	-- shows the panel and waits; returns { kind = url } for the filled-in boxes, or nil if closed
	local function askForChannels()
		local saved = loadWebhooks()
		local gui = makeGui("LoggerChannels")

		local ROW = 62
		local listTop = 66
		local buttonY = listTop + #CHANNELS * ROW + 4
		local height = buttonY + 76
		local frame = new("Frame", {
			Size = UDim2.fromOffset(400, height),
			Position = UDim2.new(0.5, -200, 0.5, -height / 2),
			BackgroundColor3 = Color3.fromRGB(18, 18, 24),
			Parent = gui,
		})
		round(frame, 14)
		new("UIStroke", { Color = Color3.fromRGB(60, 60, 78), Thickness = 1.5, Parent = frame })
		new("TextLabel", {
			Text = "📡  Log Channels",
			Size = UDim2.new(1, -60, 0, 30),
			Position = UDim2.fromOffset(16, 10),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 17,
			TextColor3 = Color3.fromRGB(240, 240, 245),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = frame,
		})
		new("TextLabel", {
			Text = "Paste a Discord webhook URL for each channel. Leave a box empty to turn it off.",
			Size = UDim2.new(1, -32, 0, 20),
			Position = UDim2.fromOffset(16, 38),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(150, 150, 165),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			Parent = frame,
		})
		local close = new("TextButton", {
			Text = "×",
			Size = UDim2.fromOffset(30, 30),
			Position = UDim2.new(1, -40, 0, 12),
			BackgroundColor3 = Color3.fromRGB(34, 34, 44),
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = Color3.fromRGB(150, 150, 165),
			Parent = frame,
		})
		round(close, 8)

		local boxes = {}
		for i, channel in ipairs(CHANNELS) do
			local y = listTop + (i - 1) * ROW
			new("TextLabel", {
				Text = channel.label,
				Size = UDim2.new(1, -32, 0, 18),
				Position = UDim2.fromOffset(16, y),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamMedium,
				TextSize = 13,
				TextColor3 = Color3.fromRGB(210, 210, 220),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
			local box = new("TextBox", {
				Text = type(saved[channel.kind]) == "string" and saved[channel.kind] or "",
				PlaceholderText = "https://discord.com/api/webhooks/...",
				PlaceholderColor3 = Color3.fromRGB(110, 110, 125),
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Size = UDim2.new(1, -32, 0, 34),
				Position = UDim2.fromOffset(16, y + 22),
				BackgroundColor3 = Color3.fromRGB(28, 28, 36),
				Font = Enum.Font.Gotham,
				TextSize = 13,
				TextColor3 = Color3.fromRGB(240, 240, 245),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
			round(box, 9)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = box })
			boxes[channel.kind] = box
		end

		local start = new("TextButton", {
			Text = "Save & Start",
			Size = UDim2.new(1, -32, 0, 36),
			Position = UDim2.fromOffset(16, buttonY),
			BackgroundColor3 = Color3.fromRGB(255, 196, 64),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(30, 24, 10),
			Parent = frame,
		})
		round(start, 9)
		local status = new("TextLabel", {
			Text = "",
			Size = UDim2.new(1, -32, 0, 28),
			Position = UDim2.fromOffset(16, buttonY + 40),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextWrapped = true,
			TextColor3 = Color3.fromRGB(240, 90, 90),
			Parent = frame,
		})

		local function fail(text)
			status.TextColor3 = Color3.fromRGB(240, 90, 90)
			status.Text = text
			shake(frame)
		end

		local result -- nil while waiting, then the webhooks table, or false if closed
		local checking = false
		local function try()
			local hooks, any = {}, false
			for _, channel in ipairs(CHANNELS) do
				local url = trim(boxes[channel.kind].Text)
				if url ~= "" then
					if not isWebhook(url) then
						return fail(channel.label .. ": that isn't a Discord webhook URL.")
					end
					hooks[channel.kind] = url
					any = true
				end
			end
			if not any then return fail("Fill in at least one channel.") end

			status.TextColor3 = Color3.fromRGB(150, 150, 165)
			status.Text = "Checking webhooks..."
			for _, channel in ipairs(CHANNELS) do
				if hooks[channel.kind] then
					local works, reason = webhookWorks(hooks[channel.kind])
					if not works then return fail(channel.label .. ": " .. reason) end
				end
			end

			saveWebhooks(hooks)
			status.TextColor3 = Color3.fromRGB(80, 220, 120)
			status.Text = "Saved! Logging started."
			task.wait(0.6)
			result = hooks
		end
		start.MouseButton1Click:Connect(function()
			if checking then return end
			checking = true
			try()
			checking = false
		end)
		close.MouseButton1Click:Connect(function() result = false end)

		while result == nil and alive and gui.Parent do task.wait() end
		gui:Destroy()
		return result or nil
	end

	print("[Logger] Waiting for channels in the Log Channels panel...")
	local WEBHOOKS = askForChannels()
	if not WEBHOOKS then
		warn("[Logger] Log Channels panel closed, logger not started.")
		return
	end
	WEBHOOKS.announcement = WEBHOOKS.announcement or WEBHOOKS.chat
	local enabled = {}
	for _, channel in ipairs(CHANNELS) do
		if WEBHOOKS[channel.kind] then table.insert(enabled, channel.kind) end
	end
	print("[Logger] Logging to Discord:", table.concat(enabled, ", "))

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

	-- kind is "join", "leave", "chat" or "announcement"; sent to that channel's webhook from the panel
	local function post(kind, payload)
		local webhook = WEBHOOKS[kind]
		if not webhook then return end -- this log is turned off in the panel
		local status, body = callServer("/log", {
			key = KEY,
			userId = Players.LocalPlayer.UserId,
			kind = kind,
			webhook = webhook,
			payload = payload,
		})
		if status == nil then
			warn("[Logger] Couldn't reach the server.")
		elseif status >= 400 then
			warn("[Logger] Server refused the", kind, "log:", status, body.error or "")
		end
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
		saveToFile(kind == "join" and "JOINED" or "LEFT", player)
		if not WEBHOOKS[kind] then return end
		fetchAvatars({ [player.UserId] = true })
		local embed, profile = playerCard(title, color, player.UserId, player.DisplayName, player.Name)
		table.insert(embed.fields, { name = "Account Age", value = player.AccountAge .. " days", inline = true })
		table.insert(embed.fields, { name = "Players In Server", value = tostring(#Players:GetPlayers()), inline = true })
		table.insert(embed.fields, { name = "Profile", value = profile })
		embed.timestamp = DateTime.now():ToIsoDate()
		post(kind, { embeds = { embed } })
	end

	track(Players.PlayerAdded:Connect(function(player)
		send("join", "✅ Player Joined", 0x2ECC71, player)
	end))

	track(Players.PlayerRemoving:Connect(function(player)
		-- player count still includes the leaver at this point, so it's 1 higher
		send("leave", "❌ Player Left", 0xE74C3C, player)
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
			if not WEBHOOKS.chat then return end -- chat logs are turned off
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
							local embed = playerCard("💬 Chat", 0x3498DB, m.userId, m.displayName, m.username)
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

		-- "Message from Xylryx" / "📢 Message From @Xylryx:" / "Message from Xylryx (@xylryx)" -> "Xylryx"
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
			if not WEBHOOKS.announcement then return end -- announcements are turned off
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
			-- The card's title is the sender's name exactly as the popup shows it ("Message from Xylryx").
			-- If that name belongs to someone in this server, their avatar, username and ID are added too.
			local title = "📢 Message from " .. senderName
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

	print("[Logger] v11 running (server version: chat cards + translation + announcements).")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
	warn("[Logger] Crashed: " .. tostring(err))
end
