-- gforce.lua — G-Force preset manager
-- Controls flow field, wave shape, colormap, and transitions.
-- Beat triggers preset changes. Time drives slow transitions.
--
-- State buffer layout (matches gforce.wgsl):
--   [1] flow_style     0=spiral, 1=breathe, 2=drift, 3=diamond
--   [2] wave_shape     0=circle, 1=ribbon, 2=star, 3=lissajous
--   [3] colormap       0=fire, 1=ocean, 2=neon, 3=sunset
--   [4] decay          0.0-1.0
--   [5] flow_speed     flow intensity multiplier
--   [6] wave_thickness line width
--   [7] colormap_speed palette cycling rate
--   [8] colormap_offset palette phase
--   [9] wave_intensity brightness of new waveshape

local state = {}
for i = 1, 16384 do state[i] = 0.0 end

-- Presets: named combinations of layers
local presets = {
    {
        name = "cosmic spiral",
        flow = 0, wave = 0, cmap = 2,
        decay = 0.96, flow_speed = 1.2,
        thickness = 0.012, cmap_speed = 0.03, intensity = 1.2,
    },
    {
        name = "ocean ribbon",
        flow = 2, wave = 1, cmap = 1,
        decay = 0.94, flow_speed = 0.8,
        thickness = 0.008, cmap_speed = 0.02, intensity = 1.0,
    },
    {
        name = "fire star",
        flow = 0, wave = 2, cmap = 0,
        decay = 0.97, flow_speed = 1.5,
        thickness = 0.015, cmap_speed = 0.04, intensity = 1.5,
    },
    {
        name = "neon lissajous",
        flow = 3, wave = 3, cmap = 2,
        decay = 0.93, flow_speed = 0.6,
        thickness = 0.006, cmap_speed = 0.05, intensity = 0.8,
    },
    {
        name = "sunset breath",
        flow = 1, wave = 0, cmap = 3,
        decay = 0.95, flow_speed = 1.0,
        thickness = 0.01, cmap_speed = 0.015, intensity = 1.1,
    },
    {
        name = "diamond drift",
        flow = 3, wave = 2, cmap = 0,
        decay = 0.96, flow_speed = 1.3,
        thickness = 0.018, cmap_speed = 0.025, intensity = 1.3,
    },
    {
        name = "deep ocean circle",
        flow = 2, wave = 0, cmap = 1,
        decay = 0.97, flow_speed = 0.5,
        thickness = 0.01, cmap_speed = 0.01, intensity = 0.9,
    },
    {
        name = "neon ribbon spiral",
        flow = 0, wave = 1, cmap = 2,
        decay = 0.95, flow_speed = 1.1,
        thickness = 0.007, cmap_speed = 0.06, intensity = 1.0,
    },
}

local current_preset = 1
local preset_timer = 0
local preset_interval = 12  -- seconds between auto-transitions
local beat_cooldown = 0
local cmap_phase = 0

local function apply_preset(idx)
    local p = presets[idx]
    log_msg = p.name  -- for debug
    state[1] = p.flow
    state[2] = p.wave
    state[3] = p.cmap
    state[4] = p.decay
    state[5] = p.flow_speed
    state[6] = p.thickness
    state[7] = p.cmap_speed
    state[9] = p.intensity
end

-- Initial preset
apply_preset(1)

function init()
    return state
end

function update(u)
    preset_timer = preset_timer + u.dt
    beat_cooldown = math.max(0, beat_cooldown - u.dt)

    -- Beat-triggered preset change (with cooldown to avoid rapid switching)
    if u.beat > 0.7 and beat_cooldown <= 0 then
        current_preset = (current_preset % #presets) + 1
        apply_preset(current_preset)
        beat_cooldown = 3.0  -- minimum 3 sec between beat-triggered changes
        preset_timer = 0
    end

    -- Auto-transition on timer
    if preset_timer > preset_interval then
        current_preset = (current_preset % #presets) + 1
        apply_preset(current_preset)
        preset_timer = 0
    end

    -- Continuously advance colormap phase
    cmap_phase = cmap_phase + u.dt * state[7]
    state[8] = cmap_phase

    -- Audio-reactive tweaks on top of preset
    -- Bass slightly increases decay (longer trails on heavy bass)
    state[4] = presets[current_preset].decay + u.bass * 0.02
    -- Amplitude boosts flow speed
    state[5] = presets[current_preset].flow_speed * (1.0 + u.amplitude * 0.3)

    return state
end
