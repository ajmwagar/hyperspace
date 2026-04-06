-- video_player.lua — Video sequence controller.
-- Crossfades between video sources. Advances via CV gate, key, or auto-timer.
--
-- State buffer layout (written to engine):
--   [1] current_clip_idx (0-based)
--   [2] next_clip_idx (0-based)
--   [3] crossfade (0.0 = showing current, 1.0 = fully transitioned to next)
--
-- Engine writes num_clips into state[4] before first update.

local state = {}
for i = 1, 16384 do state[i] = 0.0 end

local current = 0
local next_c = 1
local crossfade = 0.0
local crossfade_speed = 0.2
local auto_interval = 15.0
local auto_timer = 0.0
local advance_requested = false

-- Called externally by engine (from CV/key via controller)
function advance_video()
    advance_requested = true
end

function update(u)
    -- Read num_clips from engine (set as global before each update)
    local num_clips = math.max(1, NUM_CLIPS or 1)

    auto_timer = auto_timer + u.dt

    -- Auto-advance on timer
    if auto_timer > auto_interval and crossfade < 0.01 then
        advance_requested = true
        auto_timer = 0
    end

    -- Process advance
    if advance_requested and crossfade < 0.01 then
        next_c = (current + 1) % num_clips
        crossfade = 0.001
        auto_timer = 0
        advance_requested = false
    end

    -- Advance crossfade
    if crossfade > 0.0 and crossfade < 1.0 then
        crossfade = crossfade + u.dt * crossfade_speed
        if crossfade >= 1.0 then
            crossfade = 0.0
            current = next_c
            next_c = (current + 1) % num_clips
        end
    end

    state[1] = current
    state[2] = next_c
    state[3] = crossfade
    -- state[4] is written by engine, don't overwrite it

    return state
end
