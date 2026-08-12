//! Configuration: defaults, TOML file, environment, and CLI flags.
//!
//! Resolution order is `flags > env > file > defaults`, applied **per field**
//! rather than per struct, so setting one value in the config file does not
//! silently reset its neighbours.

use eyre::WrapErr as _;
use serde::Deserialize;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Backend {
    /// Use the daemon when it is ready, otherwise fall back to `say`.
    #[default]
    Auto,
    /// Require the daemon; fall back to `say` only if it cannot be reached.
    Daemon,
    /// Always use macOS `say`.
    Say,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Engine {
    /// Holler 0.6B (Qwen3-TTS finetune), 24 kHz, preset voices, streaming.
    #[default]
    Holler,
    /// dots.tts-soar, 48 kHz continuous AR, clone-only.
    Dots,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Priority {
    Low,
    #[default]
    Normal,
    High,
}

impl Backend {
    pub fn parse(s: &str) -> eyre::Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" => Ok(Self::Auto),
            "daemon" => Ok(Self::Daemon),
            "say" => Ok(Self::Say),
            other => eyre::bail!("unknown backend {other:?} (expected auto, daemon, or say)"),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Daemon => "daemon",
            Self::Say => "say",
        }
    }
}

impl Engine {
    pub fn parse(s: &str) -> eyre::Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "holler" => Ok(Self::Holler),
            "dots" => Ok(Self::Dots),
            other => eyre::bail!("unknown engine {other:?} (expected holler or dots)"),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Holler => "holler",
            Self::Dots => "dots",
        }
    }
}

impl Priority {
    pub fn parse(s: &str) -> eyre::Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "low" => Ok(Self::Low),
            "normal" => Ok(Self::Normal),
            "high" => Ok(Self::High),
            other => eyre::bail!("unknown priority {other:?} (expected low, normal, or high)"),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Normal => "normal",
            Self::High => "high",
        }
    }
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Words per minute for the `say` fallback.
///
/// Deliberately decoupled from [`Settings::rate`]: deriving it (175 * 1.5) would
/// make the fallback audibly slower than the tool has always been.
pub const DEFAULT_SAY_WPM: u32 = 300;
pub const DEFAULT_RATE: f32 = 1.5;
pub const DEFAULT_VOICE: &str = "oliver";
pub const DEFAULT_STALE_AFTER_MS: u32 = 30_000;
pub const DEFAULT_CONNECT_TIMEOUT_MS: u32 = 20;
pub const DEFAULT_ACK_TIMEOUT_MS: u32 = 25;
pub const DEFAULT_LAUNCHD_LABEL: &str = "org.nix-community.home.notifyd";

/// `AVAudioUnitTimePitch` accepts 1/32..32, but anything outside this window is
/// unintelligible for speech. Clamp rather than reject so a typo degrades
/// gracefully instead of dropping the message.
pub const RATE_MIN: f32 = 0.5;
pub const RATE_MAX: f32 = 3.0;

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

pub fn home() -> eyre::Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| eyre::eyre!("HOME environment variable not set"))
}

/// Expand a leading `~` or `$HOME`. Config files are hand-edited and nix-generated,
/// and both write tildes.
pub fn expand_tilde(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/").or_else(|| s.strip_prefix("$HOME/")) {
        if let Ok(h) = home() {
            return h.join(rest);
        }
    }
    if s == "~" || s == "$HOME" {
        if let Ok(h) = home() {
            return h;
        }
    }
    PathBuf::from(s)
}

/// `$XDG_CONFIG_HOME/notify/config.toml`, falling back to `~/.config`.
///
/// Deliberately hand-rolled instead of using the `dirs`/`directories` crate:
/// those return `~/Library/Application Support/notify` on macOS, which is wrong
/// for a nix/home-manager dotfiles setup where everything else lives in
/// `~/.config`.
pub fn config_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("NOTIFY_CONFIG") {
        let p = PathBuf::from(p);
        return if p.as_os_str().is_empty() { None } else { Some(p) };
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| home().ok().map(|h| h.join(".config")))?;
    Some(base.join("notify").join("config.toml"))
}

/// `$XDG_STATE_HOME/notify`, falling back to `~/.local/state/notify`.
/// Shared with `notifyd`, which is told the same path via `NOTIFY_STATE_DIR`.
pub fn state_dir() -> eyre::Result<PathBuf> {
    if let Some(p) = std::env::var_os("NOTIFY_STATE_DIR") {
        let p = PathBuf::from(p);
        if !p.as_os_str().is_empty() {
            return Ok(p);
        }
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .map(Ok)
        .unwrap_or_else(|| home().map(|h| h.join(".local").join("state")))?;
    Ok(base.join("notify"))
}

// ---------------------------------------------------------------------------
// TOML file shape
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct FileConfig {
    pub backend: Option<String>,
    pub engine: Option<String>,
    pub voice: Option<String>,
    pub rate: Option<f32>,
    pub priority: Option<String>,
    pub stale_after_ms: Option<u32>,
    pub say: SayFile,
    pub daemon: DaemonFile,
    /// Engine-specific tables are consumed by `notifyd`, not by this CLI. They
    /// are accepted and ignored here so that `deny_unknown_fields` does not
    /// reject a perfectly valid shared config file.
    #[serde(rename = "holler")]
    pub _holler: Option<toml::Value>,
    #[serde(rename = "dots")]
    pub _dots: Option<toml::Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct SayFile {
    pub wpm: Option<u32>,
    pub voice: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct DaemonFile {
    pub socket: Option<String>,
    pub state: Option<String>,
    pub connect_timeout_ms: Option<u32>,
    pub ack_timeout_ms: Option<u32>,
    pub autostart: Option<bool>,
    pub label: Option<String>,
}

impl FileConfig {
    /// A missing file is not an error: the tool must work with zero setup.
    /// A malformed file *is* an error, but only a soft one — see [`load_or_warn`].
    pub fn load(path: &Path) -> eyre::Result<Option<Self>> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                return Err(e).wrap_err_with(|| format!("failed to read {}", path.display()));
            }
        };
        let cfg: Self = toml::from_str(&text)
            .wrap_err_with(|| format!("failed to parse {}", path.display()))?;
        Ok(Some(cfg))
    }

    /// Load, but never let a broken config file make the machine go silent.
    /// A bad config warns on stderr and falls through to defaults.
    pub fn load_or_warn(path: &Path) -> Self {
        match Self::load(path) {
            Ok(Some(c)) => c,
            Ok(None) => Self::default(),
            Err(e) => {
                eprintln!("notify: ignoring config: {e:#}");
                Self::default()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Resolved settings
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Settings {
    pub backend: Backend,
    pub engine: Engine,
    pub voice: String,
    pub rate: f32,
    pub priority: Priority,
    pub interrupt: bool,
    pub stale_after_ms: u32,
    pub say_wpm: u32,
    pub say_voice: Option<String>,
    pub socket: PathBuf,
    pub state_file: PathBuf,
    pub connect_timeout_ms: u32,
    pub ack_timeout_ms: u32,
    pub autostart: bool,
    pub label: String,
}

impl Settings {
    /// Layer file, then env, then flags. Each layer only overrides the fields it
    /// actually sets.
    pub fn resolve(file: &FileConfig, flags: &Flags) -> eyre::Result<Self> {
        let sd = state_dir()?;

        let mut s = Settings {
            backend: Backend::default(),
            engine: Engine::default(),
            voice: DEFAULT_VOICE.to_string(),
            rate: DEFAULT_RATE,
            priority: Priority::default(),
            interrupt: false,
            stale_after_ms: DEFAULT_STALE_AFTER_MS,
            say_wpm: DEFAULT_SAY_WPM,
            say_voice: None,
            socket: sd.join("notifyd.sock"),
            state_file: sd.join("notifyd.json"),
            connect_timeout_ms: DEFAULT_CONNECT_TIMEOUT_MS,
            ack_timeout_ms: DEFAULT_ACK_TIMEOUT_MS,
            autostart: true,
            label: DEFAULT_LAUNCHD_LABEL.to_string(),
        };

        // --- layer 1: file -------------------------------------------------
        if let Some(v) = &file.backend {
            s.backend = Backend::parse(v)?;
        }
        if let Some(v) = &file.engine {
            s.engine = Engine::parse(v)?;
        }
        if let Some(v) = &file.voice {
            s.voice = v.clone();
        }
        if let Some(v) = file.rate {
            s.rate = v;
        }
        if let Some(v) = &file.priority {
            s.priority = Priority::parse(v)?;
        }
        if let Some(v) = file.stale_after_ms {
            s.stale_after_ms = v;
        }
        if let Some(v) = file.say.wpm {
            s.say_wpm = v;
        }
        if let Some(v) = &file.say.voice {
            s.say_voice = Some(v.clone());
        }
        if let Some(v) = &file.daemon.socket {
            s.socket = expand_tilde(v);
        }
        if let Some(v) = &file.daemon.state {
            s.state_file = expand_tilde(v);
        }
        if let Some(v) = file.daemon.connect_timeout_ms {
            s.connect_timeout_ms = v;
        }
        if let Some(v) = file.daemon.ack_timeout_ms {
            s.ack_timeout_ms = v;
        }
        if let Some(v) = file.daemon.autostart {
            s.autostart = v;
        }
        if let Some(v) = &file.daemon.label {
            s.label = v.clone();
        }

        // --- layer 2: environment ------------------------------------------
        if let Ok(v) = std::env::var("NOTIFY_BACKEND") {
            s.backend = Backend::parse(&v)?;
        }
        if let Ok(v) = std::env::var("NOTIFY_ENGINE") {
            s.engine = Engine::parse(&v)?;
        }
        if let Ok(v) = std::env::var("NOTIFY_VOICE") {
            s.voice = v;
        }
        if let Ok(v) = std::env::var("NOTIFY_RATE") {
            s.rate = v
                .parse()
                .wrap_err_with(|| format!("NOTIFY_RATE={v:?} is not a number"))?;
        }
        if let Ok(v) = std::env::var("NOTIFY_PRIORITY") {
            s.priority = Priority::parse(&v)?;
        }
        if let Ok(v) = std::env::var("NOTIFY_SOCKET") {
            s.socket = expand_tilde(&v);
        }

        // --- layer 3: flags -------------------------------------------------
        if let Some(v) = flags.backend {
            s.backend = v;
        }
        if let Some(v) = flags.engine {
            s.engine = v;
        }
        if let Some(v) = &flags.voice {
            s.voice = v.clone();
        }
        if let Some(v) = flags.rate {
            s.rate = v;
        }
        if let Some(v) = flags.priority {
            s.priority = v;
        }
        if flags.interrupt {
            s.interrupt = true;
        }

        s.rate = s.rate.clamp(RATE_MIN, RATE_MAX);
        Ok(s)
    }
}

/// Values supplied on the command line. `None` means "not specified", which is
/// what lets the per-field layering work.
#[derive(Debug, Default)]
pub struct Flags {
    pub backend: Option<Backend>,
    pub engine: Option<Engine>,
    pub voice: Option<String>,
    pub rate: Option<f32>,
    pub priority: Option<Priority>,
    pub interrupt: bool,
}
