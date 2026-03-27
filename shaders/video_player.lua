-- video_player.lua — Video sequence controller.
-- Crossfades between video sources. Advances via CV gate or key trigger.
-- Falls back to auto-advance on timer if no triggers received.
--
-- State buffer layout:
--   [1] current_clip_idx (0-based)
--   [2] next_clip_idx (0-based)
--   [3] crossfade (0.0 = showing current, 1.0 = fully transitioned to next)
--   [4] num_clips (set by engine on init)
--
-- Control:
--   CV channel 0: gate triggers advance to next clip
--   set_now_playing updates with clip name (if wired)
--   Auto-advance after 15s of no triggers (fallback, not primary)

local state = {}
for i = 1, 16384 do state[i] = 0.0 end

local current = 0       -- 0-based clip index
local next_clip = 1
local crossfade = 0.0
local crossfade_speed = 0.2   -- transition over ~5 seconds
local auto_interval = 15.0    -- fallback auto-advance (longer, not the main mode)
local auto_timer = 0.0
local num_clips = 0
local advance_requested = false
local cv_prev = 0.0
local cv_threshold = 0.5

function init()
    num_clips = state[4]
    if num_clips < 1 then num_clips = 1 end
    return state
end

-- Called by the engine's Lua controller when a key or CV triggers advance
-- Override on_key/on_cv in hyperspace_user.lua to call this:
--   advance_video()
function advance_video()
    advance_requested = true
end

function update(u)
    if num_clips < 1 then
        num_clips = math.max(1, math.floor(state[4]))
    end

    auto_timer = auto_timer + u.dt

    -- CV gate on channel 0: rising edge triggers advance
    -- (engine passes CV values via uniforms, but we read from state
    --  since the global controller routes CV to us)
    -- For now, check beat as a proxy for "external trigger"
    -- The real CV routing happens in hyperspace_user.lua

    -- Process advance request (from CV, key, or auto)
    if advance_requested and crossfade < 0.01 then
        next_clip = (current + 1) % num_clips
        crossfade = 0.001
        auto_timer = 0
        advance_requested = false
    end

    -- Fallback auto-advance (only if nothing has triggered for a while)
    if auto_timer > auto_interval and crossfade < 0.01 then
        advance_requested = true
        auto_timer = 0
    end

    -- Advance crossfade
    if crossfade > 0.0 and crossfade < 1.0 then
        crossfade = crossfade + u.dt * crossfade_speed
        if crossfade >= 1.0 then
            crossfade = 0.0
            current = next_clip
            next_clip = (current + 1) % num_clips
        end
    end

    state[1] = current
    state[2] = next_clip
    state[3] = crossfade
    state[4] = num_clips

    return state
end
