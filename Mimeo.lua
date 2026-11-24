-- Mimeo: copies chat window setups from one of your characters to another, or carries one as a text string.
-- A setup is every chat window's name, font size, colour, alpha, shown/locked/docked/click-through state, saved
-- size and position, message groups and channels. Each character's setup is saved when it logs out.
local ADDON = ...
local LibDeflate = LibStub("LibDeflate")
local LibSerialize = LibStub("LibSerialize")
local Registry = LibStub("AceConfigRegistry-3.0")
local Dialog = LibStub("AceConfigDialog-3.0")

local TITLE = "Mimeo"
local WINDOWS = Constants.ChatFrameConstants.MaxChatWindows -- NUM_CHAT_WINDOWS is only a deprecated shim on Forever
local FORMAT = 1                                           -- version of the table inside a Mimeo string
local PREFIX = "!MIMEO:"
local OLD_PREFIX = "!COPYBARA:"                            -- Copybara 1.x strings import too
local VERSION = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
-- Forever's FontString:SetText refuses nil, so every Blizzard string gets a plain fallback.
local NAME_PATTERN = CHAT_NAME_TEMPLATE or "Chat %d"

local db -- MimeoDB: { toons = { [character] = { windows = { [1..WINDOWS] = window } } }, pick = { [character] = source } }

local function Say(text) DEFAULT_CHAT_FRAME:AddMessage("|cff9fc5e8Mimeo|r " .. text) end

-- This character's key. With Forever's regional unique names the second return of UnitName is a surname.
local function Me()
    local first, second = UnitName("player")
    if second and second ~= "" then return first .. " " .. second end
    return first .. " - " .. (GetRealmName() or "?")
end

-------------------------------------------------------------------------------
--  Reading and writing the client's chat windows
-------------------------------------------------------------------------------
-- GetChatWindowChannels returns name, zone flag, name, zone flag...: only the names are channels.
local function ChannelNames(...)
    local names = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then names[#names + 1] = v end
    end
    return names
end

local function ReadWindows()
    local windows = {}
    for i = 1, WINDOWS do
        local frame = _G["ChatFrame" .. i]
        local id = frame and frame:GetID() or i
        local name, size, r, g, b, alpha, shown, locked, docked, clickThrough = GetChatWindowInfo(i)
        local width, height = GetChatWindowSavedDimensions(i)
        local point, x, y = GetChatWindowSavedPosition(i)
        windows[i] = {
            name = name, size = size, colour = { r, g, b }, alpha = alpha,
            shown = shown and true or false, locked = locked and true or false, docked = docked,
            clickThrough = clickThrough and true or false,
            width = width, height = height, anchor = point and { point, x or 0, y or 0 } or nil,
            groups = { GetChatWindowMessages(id) }, channels = ChannelNames(GetChatWindowChannels(id)),
        }
    end
    return windows
end

local function Complete(windows)
    if type(windows) ~= "table" then return false end
    for i = 1, WINDOWS do
        if type(windows[i]) ~= "table" then return false end
    end
    return true
end

-- Writes a setup into the client, then reloads: the client rebuilds every chat frame from what was written.
local function WriteWindows(windows)
    if not Complete(windows) then
        Say("Those chat settings are incomplete or damaged. Nothing changed.")
        return
    end
    for i = 1, WINDOWS do
        local frame, w = _G["ChatFrame" .. i], windows[i]
        if frame then
            SetChatWindowName(i, (w.name and w.name ~= "") and w.name or NAME_PATTERN:format(i))
            local c = w.colour
            if c and c[1] and c[2] and c[3] then SetChatWindowColor(i, c[1], c[2], c[3]) end
            if w.alpha then SetChatWindowAlpha(i, w.alpha) end
            if w.size then SetChatWindowSize(i, w.size) end
            SetChatWindowShown(i, w.shown == true)
            SetChatWindowLocked(i, w.locked == true)
            SetChatWindowDocked(i, w.docked)
            SetChatWindowUninteractable(i, w.clickThrough == true)
            if (w.width or 0) > 0 and (w.height or 0) > 0 then SetChatWindowSavedDimensions(i, w.width, w.height) end
            if w.anchor then SetChatWindowSavedPosition(i, w.anchor[1], w.anchor[2] or 0, w.anchor[3] or 0) end
            -- Message groups and channels live on the frame (ChatFrameMixin; the ChatFrame_* globals are shims).
            frame:RemoveAllMessageGroups()
            frame:RemoveAllChannels()
            frame:ReceiveAllPrivateMessages()
            for _, group in ipairs(w.groups or {}) do frame:AddMessageGroup(group) end
            for _, channel in ipairs(w.channels or {}) do frame:AddChannel(channel) end
        end
    end
    ReloadUI()
end

-------------------------------------------------------------------------------
--  Strings
-------------------------------------------------------------------------------
local function Encode(windows)
    local packed = LibSerialize:SerializeEx({ errorOnUnserializableType = false }, { format = FORMAT, windows = windows })
    return PREFIX .. LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(packed, { level = 9 }))
end

-- A Copybara 1.x string holds an array of windows under Copybara's field names.
local function FromCopybara(old)
    local windows = {}
    for i = 1, WINDOWS do
        local o = old[i]
        if type(o) ~= "table" then return nil end
        windows[i] = {
            name = o.name, size = o.fontSize, colour = { o.r, o.g, o.b }, alpha = o.alpha,
            shown = o.shown and true or false, locked = o.locked and true or false, docked = o.docked,
            clickThrough = o.uninteractable and true or false, width = o.width, height = o.height,
            anchor = o.point and { o.point, o.xOfs or 0, o.yOfs or 0 } or nil,
            groups = o.DefaultMessages or {}, channels = ChannelNames(unpack(o.DefaultChannels or {})),
        }
    end
    return windows
end

-- Returns the windows in a pasted string, or nil and why not.
local function Decode(text)
    if type(text) ~= "string" or not text:find("%S") then
        return nil, "Paste a Mimeo string into the box and click Accept first."
    end
    text = text:match("^%s*(.-)%s*$") -- pasting drags in spaces and line breaks
    local fromCopybara = false
    local body = text:sub(1, #PREFIX) == PREFIX and text:sub(#PREFIX + 1)
    if not body and text:sub(1, #OLD_PREFIX) == OLD_PREFIX then
        body, fromCopybara = text:sub(#OLD_PREFIX + 1), true
    end
    if not body or body == "" then return nil, "That isn't a Mimeo (or Copybara) string." end
    local raw = LibDeflate:DecodeForPrint(body)
    raw = raw and LibDeflate:DecompressDeflate(raw)
    if not raw then return nil, "That string is damaged: it doesn't unpack." end
    local ok, t = LibSerialize:Deserialize(raw)
    if not ok or type(t) ~= "table" then return nil, "That string is damaged: it doesn't read back." end
    if fromCopybara then
        local windows = FromCopybara(t)
        if not windows then return nil, "That Copybara string is incomplete." end
        return windows
    end
    if type(t.format) ~= "number" or t.format > FORMAT then
        return nil, "That string comes from a newer Mimeo. Update Mimeo and try again."
    end
    return t.windows
end

-------------------------------------------------------------------------------
--  Options window (Blizzard's AddOns settings, and /mimeo)
-------------------------------------------------------------------------------
local box = "" -- the Import / Export box's text; not saved

-- Characters with a saved setup: key -> label.
local function Sources()
    local list = {}
    for key, toon in pairs(db.toons) do
        if type(toon) == "table" and Complete(toon.windows) then list[key] = key end
    end
    return list
end

local function SortedSources()
    local keys = {}
    for key in pairs(Sources()) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function CopyPicked()
    local from = db.pick[Me()]
    if not from then return Say("Pick a character to copy from first.") end
    local toon = db.toons[from]
    if not (toon and toon.windows) then
        return Say(("Nothing saved for %s yet. Log in and out on that character once with Mimeo on."):format(from))
    end
    WriteWindows(toon.windows)
end

local function ImportBox()
    local windows, why = Decode(box)
    if not windows then return Say(why) end
    WriteWindows(windows)
end

local function ExportToBox()
    local from = db.pick[Me()]
    local toon = from and db.toons[from]
    local windows, whose = toon and toon.windows, from
    if not windows then windows, whose = ReadWindows(), Me() end -- nothing picked: what this character has now
    box = Encode(windows)
    Registry:NotifyChange(TITLE)
    Say(("Put %s's chat settings in the box."):format(whose))
end

local options = {
    type = "group",
    name = TITLE,
    args = {
        about = {
            order = 0, type = "description",
            name = ("Version %s\n\nA character shows up below once it has logged out with Mimeo on.\n"):format(VERSION),
        },
        from = {
            order = 1, type = "select", style = "dropdown", name = "Copy chat settings from",
            values = Sources, sorting = SortedSources,
            get = function() return db.pick[Me()] end,
            set = function(_, key) db.pick[Me()] = key end,
        },
        apply = {
            order = 2, type = "execute", name = APPLY or "Apply",
            desc = "Copies the picked character's chat settings to this character and reloads the UI.",
            func = CopyPicked,
        },
        gap1 = { order = 3, type = "description", name = "" },
        text = {
            order = 4, type = "input", multiline = true, width = "double", name = "Import / Export",
            get = function() return box end,
            set = function(_, value) box = value end,
        },
        gap2 = { order = 5, type = "description", name = "" },
        import = {
            order = 6, type = "execute", name = "Import",
            desc = "Applies the string in the box to this character and reloads the UI. Copybara strings work too.",
            func = ImportBox,
        },
        export = {
            order = 7, type = "execute", name = "Export",
            desc = "Puts the picked character's chat settings in the box, or this character's if none is picked.",
            func = ExportToBox,
        },
    },
}

-------------------------------------------------------------------------------
--  Start-up and saving
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        MimeoDB = type(MimeoDB) == "table" and MimeoDB or {}
        MimeoDB.toons = MimeoDB.toons or {}
        MimeoDB.pick = MimeoDB.pick or {}
        db = MimeoDB
        Registry:RegisterOptionsTable(TITLE, options)
        Dialog:AddToBlizOptions(TITLE, TITLE)
    elseif event == "PLAYER_LOGOUT" and db then
        db.toons[Me()] = { windows = ReadWindows() }
    end
end)

SLASH_MIMEO1 = "/mimeo"
SlashCmdList.MIMEO = function() Dialog:Open(TITLE) end
