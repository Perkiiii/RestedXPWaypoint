-- RXP Waypoint Bridge
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
--                           the first incomplete instruction (warnings only as a last resort),
--                           or the ">>" text of the next waypoint in the same route chain
--   6. preceding lines      only when this is the step's first waypoint
--   7. step.title
--   8. "Step N"             fallback (coordinates stay visible)
-- Completed or skipped instructions are never used.

local _, ns = ...
local Label = ns.Label

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
    -- Progress counters would go stale on a static label: "Worg slain: 3/10".
    text = text:gsub("%s*:?%s*%(?%d+%s*/%s*%d+%)?%s*$", "")
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if text == "" or not text:find("[%w\128-\255]") then return nil end

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

local function IsDone(element)
    return element.completed or element.skip
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

-- Instructions that follow the waypoint in its step, up to the next
-- waypoint group. Consecutive waypoints right after it are treated as the
-- same route chain, so a chain ending in ".goto ... >> Enter the crypt" is
-- labelled by that text.
local function ScanFollowing(elements, index)
    local warning
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
                        else
                            local found = Candidate(text, "following instruction")
                            if found then return found end
                        end
                    end
                end
            end
        end
    end
    return nil, warning
end

-- Instructions before the waypoint, only when it is the step's first waypoint.
local function ScanPreceding(elements, index)
    for i = 1, index - 1 do
        local element = elements[i]
        if type(element) == "table" and IsWaypointElement(element) then return nil end
    end
    for i = 1, index - 1 do
        local element = elements[i]
        if type(element) == "table" and not IsDone(element) then
            local text = InstructionText(element)
            if text and not IsWarning(text) then
                local found = Candidate(text, "preceding instruction")
                if found then return found end
            end
        end
    end
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
        if type(parent) == "table" and not IsDone(parent) then
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
