use anyhow::Result;
use mlua::prelude::*;
use std::path::Path;

/// Max state buffer size per script (128×128 grid = 16384 floats).
pub const STATE_BUFFER_SIZE: usize = 16384;

/// Convert mlua::Error to anyhow::Error (mlua Error isn't Send+Sync).
fn lua_err(e: LuaError) -> anyhow::Error {
    anyhow::anyhow!("{}", e)
}

/// Per-shader Lua scripting context.
pub struct ShaderScript {
    lua: Lua,
    pub state: Vec<f32>,
}

/// Uniform data passed to Lua's update() function.
pub struct ScriptUniforms {
    pub time: f32,
    pub delta_time: f32,
    pub amplitude: f32,
    pub beat: f32,
    pub bass: f32,
    pub mid: f32,
    pub high: f32,
    pub amplitude_l: f32,
    pub amplitude_r: f32,
}

impl ShaderScript {
    /// Try to load a Lua script matching a shader path.
    /// e.g. "shaders/cellular.wgsl" → "shaders/cellular.lua"
    pub fn load_for_shader(shader_path: &str) -> Result<Option<Self>> {
        let lua_path = shader_path.replace(".wgsl", ".lua");
        if !Path::new(&lua_path).exists() {
            return Ok(None);
        }

        log::info!("loading lua script: {}", lua_path);

        let lua = Lua::new();
        let source = std::fs::read_to_string(&lua_path)?;
        lua.load(&source).exec().map_err(lua_err)?;

        let mut script = Self {
            lua,
            state: vec![0.0; STATE_BUFFER_SIZE],
        };

        script.call_init()?;
        Ok(Some(script))
    }

    fn call_init(&mut self) -> Result<()> {
        let globals = self.lua.globals();
        if let Ok(init_fn) = globals.get::<LuaFunction>("init") {
            let result: LuaResult<LuaTable> = init_fn.call(());
            if let Ok(table) = result {
                self.read_state_from_table(&table);
            }
        }
        Ok(())
    }

    /// Call update(uniforms) and read back state buffer.
    pub fn update(&mut self, uniforms: &ScriptUniforms) -> Result<()> {
        let globals = self.lua.globals();
        let update_fn: LuaFunction = match globals.get("update") {
            Ok(f) => f,
            Err(_) => return Ok(()),
        };

        let u = self.lua.create_table().map_err(lua_err)?;
        u.set("time", uniforms.time).map_err(lua_err)?;
        u.set("dt", uniforms.delta_time).map_err(lua_err)?;
        u.set("amplitude", uniforms.amplitude).map_err(lua_err)?;
        u.set("beat", uniforms.beat).map_err(lua_err)?;
        u.set("bass", uniforms.bass).map_err(lua_err)?;
        u.set("mid", uniforms.mid).map_err(lua_err)?;
        u.set("high", uniforms.high).map_err(lua_err)?;
        u.set("amplitude_l", uniforms.amplitude_l).map_err(lua_err)?;
        u.set("amplitude_r", uniforms.amplitude_r).map_err(lua_err)?;

        let result: LuaResult<LuaTable> = update_fn.call(u);
        match result {
            Ok(table) => self.read_state_from_table(&table),
            Err(e) => log::warn!("lua update error: {}", e),
        }

        Ok(())
    }

    fn read_state_from_table(&mut self, table: &LuaTable) {
        let len = table.len().unwrap_or(0) as usize;
        let count = len.min(STATE_BUFFER_SIZE);
        for i in 0..count {
            if let Ok(v) = table.get::<f32>(i + 1) {
                self.state[i] = v;
            }
        }
    }
}
