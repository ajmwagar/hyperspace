-- cellular.lua — Real Game of Life simulation
-- Runs on CPU, uploads grid to GPU state buffer each frame.
-- Audio modulates rule thresholds; beat injects random life.

local W, H = 128, 128
local grid = {}
local next_grid = {}
local step_timer = 0
local step_interval = 0.12  -- ~8 generations per second

-- Initialize grids
for i = 1, W * H do
    grid[i] = 0.0
    next_grid[i] = 0.0
end

local function idx(x, y)
    -- Wrap (torus)
    x = ((x - 1) % W) + 1
    y = ((y - 1) % H) + 1
    return (y - 1) * W + x
end

local function get(x, y)
    return grid[idx(x, y)] > 0.5 and 1 or 0
end

local function set(x, y, v)
    grid[idx(x, y)] = v and 1.0 or 0.0
end

-- Place a glider at (ox, oy)
local function place_glider(ox, oy)
    set(ox+1, oy,   true)
    set(ox+2, oy+1, true)
    set(ox,   oy+2, true)
    set(ox+1, oy+2, true)
    set(ox+2, oy+2, true)
end

-- Place an LWSS at (ox, oy) moving right
local function place_lwss(ox, oy)
    set(ox+1, oy,   true)
    set(ox+4, oy,   true)
    set(ox,   oy+1, true)
    set(ox,   oy+2, true)
    set(ox+4, oy+2, true)
    set(ox,   oy+3, true)
    set(ox+1, oy+3, true)
    set(ox+2, oy+3, true)
    set(ox+3, oy+3, true)
end

-- Place a pulsar at (ox, oy) — period 3 oscillator
local function place_pulsar(ox, oy)
    local cells = {
        {2,0},{3,0},{4,0},{8,0},{9,0},{10,0},
        {0,2},{5,2},{7,2},{12,2},
        {0,3},{5,3},{7,3},{12,3},
        {0,4},{5,4},{7,4},{12,4},
        {2,5},{3,5},{4,5},{8,5},{9,5},{10,5},
        {2,7},{3,7},{4,7},{8,7},{9,7},{10,7},
        {0,8},{5,8},{7,8},{12,8},
        {0,9},{5,9},{7,9},{12,9},
        {0,10},{5,10},{7,10},{12,10},
        {2,12},{3,12},{4,12},{8,12},{9,12},{10,12},
    }
    for _, c in ipairs(cells) do
        set(ox + c[1], oy + c[2], true)
    end
end

-- Place R-pentomino (chaotic, creates lots of debris)
local function place_rpentomino(ox, oy)
    set(ox+1, oy,   true)
    set(ox+2, oy,   true)
    set(ox,   oy+1, true)
    set(ox+1, oy+1, true)
    set(ox+1, oy+2, true)
end

-- Place a blinker
local function place_blinker(ox, oy)
    set(ox, oy, true)
    set(ox+1, oy, true)
    set(ox+2, oy, true)
end

-- Seed initial state
local function seed()
    -- A few gliders
    place_glider(10, 10)
    place_glider(50, 20)
    place_glider(80, 60)
    place_glider(30, 90)

    -- LWSS
    place_lwss(5, 40)
    place_lwss(5, 100)

    -- R-pentomino (creates chaos!)
    place_rpentomino(64, 64)
    place_rpentomino(30, 30)

    -- Pulsar
    place_pulsar(90, 50)

    -- Scattered blinkers
    place_blinker(20, 50)
    place_blinker(70, 30)
    place_blinker(100, 80)
    place_blinker(45, 110)

    -- Random sparse life
    for i = 1, 200 do
        local x = math.random(1, W)
        local y = math.random(1, H)
        set(x, y, true)
    end
end

seed()

function init()
    return grid
end

function update(u)
    step_timer = step_timer + u.dt

    -- Beat injects random life
    if u.beat > 0.5 then
        local count = math.floor(u.beat * 30)
        for i = 1, count do
            local x = math.random(1, W)
            local y = math.random(1, H)
            set(x, y, true)
        end
    end

    -- Step the simulation at fixed rate
    if step_timer < step_interval then
        return grid
    end
    step_timer = step_timer - step_interval

    -- Standard GoL rules with subtle audio modulation
    -- Bass slightly lowers birth threshold (more life)
    -- Mid slightly widens survival (more stable)
    local birth_min = 3 - math.floor(u.bass * 0.3)
    local birth_max = 3
    local survive_min = 2
    local survive_max = 3 + math.floor(u.mid * 0.3)

    for y = 1, H do
        for x = 1, W do
            local neighbors = get(x-1,y-1) + get(x,y-1) + get(x+1,y-1)
                            + get(x-1,y)                 + get(x+1,y)
                            + get(x-1,y+1) + get(x,y+1) + get(x+1,y+1)

            local alive = grid[idx(x, y)] > 0.5
            local new_alive = false

            if alive then
                new_alive = neighbors >= survive_min and neighbors <= survive_max
            else
                new_alive = neighbors >= birth_min and neighbors <= birth_max
            end

            -- Encode: 1.0 = alive, add age info in fractional part
            if new_alive then
                local prev = grid[idx(x, y)]
                if prev > 0.5 then
                    -- Aging cell: increase value (capped at 1.0)
                    next_grid[(y-1)*W + x] = math.min(prev + 0.05, 1.0)
                else
                    -- Newly born
                    next_grid[(y-1)*W + x] = 0.6
                end
            else
                -- Dead: decay slowly for trail effect
                local prev = grid[idx(x, y)]
                next_grid[(y-1)*W + x] = math.max(prev - 0.15, 0.0)
            end
        end
    end

    -- Swap
    grid, next_grid = next_grid, grid

    return grid
end
