-- video_player.lua — Video sequence controller.
-- Manages crossfading between video sources, triggered by beat or timer.
--
-- State buffer layout:
--   [1] current_clip_idx (0-based)
--   [2] next_clip_idx (0-based)
--   [3] crossfade (0.0 = showing current, 1.0 = fully transitioned to next)
--   [4] num_clips (set by engine on init)

local state = {}
for i = 1, 16384 do state[i] = 0.0 end

local current = 0       -- 0-based clip index
local next_clip = 1
local crossfade = 0.0
local crossfade_speed = 0.15  -- transition over ~6 seconds
local auto_interval = 10.0    -- auto-advance every N seconds
local auto_timer = 0.0
local num_clips = 0
local beat_cooldown = 0.0

function init()
    num_clips = state[4]  -- engine sets this
    if num_clips < 1 then num_clips = 1 end
    return state
end

function update(u)
    if num_clips < 1 then
        num_clips = math.max(1, math.floor(state[4]))
    end

    beat_cooldown = math.max(0, beat_cooldown - u.dt)
    auto_timer = auto_timer + u.dt

    -- Beat-triggered advance (with cooldown)
    if u.beat > 0.7 and beat_cooldown <= 0 and crossfade < 0.01 then
        -- Start crossfade to next clip
        next_clip = (current + 1) % num_clips
        crossfade = 0.001  -- start transition
        beat_cooldown = 4.0
        auto_timer = 0
    end

    -- Auto-advance on timer
    if auto_timer > auto_interval and crossfade < 0.01 then
        next_clip = (current + 1) % num_clips
        crossfade = 0.001
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
