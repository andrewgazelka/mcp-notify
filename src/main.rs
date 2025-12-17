use eyre::WrapErr as _;
use std::os::fd::AsRawFd as _;

fn get_lock_file_path() -> eyre::Result<std::path::PathBuf> {
    let home =
        std::env::var("HOME").map_err(|_| eyre::eyre!("HOME environment variable not set"))?;

    let lock_dir = std::path::PathBuf::from(home).join(".notify-lock");
    std::fs::create_dir_all(&lock_dir)
        .wrap_err_with(|| format!("failed to create lock directory at {}", lock_dir.display()))?;

    Ok(lock_dir.join("say.lock"))
}

fn lock_file(file: &std::fs::File) -> std::io::Result<()> {
    let fd = file.as_raw_fd();
    let result = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn speak(text: &str) -> eyre::Result<()> {
    let lock_path = get_lock_file_path()?;
    let lock_file_handle = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .wrap_err_with(|| format!("failed to open lock file at {}", lock_path.display()))?;

    lock_file(&lock_file_handle).wrap_err("failed to acquire lock")?;

    let output = std::process::Command::new("say")
        .arg("-r")
        .arg("300")
        .arg(text)
        .output()
        .wrap_err("failed to execute say command")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        eyre::bail!("say command failed: {}", stderr);
    }

    Ok(())
}

fn main() -> eyre::Result<()> {
    color_eyre::install()?;

    let args: Vec<String> = std::env::args().collect();

    // If called with --exec, actually speak (this is the backgrounded child)
    if args.len() >= 3 && args[1] == "--exec" {
        let text = args[2..].join(" ");
        return speak(&text);
    }

    if args.len() < 2 {
        eyre::bail!("usage: notify <text>");
    }

    let text = args[1..].join(" ");

    // Spawn ourselves in background with --exec flag
    let exe = std::env::current_exe().wrap_err("failed to get current executable")?;
    std::process::Command::new(exe)
        .arg("--exec")
        .arg(&text)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .wrap_err("failed to spawn background process")?;

    Ok(())
}
