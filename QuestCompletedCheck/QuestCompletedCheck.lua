-- Create the main frame
local QuestCompletedCheckFrame = CreateFrame("Frame", "QuestCompletedCheckFrame", UIParent, "BasicFrameTemplateWithInset")
_G["QuestCompletedCheckFrame"] = QuestCompletedCheckFrame -- Make frame globally accessible
table.insert(UISpecialFrames, "QuestCompletedCheckFrame") -- Register for Escape key closure
QuestCompletedCheckFrame:SetSize(220, 110)
QuestCompletedCheckFrame:SetPoint("CENTER")
QuestCompletedCheckFrame:Hide()
QuestCompletedCheckFrame:SetMovable(true)
QuestCompletedCheckFrame:EnableMouse(true)
QuestCompletedCheckFrame:RegisterForDrag("LeftButton")
QuestCompletedCheckFrame:SetScript("OnDragStart", QuestCompletedCheckFrame.StartMoving)
QuestCompletedCheckFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save position
    QuestCompletedCheckDB = QuestCompletedCheckDB or {}
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    QuestCompletedCheckDB.point = point
    QuestCompletedCheckDB.relativePoint = relativePoint
    QuestCompletedCheckDB.xOfs = xOfs
    QuestCompletedCheckDB.yOfs = yOfs
end)

-- How long to wait on the server for quest data before rendering what we know
local POLL_INTERVAL = 0.2
local MAX_WAIT_SECONDS = 5
-- Re-ask the server on a schedule: a second manual submit is known to work, so
-- the retry a player does by hand happens here instead. Spaced well apart,
-- since rapid repeat requests for the same quest appear to be dropped.
local RETRY_AFTER = 1.5
local MAX_REQUESTS = 2
-- How long to keep trying after the server reports it has no data for an ID.
-- That answer is weak evidence: the first request for an uncached quest can
-- report failure and still deliver the data seconds later.
local MISSING_GRACE = 2.5

-- The lookup awaiting async quest data, if any. Each submission gets a serial
-- so a late reply from an earlier lookup can never overwrite a newer one.
local lookupSerial = 0
local pendingLookup = nil
-- Forward-declared; assigned below once the frame's text/icon widgets exist
local UpdateStatus
local PollLookup

-- Restore saved position on load
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        local addonName = arg1
        if addonName == "QuestCompletedCheck" then
            if QuestCompletedCheckDB and QuestCompletedCheckDB.point and QuestCompletedCheckDB.xOfs and QuestCompletedCheckDB.yOfs then
                QuestCompletedCheckFrame:ClearAllPoints()
                QuestCompletedCheckFrame:SetPoint(QuestCompletedCheckDB.point, UIParent, QuestCompletedCheckDB.relativePoint or "CENTER", QuestCompletedCheckDB.xOfs, QuestCompletedCheckDB.yOfs)
            end
            if QuestCompletedCheckDB then
                QuestCompletedCheckDB.log = nil -- drop a log left by an older build
            end
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        local questID, success = arg1, arg2
        -- Other addons request quest data constantly, so most of these are
        -- not ours. Only the pending lookup is of interest.
        if not pendingLookup or pendingLookup.questId ~= questID then
            return
        end
        if success == false then
            -- Not proof of a bad ID, only a reason to stop waiting soon
            if not pendingLookup.serverMissing then
                pendingLookup.serverMissing = true
                pendingLookup.serverMissingAt = pendingLookup.elapsed
            end
        else
            pendingLookup.exists = true
        end
        -- Flags only. The running poll picks them up within POLL_INTERVAL;
        -- calling PollLookup here would start a second timer chain.
    end
end)

-- Title
QuestCompletedCheckFrame.Title = QuestCompletedCheckFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
QuestCompletedCheckFrame.Title:SetPoint("TOP", 0, -5)
QuestCompletedCheckFrame.Title:SetText("Quest Completed Check")

-- Status message (above EditBox) with icon to the left
QuestCompletedCheckFrame.StatusText = QuestCompletedCheckFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
QuestCompletedCheckFrame.StatusText:SetPoint("CENTER", 0, 19)
QuestCompletedCheckFrame.StatusText:Hide()

QuestCompletedCheckFrame.StatusIcon = QuestCompletedCheckFrame:CreateTexture(nil, "OVERLAY")
QuestCompletedCheckFrame.StatusIcon:SetSize(20, 20)
QuestCompletedCheckFrame.StatusIcon:SetPoint("LEFT", 12, -2)
QuestCompletedCheckFrame.StatusIcon:Hide()

-- EditBox for quest ID
QuestCompletedCheckFrame.EditBox = CreateFrame("EditBox", nil, QuestCompletedCheckFrame, "InputBoxTemplate")
QuestCompletedCheckFrame.EditBox:SetSize(140, 20)
QuestCompletedCheckFrame.EditBox:SetPoint("CENTER", 0, -2)
QuestCompletedCheckFrame.EditBox:SetJustifyH("LEFT")
QuestCompletedCheckFrame.EditBox:SetFontObject("ChatFontNormal")
QuestCompletedCheckFrame.EditBox:SetAutoFocus(false)
-- Restrict to numbers only
QuestCompletedCheckFrame.EditBox:SetScript("OnChar", function(self, char)
    if not char:match("%d") then
        return -- Allow only digits
    end
end)

-- Placeholder text
QuestCompletedCheckFrame.Placeholder = QuestCompletedCheckFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
QuestCompletedCheckFrame.Placeholder:SetPoint("LEFT", QuestCompletedCheckFrame.EditBox, "LEFT", 5, 0)
QuestCompletedCheckFrame.Placeholder:SetText("Enter Quest ID")
QuestCompletedCheckFrame.Placeholder:SetTextColor(0.5, 0.5, 0.5, 1)
QuestCompletedCheckFrame.Placeholder:Show()

-- A quest name lives in one of several caches depending on the quest type
local function GetQuestTitle(questId)
    local questTitle = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questId)
    if not questTitle or questTitle == "" then
        questTitle = C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(questId)
    end
    if (not questTitle or questTitle == "") and C_QuestLog.GetQuestInfo then
        questTitle = C_QuestLog.GetQuestInfo(questId)
    end
    if not questTitle or questTitle == "" then
        return nil
    end
    return questTitle
end

-- Function to update status (icon, text, and quest title with cases).
-- questExists tells us the server confirmed the ID; an empty title does not,
-- since the name cache fills in asynchronously.
UpdateStatus = function(questId, questExists)
    local questTitle = GetQuestTitle(questId)
    -- A local flag, so this is reliable even while the title cache is empty
    local isCompleted = C_QuestLog.IsQuestFlaggedCompleted(questId)
    if not questTitle and not isCompleted and not questExists then
        -- Case 1: Not Found
        QuestCompletedCheckFrame.StatusIcon:Hide()
        QuestCompletedCheckFrame.StatusText:SetText("Quest Not Found")
        QuestCompletedCheckFrame.StatusText:SetTextColor(1, 0, 0) -- Red
    else
        QuestCompletedCheckFrame.StatusIcon:Show()
        -- A verified ID whose name never arrived still gets a readable label
        local label = questTitle or ("Quest " .. questId)
        if #label > 33 then
            local startLen = 15 -- Characters from the start
            local endLen = 15 -- Characters from the end
            label = string.sub(label, 1, startLen) .. "…" .. string.sub(label, -endLen)
        end
        if not isCompleted then
            -- Case 2: Found, Not Complete
            QuestCompletedCheckFrame.StatusIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
            QuestCompletedCheckFrame.StatusIcon:SetVertexColor(1, 1, 0) -- Yellow
            QuestCompletedCheckFrame.StatusText:SetText(label)
            QuestCompletedCheckFrame.StatusText:SetTextColor(1, 1, 0) -- Yellow
        else
            -- Case 3: Found, Complete
            QuestCompletedCheckFrame.StatusIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
            QuestCompletedCheckFrame.StatusIcon:SetVertexColor(0, 1, 0) -- Green
            QuestCompletedCheckFrame.StatusText:SetText(label)
            QuestCompletedCheckFrame.StatusText:SetTextColor(0, 1, 0) -- Green
        end
    end
    
    QuestCompletedCheckFrame.StatusText:Show()
    QuestCompletedCheckFrame.Placeholder:Hide()
end

-- Shown while the server is still being waited on, so a slow lookup is never
-- mistaken for a missing quest
local function ShowChecking(questId)
    QuestCompletedCheckFrame.StatusIcon:Hide()
    QuestCompletedCheckFrame.StatusText:SetText("Checking " .. questId .. "…")
    QuestCompletedCheckFrame.StatusText:SetTextColor(0.7, 0.7, 0.7) -- Grey
    QuestCompletedCheckFrame.StatusText:Show()
    QuestCompletedCheckFrame.Placeholder:Hide()
end

-- Drops a lookup in flight so its result cannot land on a cleared or retyped box
local function CancelLookup()
    pendingLookup = nil
end

local function FinishLookup(serial, questExists)
    if not pendingLookup or pendingLookup.serial ~= serial then
        return -- superseded or cancelled
    end
    local questId = pendingLookup.questId
    pendingLookup = nil
    UpdateStatus(questId, questExists)
end

local function IssueRequest()
    pendingLookup.requests = pendingLookup.requests + 1
    C_QuestLog.RequestLoadQuestByID(pendingLookup.questId)
end

-- Waits for the async quest data to arrive, then renders the result. Keeps
-- polling because QUEST_DATA_LOAD_RESULT can land a frame before the title,
-- and re-asks the server because the first request does not always deliver.
PollLookup = function(serial)
    if not pendingLookup or pendingLookup.serial ~= serial then
        return -- superseded or cancelled
    end
    local questId = pendingLookup.questId

    if GetQuestTitle(questId) then
        FinishLookup(serial, true)
        return
    end
    if HaveQuestData and HaveQuestData(questId) then
        pendingLookup.exists = true
    end

    if pendingLookup.requests < MAX_REQUESTS
        and pendingLookup.elapsed >= pendingLookup.requests * RETRY_AFTER then
        IssueRequest()
    end

    local deadline = MAX_WAIT_SECONDS
    if pendingLookup.serverMissing then
        local graceEnds = pendingLookup.serverMissingAt + MISSING_GRACE
        if graceEnds < deadline then
            deadline = graceEnds
        end
    end
    if pendingLookup.elapsed >= deadline then
        FinishLookup(serial, pendingLookup.exists)
        return
    end

    pendingLookup.elapsed = pendingLookup.elapsed + POLL_INTERVAL
    C_Timer.After(POLL_INTERVAL, function() PollLookup(serial) end)
end

-- Looks up a quest ID. Completion is a local flag and is shown immediately;
-- only the quest name (and confirming that an unknown ID really is unknown)
-- needs the server, so a verified ID no longer reports "Quest Not Found"
-- while its data is still in flight.
local function RequestQuestStatus(questId)
    lookupSerial = lookupSerial + 1
    local serial = lookupSerial
    pendingLookup = { serial = serial, questId = questId, elapsed = 0, exists = nil, requests = 0 }

    local questTitle = GetQuestTitle(questId)
    if questTitle or C_QuestLog.IsQuestFlaggedCompleted(questId) then
        -- Answer with what the client already knows
        UpdateStatus(questId, true)
    else
        ShowChecking(questId)
    end

    if questTitle then
        -- Nothing left to wait for
        pendingLookup = nil
        return
    end

    IssueRequest()
    C_Timer.After(POLL_INTERVAL, function() PollLookup(serial) end)
end

-- EditBox scripts
QuestCompletedCheckFrame.EditBox:SetScript("OnEnterPressed", function(self)
    local cleaned_string = string.gsub(self:GetText(), "%D", "")
    QuestCompletedCheckFrame.EditBox:SetText(cleaned_string)    
    local questId = tonumber(cleaned_string)
    if questId then
        RequestQuestStatus(questId)
    else
        QuestCompletedCheckFrame.StatusIcon:Hide()
        QuestCompletedCheckFrame.StatusText:Hide()
        if self:GetText() == "" then
            QuestCompletedCheckFrame.Placeholder:Show()
        end
    end
end)
QuestCompletedCheckFrame.EditBox:SetScript("OnEscapePressed", function(self)
    if self:HasFocus() then
        -- If EditBox has focus, lose focus but keep popup open
        self:ClearFocus()
    end
end)
QuestCompletedCheckFrame.EditBox:SetScript("OnTextChanged", function(self)
    CancelLookup()
    QuestCompletedCheckFrame.StatusIcon:Hide()
    QuestCompletedCheckFrame.StatusText:Hide()
    if self:GetText() == "" then
        QuestCompletedCheckFrame.Placeholder:Show()
    else
        QuestCompletedCheckFrame.Placeholder:Hide()
    end
end)

-- Clear button (bottom left)
QuestCompletedCheckFrame.ClearButton = CreateFrame("Button", nil, QuestCompletedCheckFrame, "UIPanelButtonTemplate")
QuestCompletedCheckFrame.ClearButton:SetSize(70, 20)
QuestCompletedCheckFrame.ClearButton:SetPoint("BOTTOMLEFT", 15, 15)
QuestCompletedCheckFrame.ClearButton:SetText("Clear")
QuestCompletedCheckFrame.ClearButton:SetScript("OnClick", function()
    CancelLookup()
    QuestCompletedCheckFrame.EditBox:SetText("")
    QuestCompletedCheckFrame.StatusIcon:Hide()
    QuestCompletedCheckFrame.StatusText:Hide()
    QuestCompletedCheckFrame.Placeholder:Show()
    QuestCompletedCheckFrame.EditBox:SetFocus() -- Focus on Clear
end)

-- Enter button (bottom right)
QuestCompletedCheckFrame.EnterButton = CreateFrame("Button", nil, QuestCompletedCheckFrame, "UIPanelButtonTemplate")
QuestCompletedCheckFrame.EnterButton:SetSize(70, 20)
QuestCompletedCheckFrame.EnterButton:SetPoint("BOTTOMRIGHT", -15, 15)
QuestCompletedCheckFrame.EnterButton:SetText("Enter")
QuestCompletedCheckFrame.EnterButton:SetScript("OnClick", function()
    local questId = tonumber(QuestCompletedCheckFrame.EditBox:GetText())
    if questId then
        RequestQuestStatus(questId)
    else
        QuestCompletedCheckFrame.StatusIcon:Hide()
        QuestCompletedCheckFrame.StatusText:Hide()
        if QuestCompletedCheckFrame.EditBox:GetText() == "" then
            QuestCompletedCheckFrame.Placeholder:Show()
        end
    end
end)

-- Slash command
SLASH_QUESTCOMPLETEDCHECK1 = "/qcc"
-- Kept from the pre-rename QuestCompleted addon so existing macros still work
SLASH_QUESTCOMPLETEDCHECK2 = "/iqc"
SlashCmdList.QUESTCOMPLETEDCHECK = function()
    CancelLookup()
    QuestCompletedCheckFrame:Show()
    QuestCompletedCheckFrame.EditBox:SetText("")
    QuestCompletedCheckFrame.StatusIcon:Hide()
    QuestCompletedCheckFrame.StatusText:Hide()
    QuestCompletedCheckFrame.Placeholder:Show()
    QuestCompletedCheckFrame.EditBox:SetFocus() -- Mimic Clear behavior
end
