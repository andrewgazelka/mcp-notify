//! The macOS `say` backend and the cross-process utterance lock.
//!
//! The lock is shared with `notifyd`, which takes the same file around playback.
//! That is what stops a `say` fallback from talking over the daemon during
//! warm-up or after a crash.

use eyre::WrapErr as _;
use std::os::fd::AsRawFd as _;
use std::path::PathBuf;

use crate::config;

/// `~/.notify-lock/say.lock`.
///
/// This exact path is load-bearing: `notifyd` opens the same file, so it must
/// not move without changing the daemon too.
pub fn lock_path() -> eyre::Result<PathBuf> {
    let dir = config::home()?.join(".notify-lock");
    std::fs::create_dir_all(&dir)
        .wrap_err_with(|| format!("failed to create lock directory at {}", dir.display()))?;
    Ok(dir.join("say.lock"))
}

/// An advisory `flock(LOCK_EX)` held for the lifetime of the value.
pub struct Utterance {
    file: std::fs::File,
}

impl Utterance {
    /// Blocks until no other `notify` process (or `notifyd`) is speaking.
    pub fn acquire() -> eyre::Result<Self> {
        let path = lock_path()?;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .wrap_err_with(|| format!("failed to open lock file at {}", path.display()))?;

        // SAFETY: `file` owns a valid fd for the duration of the call.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if rc != 0 {
            return Err(std::io::Error::last_os_error()).wrap_err("failed to acquire lock");
        }
        Ok(Self { file })
    }
}

impl Drop for Utterance {
    fn drop(&mut self) {
        // SAFETY: same fd, still open until `file` drops immediately after.
        unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

/// Speak via macOS `say`, serialized against every other utterance.
///
/// `wpm` defaults to 300, matching the tool's long-standing `-r 300`.
pub fn speak(text: &str, wpm: u32, voice: Option<&str>) -> eyre::Result<()> {
    let _guard = Utterance::acquire()?;

    let mut cmd = std::process::Command::new("say");
    cmd.arg("-r").arg(wpm.to_string());
    if let Some(v) = voice {
        cmd.arg("-v").arg(v);
    }
    // `--` so text beginning with a dash is never parsed as a flag by `say`.
    cmd.arg("--").arg(text);

    let output = cmd.output().wrap_err("failed to execute say command")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        eyre::bail!("say command failed: {}", stderr.trim());
    }
    Ok(())
}
