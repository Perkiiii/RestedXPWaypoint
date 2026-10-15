-- RestedXP Waypoint
-- LabelResolver: turns RestedXP's arrow element into a short, clean
-- description for Waypoint UI. Like RXPAdapter, it reads RestedXP internals,
-- so every field is type-checked.
--
-- How RestedXP links instructions to waypoints (GuideLoader.lua parseLine,
-- functions.lua, RXPGuides v4.11.23):
--   * A step's lines become step.elements, in guide order. ".goto" lines are
--     waypoint elements (tag "goto", usually arrow = true).
--   * "line >> text" gives that element its own text. A ".goto ... >> text"
--     therefore carries the instruction for that exact waypoint.
--   * When parsed, a waypoint's element.parent is set to the most recent
--     text-bearing objective ABOVE it in the same step (addon.lastObjective).
--     RestedXP drops the waypoint once that parent completes, so parent is
--     RestedXP's own "this waypoint belongs to this instruction" link.
--   * Text-only ">>Talk to X" lines never become a parent, and a step's
--     first .goto usually has no parent: its instructions FOLLOW it.
--   * A non-optional .goto with a radius and no text gets generated text
--     "Go to x,y (zone)", which is just coordinates.
--   * Quest elements may hold "*quest*" until the quest name loads. Objective
--     text is rebuilt with live progress ("Worg slain: 3/10"); rawtext holds
--     the author's text but can be a format string.
--
-- Resolution order (first usable text wins):
--   1. element.title        explicit arrow title (what RestedXP's own arrow shows)
--   2. step.arrowtext       explicit per-step arrow text
--   3. element.text         the waypoint's own ">>" text (not generated coordinate text)
--   4. element.parent       RestedXP's linked objective, if not completed
--   5. following lines      in the same step, up to the next waypoint group:
--                           the first pending real instruction (with live progress),
--                           else a text-only heading, warnings only as a last resort,
--                           or the ">>" text of the next waypoint in the same route chain
--   6. preceding lines      only when this is the step's first waypoint (same order)
--   7. step.title
--   8. "Step N"             fallback (coordinates stay visible)
-- Finished instructions are never used (see IsDone: RestedXP's render-time
-- "completed" flag on text-only lines does not count).

local _, RXPW = ...
local Label = RXPW.Label

-- Longest label in bytes before it is shortened at a word boundary.
local MAX_LENGTH = 60

local type = type
local ipairs = ipairs
local tostring = tostring

--------------------------------------------------------------------------------
-- Text cleaning
--------------------------------------------------------------------------------

local PROTECTED_PIPE = "\001"

-- Returns cleaned, wasCleaned, wasShortened; cleaned is nil if nothing usable remains.
function Label.Clean(text)
    if type(text) ~= "string" then return nil end
    local original = text

    text = text:gsub("\\n", "\n")                 -- guide text uses a literal "\n"
    text = text:gsub("||", PROTECTED_PIPE)        -- escaped pipe, handled below
    text = text:gsub("|cRXP_[%u%d]+_", "")        -- RestedXP colour tokens: |cRXP_FRIENDLY_Name|r
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")    -- |cAARRGGBB
    text = text:gsub("|cn[^:]*:", "")             -- |cnCOLOR_NAME:
    text = text:gsub("|r", "")
    text = text:gsub("|H.-|h(.-)|h", "%1")        -- hyperlinks keep their visible text
    text = text:gsub("|T.-|t", "")                -- textures / icons
    text = text:gsub("|A.-|a", "")                -- atlases
    text = text:gsub("RXP_[%u%d]+_", "")          -- stray RestedXP tokens
    text = text:gsub("::%d+", "")                 -- NPC IDs: "Name::251368" (RestedXP strips these too)
    text = text:gsub("|", "")                     -- any other escape introducer
    text = text:gsub(PROTECTED_PIPE, "/")         -- a lone pipe would start an escape in UI text

    -- Unresolved placeholder: not safe to show.
    if text:find("%*quest%*") then return nil end

    -- Several instructions on separate lines: the first one is the primary.
    local firstLine
    for line in text:gmatch("[^\n]+") do
        if line:find("%S") then
            firstLine = line
            break
        end
    end
    if not firstLine then return nil end
    text = firstLine

    text = text:gsub("%c", " ")
    -- Progress counts ("1/15 Windstone Cluster") are kept: the bridge refreshes
    -- the label when RestedXP's objective text changes (v0.5.6).
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    -- Needs at least one letter: RestedXP's "+1" placeholder is not a label.
    if text == "" or not text:find("[%a\128-\255]") then return nil end

    local shortened = false
    if #text > MAX_LENGTH then
        local cut = MAX_LENGTH
        -- Prefer the last space (ASCII, so never inside a UTF-8 sequence).
        local space = text:sub(1, MAX_LENGTH):match(".*() ")
        if space and space > MAX_LENGTH / 2 then
            cut = space - 1
        else
            -- Never split a UTF-8 multi-byte character.
            while cut > 1 do
                local nextByte = text:byte(cut + 1)
                if not nextByte or nextByte < 0x80 or nextByte >= 0xC0 then break end
                cut = cut - 1
            end
        end
        text = text:sub(1, cut):gsub("[%s,;:%-]+$", "") .. "..."
        shortened = true
    end

    return text, text ~= original, shortened
end

--------------------------------------------------------------------------------
-- RestedXP element helpers
--------------------------------------------------------------------------------

local function IsWaypointElement(element)
    return element.arrow == true or element.tag == "goto" or element.tag == "waypoint"
end

-- RestedXP's guide window sets completed = true on EVERY text-only or
-- text-less element it draws (GuideWindow.lua ~1316-1328: ">>" headers, "*"
-- notes, .mob/.target, and every .goto), so "completed" alone does not mean
-- done. Real progress: SetElementComplete sets completed AND skip, and a reached
-- waypoint sets skip. So: skip, or completed on a real instruction.
local function IsDone(element)
    return element.skip or (element.completed and not element.textOnly and element.text ~= nil) or false
end

local function IsWarning(text)
    return text:find("^%s*|cRXP_WARN_") ~= nil
end

-- The waypoint's own ">>" text, ignoring RestedXP's generated "Go to x,y (zone)".
local function WaypointOwnText(element)
    local text = element.text
    if type(text) ~= "string" then return nil end
    if text:find("%-?%d+%.%d+,%s*%-?%d+%.%d+ %(") then return nil end
    return text
end

-- An instruction's text: the author's rawtext when it is plain (not a format
-- string), else the live text, with "*quest*" filled in when the name is known.
local function InstructionText(element)
    local text = element.rawtext
    if type(text) ~= "string" or text:find("%%") or not text:find("%S") then
        text = element.text
    end
    if type(text) ~= "string" then return nil end
    if text:find("%*quest%*") then
        local questName = element.title
        if type(questName) ~= "string" or questName == "" then return nil end
        text = text:gsub("%*quest%*", (questName:gsub("%%", "%%%%")))
    end
    return text
end

local function Candidate(text, source)
    if type(text) ~= "string" then return nil end
    local label, cleaned, shortened = Label.Clean(text)
    if not label then return nil end
    return {
        label = label,
        source = source,
        cleaned = cleaned,
        shortened = shortened,
        fallback = false,
        raw = text,
    }
end

local function FindIndex(elements, element)
    for i, e in ipairs(elements) do
        if e == element then return i end
    end
end

-- Validate RestedXP's explicit link within this active step. Consecutive
-- waypoints may be crossed only when they share that exact parent. Keep the
-- full instruction block (including sibling objectives) before the group.
function Label.LinkedBlock(element)
    local step, parent = element.step, element.parent
    if type(step) ~= "table" or not step.active or type(step.elements) ~= "table"
        or type(parent) ~= "table" or IsDone(parent) then return nil end
    local elements = step.elements
    local index, parentIndex = FindIndex(elements, element), FindIndex(elements, parent)
    if not index or not parentIndex or parentIndex >= index then return nil end
    for i = parentIndex + 1, index - 1 do
        local e = elements[i]
        if type(e) == "table" and IsWaypointElement(e) and e.parent ~= parent then return nil end
    end
    local first = parentIndex - 1
    while first >= 1 do
        local e = elements[first]
        if type(e) == "table" and IsWaypointElement(e) then break end
        first = first - 1
    end
    return first + 1, index - 1, index
end

-- Instructions that follow the waypoint in its step, up to the next
-- waypoint group. Consecutive waypoints right after it are treated as the
-- same route chain, so a chain ending in ".goto ... >> Enter the crypt" is
-- labelled by that text.
-- Within the segment the first pending real instruction wins (an objective
-- with its live progress, "Turn in X", "Fly to Y"); text-only headings
-- (">>Click on the Crystals") are the fallback, warnings the last resort.
-- (In game RestedXP marks text-only lines completed when it draws them, so
-- headings were never chosen ahead of instructions; v0.5.6 keeps that order
-- deliberately and uses headings instead of falling back to "Step N".)
local function ScanFollowing(elements, index)
    local heading, warning
    local passedInstruction = false

    for i = index + 1, #elements do
        local element = elements[i]
        if type(element) == "table" then
            if IsWaypointElement(element) then
                if passedInstruction then break end
                local found = Candidate(WaypointOwnText(element), "route text of a later waypoint")
                if found then return found end
            else
                local text = InstructionText(element)
                if text then
                    passedInstruction = true
                    if not IsDone(element) then
                        if IsWarning(text) then
                            warning = warning or Candidate(text, "following warning text")
                        elseif element.textOnly then
                            heading = heading or Candidate(text, "following heading")
                        else
                            local found = Candidate(text, "following instruction")
                            if found then return found end
                        end
                    end
                end
            end
        end
    end
    return heading, warning
end

-- Instructions before the waypoint, only when it is the step's first waypoint
-- (real instructions first, then headings).
local function ScanPreceding(elements, index)
    for i = 1, index - 1 do
        local element = elements[i]
        if type(element) == "table" and IsWaypointElement(element) then return nil end
    end
    local heading
    for i = 1, index - 1 do
        local element = elements[i]
        if type(element) == "table" and not IsDone(element) then
            local text = InstructionText(element)
            if text and not IsWarning(text) then
                if element.textOnly then
                    heading = heading or Candidate(text, "preceding heading")
                else
                    local found = Candidate(text, "preceding instruction")
                    if found then return found end
                end
            end
        end
    end
    return heading
end

--------------------------------------------------------------------------------
-- Resolver
--------------------------------------------------------------------------------

-- Returns { label, source, cleaned, shortened, fallback, raw }.
function Label.Resolve(element)
    local step = type(element.step) == "table" and element.step or nil

    local found = Candidate(element.title, "arrow title")
        or (step and Candidate(step.arrowtext, "step arrow text"))
        or Candidate(WaypointOwnText(element), "waypoint text")

    if not found then
        local parent = element.parent
        if Label.LinkedBlock(element) then
            found = Candidate(InstructionText(parent), "linked objective")
        end
    end

    local warning
    if not found and step and type(step.elements) == "table" then
        local index = FindIndex(step.elements, element)
        if index then
            found, warning = ScanFollowing(step.elements, index)
            found = found or ScanPreceding(step.elements, index)
        end
    end

    found = found or warning or (step and Candidate(step.title, "step title"))
    if found then return found end

    return {
        label = step and step.index and ("Step " .. tostring(step.index)) or "RestedXP",
        source = "fallback",
        cleaned = false,
        shortened = false,
        fallback = true,
    }
end
