-- hyperspace_user.lua — Playlist listening mode controller.
-- Cycles through scenes with varying durations.
-- Video sequences get extra time for a full loop.
-- Post-processing rotates within video stages.
--
-- Controls:
--   b     = skip to next stage
--   CV 1  = gate advances playlist
--
-- To use: just run with scenes/all_series.toml
--   cargo run -- scenes/all_series.toml

-- ============================================================
-- PLAYLIST
-- ============================================================
local playlist = {
    -- Pure shaders (2-3 min each)
    { scene = "scenes/gforce.toml",       duration = 150, desc = "G-Force feedback" },
    { scene = "scenes/default.toml",      duration = 120, desc = "Tunnel + Gauges" },
    { scene = "scenes/composed.toml",     duration = 120, desc = "Scope spiral + Classic fire" },

    -- Space footage (4 min — full loop through 14 clips)
    { scene = "scenes/space_reel.toml",   duration = 240, desc = "Apollo space reel" },

    -- More shaders
    { scene = "scenes/vortex.toml",       duration = 120, desc = "Plasma vortex + Fractal" },
    { scene = "scenes/retrowave.toml",    duration = 120, desc = "Neon grid retrowave" },

    -- Blade Runner (4 min — full loop through 7 clips)
    { scene = "scenes/bladerunner.toml",  duration = 240, desc = "Blade Runner reel" },

    -- G-Force again with different feel (playlist wraps)
    { scene = "scenes/gforce.toml",       duration = 150, desc = "G-Force (encore)" },
}

local current_idx = 1
local stage_timer = 0
local loaded_scene = nil

local function advance()
    current_idx = (current_idx % #playlist) + 1
    local entry = playlist[current_idx]
    log_info("playlist: [" .. current_idx .. "/" .. #playlist .. "] " .. entry.desc .. " (" .. entry.duration .. "s)")
    set_scene(entry.scene)
    loaded_scene = entry.scene
    stage_timer = 0
end

-- Load first stage on startup
local first = playlist[1]
log_info("playlist: starting — " .. #playlist .. " stages")
log_info("playlist: [1/" .. #playlist .. "] " .. first.desc .. " (" .. first.duration .. "s)")
set_scene(first.scene)
loaded_scene = first.scene

-- ============================================================
-- Handlers
-- ============================================================

local last_log = 0

function on_tick(dt)
    stage_timer = stage_timer + dt
    -- Log progress every 30 seconds
    if math.floor(stage_timer) >= last_log + 30 then
        last_log = math.floor(stage_timer)
        local entry = playlist[current_idx]
        local remaining = entry.duration - stage_timer
        log_info(string.format("playlist: %ds / %ds remaining (stage %d/%d)",
            math.floor(stage_timer), entry.duration, current_idx, #playlist))
    end
    local entry = playlist[current_idx]
    if stage_timer >= entry.duration then
        advance()
    end
end

function on_key(key)
    if key == "b" then
        advance()
    end
end

function on_cv(channel, value)
    -- CV 1 rising edge: advance playlist
    if channel == 1 then
        local was_high = _cv1_prev or false
        local is_high = value > 0.5
        if is_high and not was_high then
            advance()
        end
        _cv1_prev = is_high
    end
end

function on_beat()
    -- No beat-driven playlist changes
end
