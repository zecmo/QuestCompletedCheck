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

-- Tracks the quest ID currently awaiting an async cache load, if any
local pendingQuestId = nil
-- Forward-declared; assigned below once the frame's text/icon widgets exist
local UpdateStatus

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
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        local questID = arg1
        if pendingQuestId and questID == pendingQuestId then
            pendingQuestId = nil
            UpdateStatus(questID)
        end
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

-- Function to update status (icon, text, and quest title with cases)
UpdateStatus = function(questId)
    local questTitle = C_QuestLog.GetTitleForQuestID(questId)
    if not questTitle or questTitle == "" then
        -- Case 1: Not Found
        QuestCompletedCheckFrame.StatusIcon:Hide()
        QuestCompletedCheckFrame.StatusText:SetText("Quest Not Found")
        QuestCompletedCheckFrame.StatusText:SetTextColor(1, 0, 0) -- Red
    else
        QuestCompletedCheckFrame.StatusIcon:Show()
        if #questTitle > 33 then
            local startLen = 15 -- Characters from the start
            local endLen = 15 -- Characters from the end
            questTitle = string.sub(questTitle, 1, startLen) .. "…" .. string.sub(questTitle, -endLen)
        end
        local isCompleted = C_QuestLog.IsQuestFlaggedCompleted(questId)
        if not isCompleted then
            -- Case 2: Found, Not Complete
            QuestCompletedCheckFrame.StatusIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
            QuestCompletedCheckFrame.StatusIcon:SetVertexColor(1, 1, 0) -- Yellow
            QuestCompletedCheckFrame.StatusText:SetText(questTitle)
            QuestCompletedCheckFrame.StatusText:SetTextColor(1, 1, 0) -- Yellow
        else
            -- Case 3: Found, Complete
            QuestCompletedCheckFrame.StatusIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
            QuestCompletedCheckFrame.StatusIcon:SetVertexColor(0, 1, 0) -- Green
            QuestCompletedCheckFrame.StatusText:SetText(questTitle)
            QuestCompletedCheckFrame.StatusText:SetTextColor(0, 1, 0) -- Green
        end
    end
    
    QuestCompletedCheckFrame.StatusText:Show()
    QuestCompletedCheckFrame.Placeholder:Hide()
end

-- Requests quest data from the server before checking status, since a quest
-- not yet cached client-side reports "Not Found" until its data arrives.
local function RequestQuestStatus(questId)
    pendingQuestId = questId
    C_QuestLog.RequestLoadQuestByID(questId)

    local questTitle = C_QuestLog.GetTitleForQuestID(questId)
    if questTitle and questTitle ~= "" then
        -- Already cached, no need to wait for QUEST_DATA_LOAD_RESULT
        pendingQuestId = nil
        UpdateStatus(questId)
        return
    end

    -- Not cached yet; the QUEST_DATA_LOAD_RESULT handler will finish this.
    -- Fall back in case the event never fires (e.g. an invalid quest ID).
    C_Timer.After(2, function()
        if pendingQuestId == questId then
            pendingQuestId = nil
            UpdateStatus(questId)
        end
    end)
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
SlashCmdList.QUESTCOMPLETEDCHECK = function()
    QuestCompletedCheckFrame:Show()
    QuestCompletedCheckFrame.EditBox:SetText("")
    QuestCompletedCheckFrame.StatusIcon:Hide()
    QuestCompletedCheckFrame.StatusText:Hide()
    QuestCompletedCheckFrame.Placeholder:Show()
    QuestCompletedCheckFrame.EditBox:SetFocus() -- Mimic Clear behavior
end
