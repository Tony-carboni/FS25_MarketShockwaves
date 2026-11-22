--[[
    NotificationAdapter — shows event messages to the player.

    Event messages are a paragraph long and matter to the player's decisions, so
    they are shown as a MODAL DIALOG that has to be acknowledged. A HUD
    side-notification is the wrong medium: it scrolls past in a second or two and
    truncates anything longer than a sentence.

    Dialog entry points have moved between FS versions, so we try the known
    candidates in order and log which one worked - that log line tells us the
    right API for this build. If every dialog attempt fails we fall back to a
    side notification, and failing that the log alone. A missing UI API must
    never break the economy simulation, so every attempt is pcall-guarded.

    MESSAGES ARE QUEUED, NEVER SHOWN SYNCHRONOUSLY. Events fire from inside
    FSBaseMission.update, and opening a dialog there while the player is asleep
    pushes a GUI input context in the middle of SleepManager's own context
    handling. SleepManager then fails to revert it:

        Warning: Tried reverting to input context [] which is not defined.
        Current context [SLEEPING]

    which leaves the player stuck in the SLEEPING context - unable to move, with
    only the console responding. So notify() only enqueues, and the queue is
    drained from update() once no GUI is open, the player is not sleeping, and a
    short grace period has passed so SleepManager has finished its own cleanup.
]]

MSWNotificationAdapter = {}
local MSWNotificationAdapter_mt = Class(MSWNotificationAdapter)

-- Frames to wait after conditions look safe, so SleepManager can finish
-- restoring its input context before we push a dialog on top.
local SAFE_GRACE_FRAMES = 30

-- If we still cannot show a dialog after this long, fall back to a
-- notification rather than swallowing the message entirely.
local MAX_QUEUE_FRAMES = 60 * 30   -- roughly 30 seconds at 60fps

function MSWNotificationAdapter.new(logger)
    local self = setmetatable({}, MSWNotificationAdapter_mt)
    self.log = logger
    self.workingMethod = nil    -- remembered after the first success
    self.queue = {}             -- pending { title, text, waited }
    self.safeFrames = 0         -- consecutive frames conditions have looked safe
    return self
end

--- Is it safe to open a dialog right now?
---
--- Refuses while the player is asleep (the freeze described above), while any
--- other GUI is open (do not interrupt a menu, and do not stack dialogs), and
--- before the mission is running.
function MSWNotificationAdapter:isSafeToShow()
    if g_gui == nil or g_currentMission == nil then return false end

    -- Any GUI or dialog already on screen.
    local guiOpen = false
    pcall(function()
        if g_gui.currentGui ~= nil then guiOpen = true end
        if g_gui.getIsDialogVisible ~= nil and g_gui:getIsDialogVisible() then
            guiOpen = true
        end
    end)
    if guiOpen then return false end

    -- Sleeping: this is the case that corrupted the input context stack.
    local sleeping = false
    pcall(function()
        if g_sleepManager ~= nil then
            if g_sleepManager.isSleeping == true then sleeping = true end
            if g_sleepManager.getIsSleeping ~= nil and g_sleepManager:getIsSleeping() then
                sleeping = true
            end
        end
        if g_currentMission.isSleeping == true then sleeping = true end
    end)
    if sleeping then return false end

    -- Fast-forward / time skip also runs the sleep machinery on some builds.
    local skipping = false
    pcall(function()
        if g_currentMission.missionDynamicInfo ~= nil
           and g_currentMission.missionDynamicInfo.isSkippingTime == true then
            skipping = true
        end
    end)
    if skipping then return false end

    return true
end

--- Drain one queued message when it is safe. Call every frame from update().
function MSWNotificationAdapter:update()
    if #self.queue == 0 then
        self.safeFrames = 0
        return
    end

    -- Age everything so a message cannot be trapped forever.
    for _, m in ipairs(self.queue) do m.waited = (m.waited or 0) + 1 end

    if self:isSafeToShow() then
        self.safeFrames = self.safeFrames + 1
    else
        self.safeFrames = 0
    end

    local head = self.queue[1]
    -- A PATIENT message is never downgraded: it waits for a safe moment however
    -- long that takes. The welcome text is several paragraphs, and the fallback
    -- side notification would show a sentence of it for two seconds.
    local timedOut = (not head.patient) and head.waited >= MAX_QUEUE_FRAMES

    if self.safeFrames < SAFE_GRACE_FRAMES and not timedOut then return end

    table.remove(self.queue, 1)
    self.safeFrames = 0

    if timedOut and not self:isSafeToShow() then
        self.log:warn("NotificationAdapter: could not open a dialog in time; "
                   .. "using a plain notification instead")
        self:showFallback(head.title, head.text)
        return
    end

    if self:showDialog(head.title, head.text) == nil then
        self:showFallback(head.title, head.text)
    end
end

--- Try to raise a modal, acknowledge-required dialog.
--- @return string|nil name of the method that worked
function MSWNotificationAdapter:showDialog(title, text)
    if g_gui == nil then return nil end

    local body = text
    if title ~= nil and title ~= "" then
        body = title .. "\n\n" .. text
    end

    -- Candidates, most likely first. InfoDialog.show is confirmed working on
    -- FS25 (verified in a test log); the g_gui:showInfoDialog variants failed
    -- there but are kept as fallbacks for other builds.
    local attempts = {
        {
            name = "InfoDialog.show",
            run = function()
                if InfoDialog == nil or InfoDialog.show == nil then return false end
                InfoDialog.show(body)
                return true
            end,
        },
        {
            name = "g_gui:showInfoDialog{text,title}",
            run = function()
                g_gui:showInfoDialog({ text = text, title = title })
                return true
            end,
        },
        {
            name = "g_gui:showInfoDialog{text}",
            run = function()
                g_gui:showInfoDialog({ text = body })
                return true
            end,
        },
        {
            name = "g_gui:showYesNoDialog{text}",
            run = function()
                -- Last resort: a yes/no dialog still requires acknowledgement.
                g_gui:showYesNoDialog({ text = body, title = title })
                return true
            end,
        },
    }

    -- If one already worked, use it directly.
    if self.workingMethod ~= nil then
        for _, a in ipairs(attempts) do
            if a.name == self.workingMethod then
                local ok, res = pcall(a.run)
                if ok and res then return a.name end
                break   -- it stopped working; fall through and re-probe
            end
        end
        self.workingMethod = nil
    end

    for _, a in ipairs(attempts) do
        local ok, res = pcall(a.run)
        if ok and res then
            self.workingMethod = a.name
            self.log:info("NotificationAdapter: dialog shown via " .. a.name)
            return a.name
        end
        self.log:debug(("NotificationAdapter: %s failed (%s)")
            :format(a.name, tostring(res)))
    end
    return nil
end

--- Queue a message. Never opens a dialog directly - see the header note.
--- @param opts table|nil  { patient = true } waits for a dialog indefinitely
---                        instead of falling back to a notification
function MSWNotificationAdapter:notify(title, text, opts)
    -- Always log it in full: guarantees the message is recoverable even if no
    -- UI path works, and keeps a record of what the player was told when.
    self.log:info("EVENT >> " .. tostring(title) .. ": " .. tostring(text))
    if g_currentMission == nil then return end
    self.queue[#self.queue + 1] = { title = title, text = text, waited = 0,
                                    patient = opts ~= nil and opts.patient == true }
end

--- Non-modal paths, used when a dialog is impossible.
function MSWNotificationAdapter:showFallback(title, text)
    local message = tostring(title) .. ": " .. tostring(text)

    if g_currentMission.addIngameNotification ~= nil then
        local ok = pcall(function()
            local t = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
            g_currentMission:addIngameNotification(t, message)
        end)
        if ok then return end
    end

    if g_currentMission.hud ~= nil and g_currentMission.hud.addSideNotification ~= nil then
        local ok = pcall(function()
            g_currentMission.hud:addSideNotification(nil, message)
        end)
        if ok then return end
    end

    self.log:warn("NotificationAdapter: no UI path worked; message is in the log only")
end
