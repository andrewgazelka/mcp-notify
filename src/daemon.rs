//! Client side of the `notifyd` connection, plus the readiness decision.
//!
//! The guiding invariant: this module must never make the caller wait. Every
//! path is bounded by an explicit timeout, and every failure is a fast, silent
//! fall-through to the `say` backend.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use crate::config::Settings;
use crate::proto::{self, Request, Response, State};

/// Why the daemon was not used. Only surfaced under `--status` / `NOTIFY_DEBUG`.
#[derive(Debug)]
pub enum Unavailable {
    NoStateFile,
    Unreadable(String),
    DeadPid(i32),
    NotReady { phase: String },
    EngineCold(String),
    ConnectFailed(String),
    NoAck(String),
    Refused { status: String, reason: Option<String> },
}

impl std::fmt::Display for Unavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoStateFile => write!(f, "daemon not running (no state file)"),
            Self::Unreadable(e) => write!(f, "state file unreadable: {e}"),
            Self::DeadPid(p) => write!(f, "stale state file (pid {p} is gone)"),
            Self::NotReady { phase } => write!(f, "daemon not ready (phase: {phase})"),
            Self::EngineCold(e) => write!(f, "engine {e} is still loading"),
            Self::ConnectFailed(e) => write!(f, "connect failed: {e}"),
            Self::NoAck(e) => write!(f, "no ack: {e}"),
            Self::Refused { status, reason } => match reason {
                Some(r) => write!(f, "daemon refused: {status} ({r})"),
                None => write!(f, "daemon refused: {status}"),
            },
        }
    }
}

/// Read the state file and confirm the process behind it is alive.
///
/// This is the whole readiness check: one small read plus a signal-0 probe,
/// tens of microseconds. The `kill` probe is what makes a state file left
/// behind by a SIGKILL harmless instead of a hang.
pub fn read_state(path: &Path) -> Result<State, Unavailable> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(Unavailable::NoStateFile),
        Err(e) => return Err(Unavailable::Unreadable(e.to_string())),
    };
    let state: State =
        serde_json::from_str(&text).map_err(|e| Unavailable::Unreadable(e.to_string()))?;

    if state.pid <= 0 || !pid_alive(state.pid) {
        return Err(Unavailable::DeadPid(state.pid));
    }
    Ok(state)
}

/// `kill(pid, 0)` - does this process exist and can we signal it?
fn pid_alive(pid: i32) -> bool {
    // SAFETY: signal 0 performs error checking only, it delivers nothing.
    let rc = unsafe { libc::kill(pid, 0) };
    if rc == 0 {
        return true;
    }
    // EPERM means it exists but belongs to someone else, which still counts as
    // alive. Only ESRCH proves it is gone.
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Try to hand the utterance to the daemon.
///
/// Returns `Ok(())` only when the daemon has taken ownership. Every `Err` means
/// the caller should fall back to `say`.
pub fn try_speak(settings: &Settings, text: &str) -> Result<(), Unavailable> {
    let state = read_state(&settings.state_file)?;

    if !state.ready {
        return Err(Unavailable::NotReady { phase: state.phase.clone() });
    }
    // The daemon loads `dots` lazily; asking a cold engine to speak would stall.
    if let Some(status) = state.engines.get(settings.engine.as_str())
        && status != "loaded"
    {
        return Err(Unavailable::EngineCold(settings.engine.as_str().to_string()));
    }

    // The daemon publishes the socket it actually bound, which may differ from
    // our config if the two were changed out of step. Trust the daemon.
    let socket = state
        .socket
        .as_deref()
        .map(crate::config::expand_tilde)
        .unwrap_or_else(|| settings.socket.clone());

    // AF_UNIX connect() to a listening socket completes without blocking unless
    // the accept backlog is full, so there is no timeout knob to set here. The
    // real hazard is a daemon that accepts and then wedges, which the read
    // timeout below covers.
    let mut stream =
        UnixStream::connect(&socket).map_err(|e| Unavailable::ConnectFailed(e.to_string()))?;

    let ack = Duration::from_millis(settings.ack_timeout_ms as u64);
    let _ = stream.set_read_timeout(Some(ack));
    let _ = stream.set_write_timeout(Some(ack));

    let id = proto::request_id();
    let req = Request {
        v: proto::PROTOCOL_VERSION,
        op: "speak",
        id: &id,
        text,
        engine: settings.engine.as_str(),
        voice: &settings.voice,
        rate: settings.rate,
        priority: settings.priority.as_str(),
        interrupt: settings.interrupt,
        stale_after_ms: settings.stale_after_ms,
        ack: "queued",
    };

    let mut line = serde_json::to_string(&req).map_err(|e| Unavailable::NoAck(e.to_string()))?;
    line.push('\n');
    stream
        .write_all(line.as_bytes())
        .map_err(|e| Unavailable::NoAck(e.to_string()))?;
    stream.flush().map_err(|e| Unavailable::NoAck(e.to_string()))?;

    let mut reader = BufReader::new(stream);
    let mut resp_line = String::new();
    reader
        .read_line(&mut resp_line)
        .map_err(|e| Unavailable::NoAck(e.to_string()))?;
    if resp_line.trim().is_empty() {
        return Err(Unavailable::NoAck("empty response".into()));
    }

    let resp: Response =
        serde_json::from_str(resp_line.trim()).map_err(|e| Unavailable::NoAck(e.to_string()))?;
    if resp.accepted() {
        Ok(())
    } else {
        Err(Unavailable::Refused { status: resp.status, reason: resp.reason })
    }
}

/// Nudge launchd to (re)start the daemon, at most once per 30 s.
///
/// Deliberately does *not* exec the daemon binary: launchd owns the lifecycle,
/// and a CLI that forks its own copy creates orphans racing for the socket.
///
/// The rate limit is not optional. An agent loop firing `notify` 20x a minute
/// during an outage would otherwise spawn 20 `launchctl` processes a minute.
pub fn maybe_kickstart(settings: &Settings) {
    if !settings.autostart {
        return;
    }
    const MIN_INTERVAL: Duration = Duration::from_secs(30);

    let Some(dir) = settings.state_file.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let stamp = dir.join("last_kick");

    if let Ok(meta) = std::fs::metadata(&stamp)
        && let Ok(modified) = meta.modified()
        && let Ok(age) = modified.elapsed()
        && age < MIN_INTERVAL
    {
        return;
    }
    // Touch first, so concurrent invocations racing here still only produce one
    // burst rather than one kickstart each.
    if std::fs::write(&stamp, b"").is_err() {
        return;
    }

    // SAFETY: getuid never fails.
    let uid = unsafe { libc::getuid() };
    let target = format!("gui/{uid}/{}", settings.label);
    let _ = std::process::Command::new("launchctl")
        .arg("kickstart")
        .arg(&target)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}
