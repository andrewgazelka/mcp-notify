//! Wire format for the `notify` -> `notifyd` unix socket.
//!
//! Newline-delimited JSON, one request per connection. Messages are ~200 bytes,
//! so length-prefix framing would buy nothing and cost framing bugs; this way
//! the whole protocol is debuggable with `nc -U`.
//!
//! Both sides ignore unknown fields; `v` gates breaking changes.

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Serialize)]
pub struct Request<'a> {
    pub v: u32,
    pub op: &'a str,
    pub id: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    pub text: &'a str,
    pub engine: &'a str,
    pub voice: &'a str,
    pub rate: f32,
    pub priority: &'a str,
    pub interrupt: bool,
    pub stale_after_ms: u32,
    /// `none` | `queued` | `started` | `done`. The CLI always asks for `queued`
    /// so it can exit as soon as the daemon owns the message.
    pub ack: &'a str,
}

#[derive(Debug, Deserialize)]
pub struct Response {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub queue_depth: Option<u32>,
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default)]
    pub ready: Option<bool>,
}

impl Response {
    /// Did the daemon take ownership of the utterance?
    pub fn accepted(&self) -> bool {
        // `dropped` (dedupe / backpressure) is a deliberate daemon decision, not
        // a failure: re-speaking it via `say` would defeat the whole policy.
        matches!(self.status.as_str(), "queued" | "started" | "done" | "dropped")
    }
}

/// The daemon's state file, `~/.local/state/notify/notifyd.json`.
///
/// Read by the CLI on every invocation to decide, without a round trip, whether
/// the daemon is worth talking to.
#[derive(Debug, Deserialize)]
pub struct State {
    #[serde(default)]
    pub v: u32,
    #[serde(default)]
    pub pid: i32,
    #[serde(default)]
    pub socket: Option<String>,
    #[serde(default)]
    pub ready: bool,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub engines: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub download: Option<Download>,
}

#[derive(Debug, Deserialize)]
pub struct Download {
    #[serde(default)]
    pub repo: String,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub total: u64,
}

/// A cheap unique-enough id. Avoids pulling in a uuid crate for what is only a
/// correlation token in a log line.
pub fn request_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", std::process::id(), nanos)
}
