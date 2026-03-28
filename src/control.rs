use anyhow::Result;
use mlua::prelude::*;
use std::sync::{Arc, Mutex};

use crate::scene::SceneConfig;

/// Shared state that Lua can read/write and Rust can act on.
#[derive(Debug, Clone, Default)]
pub struct ControlState {
    /// Scene to switch to (set by Lua, consumed by main loop)
    pub pending_scene: Option<String>,
    /// Now playing metadata
    pub now_playing_artist: String,
    pub now_playing_title: String,
    pub now_playing_changed: bool,
    /// Video overlay toggles (key → toggle request)
    pub video_toggles: Vec<String>,
    /// Clip triggers (clip name)
    pub clip_triggers: Vec<String>,
    /// Advance video sequence (triggered by CV/key)
    pub advance_video: bool,
}

pub type SharedControlState = Arc<Mutex<ControlState>>;

/// The global Lua controller.
/// Loads hyperspace.lua (default, auto-generated) then hyperspace_user.lua (overrides).
pub struct Controller {
    lua: Lua,
    shared: SharedControlState,
}

impl Controller {
    pub fn new(config: &SceneConfig) -> Result<(Self, SharedControlState)> {
        let lua = Lua::new();
        let shared: SharedControlState = Arc::new(Mutex::new(ControlState::default()));

        // Set now_playing from config if present
        if let Some(ref np) = config.audio.now_playing {
            let mut state = shared.lock().unwrap();
            if let Some((artist, title)) = np.split_once(" - ") {
                state.now_playing_artist = artist.trim().to_string();
                state.now_playing_title = title.trim().to_string();
            } else {
                state.now_playing_title = np.clone();
            }
            state.now_playing_changed = true;
        }

        // Register Rust API functions into Lua globals
        Self::register_api(&lua, shared.clone())?;

        // Generate default controller from config
        let default_lua = Self::generate_default_lua(config);
        lua.load(&default_lua).exec().map_err(lua_err)?;

        // Load user overrides if they exist
        if std::path::Path::new("hyperspace_user.lua").exists() {
            log::info!("loading user controller overrides: hyperspace_user.lua");
            let user_src = std::fs::read_to_string("hyperspace_user.lua")?;
            lua.load(&user_src).exec().map_err(lua_err)?;
        }

        let controller = Self { lua, shared: shared.clone() };
        Ok((controller, shared))
    }

    fn register_api(lua: &Lua, shared: SharedControlState) -> Result<()> {
        let globals = lua.globals();

        // set_scene(path)
        let s = shared.clone();
        let set_scene = lua.create_function(move |_, path: String| {
            s.lock().unwrap().pending_scene = Some(path);
            Ok(())
        }).map_err(lua_err)?;
        globals.set("set_scene", set_scene).map_err(lua_err)?;

        // set_now_playing(artist, title)
        let s = shared.clone();
        let set_np = lua.create_function(move |_, (artist, title): (String, String)| {
            let mut state = s.lock().unwrap();
            state.now_playing_artist = artist;
            state.now_playing_title = title;
            state.now_playing_changed = true;
            Ok(())
        }).map_err(lua_err)?;
        globals.set("set_now_playing", set_np).map_err(lua_err)?;

        // toggle_video(key)
        let s = shared.clone();
        let toggle_vid = lua.create_function(move |_, key: String| {
            s.lock().unwrap().video_toggles.push(key);
            Ok(())
        }).map_err(lua_err)?;
        globals.set("toggle_video", toggle_vid).map_err(lua_err)?;

        // trigger_clip(name)
        let s = shared.clone();
        let trigger_clip = lua.create_function(move |_, name: String| {
            s.lock().unwrap().clip_triggers.push(name);
            Ok(())
        }).map_err(lua_err)?;
        globals.set("trigger_clip", trigger_clip).map_err(lua_err)?;

        // advance_video()
        let s = shared.clone();
        let adv_vid = lua.create_function(move |_, ()| {
            s.lock().unwrap().advance_video = true;
            Ok(())
        }).map_err(lua_err)?;
        globals.set("advance_video", adv_vid).map_err(lua_err)?;

        // log_info(msg)
        let log_fn = lua.create_function(|_, msg: String| {
            log::info!("[lua] {}", msg);
            Ok(())
        }).map_err(lua_err)?;
        globals.set("log_info", log_fn).map_err(lua_err)?;

        Ok(())
    }

    /// Generate the default hyperspace.lua from TOML config.
    /// This builds the on_cv, on_key, on_beat handlers from config values.
    fn generate_default_lua(config: &SceneConfig) -> String {
        let mut lua = String::new();
        lua.push_str("-- Auto-generated default controller from scene config.\n");
        lua.push_str("-- Override any function in hyperspace_user.lua.\n\n");

        // Build on_key handler from clips
        lua.push_str("function on_key(key)\n");
        for clip in &config.clips {
            if let Some(ref k) = clip.key {
                lua.push_str(&format!(
                    "  if key == \"{}\" then trigger_clip(\"{}\") return end\n",
                    k, clip.name
                ));
            }
        }
        lua.push_str("end\n\n");

        // Build on_cv handler from clips + video overlays
        lua.push_str("-- CV routing: channel 0 = advance video sequence (default)\n");
        lua.push_str("local cv_prev = {}\n");
        lua.push_str("function on_cv(channel, value)\n");
        // CV 0: advance video on rising edge
        lua.push_str("  if channel == 0 then\n");
        lua.push_str("    local was_high = cv_prev[0] or false\n");
        lua.push_str("    local is_high = value > 0.5\n");
        lua.push_str("    if is_high and not was_high then advance_video() end\n");
        lua.push_str("    cv_prev[0] = is_high\n");
        lua.push_str("  end\n");
        for clip in &config.clips {
            if let Some(ch) = clip.cv_channel {
                lua.push_str(&format!(
                    "  if channel == {} and value > {} then trigger_clip(\"{}\") end\n",
                    ch, clip.cv_threshold, clip.name
                ));
            }
        }
        lua.push_str("end\n\n");

        // on_beat: default no-op
        lua.push_str("function on_beat()\n");
        lua.push_str("end\n\n");

        // on_tick: default no-op (called every frame with dt)
        lua.push_str("function on_tick(dt)\n");
        lua.push_str("end\n\n");

        // get_now_playing: returns current state (set via set_now_playing API)
        lua.push_str("function get_now_playing()\n");
        lua.push_str("  return nil, nil\n");
        lua.push_str("end\n\n");

        lua
    }

    /// Call on_key(key) in Lua.
    pub fn on_key(&self, key: &str) {
        if let Ok(f) = self.lua.globals().get::<LuaFunction>("on_key") {
            if let Err(e) = f.call::<()>(key.to_string()) {
                log::warn!("on_key error: {}", e);
            }
        }
    }

    /// Call on_cv(channel, value) in Lua.
    pub fn on_cv(&self, channel: usize, value: f32) {
        if let Ok(f) = self.lua.globals().get::<LuaFunction>("on_cv") {
            if let Err(e) = f.call::<()>((channel as u32, value)) {
                log::warn!("on_cv error: {}", e);
            }
        }
    }

    /// Call on_beat() in Lua.
    pub fn on_beat(&self) {
        if let Ok(f) = self.lua.globals().get::<LuaFunction>("on_beat") {
            if let Err(e) = f.call::<()>(()) {
                log::warn!("on_beat error: {}", e);
            }
        }
    }

    /// Call on_tick(dt) in Lua — called every frame for timer-based logic.
    pub fn on_tick(&self, dt: f32) {
        if let Ok(f) = self.lua.globals().get::<LuaFunction>("on_tick") {
            if let Err(e) = f.call::<()>(dt) {
                log::warn!("on_tick error: {}", e);
            }
        }
    }

    /// Drain pending actions from shared state.
    pub fn drain(&self) -> ControlState {
        let mut state = self.shared.lock().unwrap();
        let snapshot = state.clone();
        state.pending_scene = None;
        state.video_toggles.clear();
        state.clip_triggers.clear();
        state.now_playing_changed = false;
        state.advance_video = false;
        snapshot
    }
}

fn lua_err(e: LuaError) -> anyhow::Error {
    anyhow::anyhow!("{}", e)
}
