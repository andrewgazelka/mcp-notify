//! `notify` - speak short status updates on macOS.
//!
//! Two properties define this tool and must survive every change:
//!
//! 1. **You never wait.** The caller returns in bounded time and audio starts
//!    promptly, even when the neural backend is cold, broken, or absent.
//! 2. **Messages never overlap.** Utterances are serialized, including across
//!    the boundary between the daemon and the `say` fallback.

mod config;
mod daemon;
mod proto;
mod say;

use config::{Backend, Engine, Flags, Priority, Settings};

const USAGE: &str = "\
notify - speak short status updates

usage:
  notify [options] <text>...
  notify --status

options:
  --backend <auto|daemon|say>   where to speak (default: auto)
  --engine  <holler|dots>       neural engine when using the daemon
  --voice   <name>              voice name (default: oliver)
  --rate    <float>             pitch-preserving speed, 0.5-3.0 (default: 1.5)
  --priority <low|normal|high>  queue priority
  --interrupt                   cut off whatever is speaking now
  --status                      print daemon state and resolved settings
  -h, --help                    this text
  -V, --version                 version
  --                            end of options; everything after is text

environment:
  NOTIFY_BACKEND NOTIFY_ENGINE NOTIFY_VOICE NOTIFY_RATE NOTIFY_PRIORITY
  NOTIFY_SOCKET NOTIFY_CONFIG NOTIFY_STATE_DIR NOTIFY_DEBUG

config:
  $XDG_CONFIG_HOME/notify/config.toml (default ~/.config/notify/config.toml)
";

/// Everything the command line asked for.
struct Parsed {
    flags: Flags,
    text: String,
    status: bool,
    /// Internal: this process *is* the backgrounded `say` child.
    exec_wpm: Option<u32>,
    exec_voice: Option<String>,
}

fn parse_args(argv: &[String]) -> eyre::Result<Parsed> {
    let mut p = Parsed {
        flags: Flags::default(),
        text: String::new(),
        status: false,
        exec_wpm: None,
        exec_voice: None,
    };
    let mut words: Vec<String> = Vec::new();
    let mut i = 0;

    // Hand-rolled rather than clap: there are a handful of flags, the payload is
    // free-form prose that must pass through byte-for-byte, and this binary runs
    // dozens of times a minute so its startup cost is the product.
    while i < argv.len() {
        let a = &argv[i];

        // Once we hit the text, everything after is text - including things that
        // look like flags. Otherwise "--rate limiting is broken" loses a word.
        if !words.is_empty() {
            words.push(a.clone());
            i += 1;
            continue;
        }

        let mut need = |name: &str| -> eyre::Result<String> {
            i += 1;
            argv.get(i)
                .cloned()
                .ok_or_else(|| eyre::eyre!("{name} requires a value"))
        };

        match a.as_str() {
            "--" => {
                words.extend_from_slice(&argv[i + 1..]);
                break;
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("notify {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--status" => p.status = true,
            "--interrupt" => p.flags.interrupt = true,
            "--backend" => p.flags.backend = Some(Backend::parse(&need("--backend")?)?),
            "--engine" => p.flags.engine = Some(Engine::parse(&need("--engine")?)?),
            "--voice" => p.flags.voice = Some(need("--voice")?),
            "--priority" => p.flags.priority = Some(Priority::parse(&need("--priority")?)?),
            "--rate" => {
                let v = need("--rate")?;
                p.flags.rate = Some(
                    v.parse()
                        .map_err(|_| eyre::eyre!("--rate {v:?} is not a number"))?,
                );
            }
            // Internal contract with the backgrounded child.
            "--exec" => p.exec_wpm = Some(config::DEFAULT_SAY_WPM),
            "--wpm" => {
                let v = need("--wpm")?;
                p.exec_wpm = Some(
                    v.parse()
                        .map_err(|_| eyre::eyre!("--wpm {v:?} is not a number"))?,
                );
            }
            "--say-voice" => p.exec_voice = Some(need("--say-voice")?),
            other => words.push(other.to_string()),
        }
        i += 1;
    }

    p.text = words.join(" ").trim().to_string();
    Ok(p)
}

/// Re-exec ourselves detached so the caller returns immediately, then let the
/// child block on the lock and on `say`.
fn spawn_say_child(text: &str, wpm: u32, voice: Option<&str>) -> eyre::Result<()> {
    let exe = std::env::current_exe().unwrap_or_else(|_| "notify".into());
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("--exec").arg("--wpm").arg(wpm.to_string());
    if let Some(v) = voice {
        cmd.arg("--say-voice").arg(v);
    }
    cmd.arg("--").arg(text);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    cmd.spawn()
        .map(|_| ())
        .map_err(|e| eyre::eyre!("failed to spawn background process: {e}"))
}

fn debug_enabled() -> bool {
    std::env::var_os("NOTIFY_DEBUG").is_some_and(|v| !v.is_empty() && v != "0")
}

fn print_status(settings: &Settings) {
    println!("backend        {}", settings.backend.as_str());
    println!("engine         {}", settings.engine.as_str());
    println!("voice          {}", settings.voice);
    println!("rate           {:.2}", settings.rate);
    println!("say fallback   say -r {}", settings.say_wpm);
    println!("socket         {}", settings.socket.display());
    println!("state          {}", settings.state_file.display());
    println!(
        "config         {}",
        config::config_path()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "<none>".into())
    );
    print!("daemon         ");
    match daemon::read_state(&settings.state_file) {
        Ok(s) => {
            println!("pid {} phase {} ready {}", s.pid, s.phase, s.ready);
            for (name, st) in &s.engines {
                println!("  engine {name:<8} {st}");
            }
            if let Some(d) = &s.download {
                let pct = if d.total > 0 {
                    (d.bytes as f64 / d.total as f64) * 100.0
                } else {
                    0.0
                };
                println!("  downloading {} {:.1}%", d.repo, pct);
            }
        }
        Err(e) => println!("unavailable - {e}"),
    }
}

fn main() -> eyre::Result<()> {
    // Rust sets SIGPIPE to SIG_IGN before main, so writing to a closed pipe
    // returns EPIPE and `println!` panics on it. That turns the entirely normal
    // `notify --status | head -3` into a panic with a backtrace. Restore the
    // default disposition so we die quietly like every other CLI.
    //
    // Safe: this is the documented way to opt out, and it runs before any
    // thread has been spawned.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };

    // `color_eyre` installs a panic hook and backtrace handler. That is real
    // startup cost on a binary invoked dozens of times a minute to print
    // nothing, so it is opt-in.
    if debug_enabled() {
        color_eyre::install()?;
    }

    let argv: Vec<String> = std::env::args().skip(1).collect();
    let parsed = parse_args(&argv)?;

    // The backgrounded child: just speak and exit. No config, no daemon.
    if let Some(wpm) = parsed.exec_wpm {
        return say::speak(&parsed.text, wpm, parsed.exec_voice.as_deref());
    }

    let file = match config::config_path() {
        Some(p) => config::FileConfig::load_or_warn(&p),
        None => config::FileConfig::default(),
    };
    let settings = Settings::resolve(&file, &parsed.flags)?;

    if parsed.status {
        print_status(&settings);
        return Ok(());
    }

    if parsed.text.is_empty() {
        eprint!("{USAGE}");
        eyre::bail!("no text given");
    }

    let say_voice = settings.say_voice.clone();
    let fallback =
        || spawn_say_child(&parsed.text, settings.say_wpm, say_voice.as_deref());

    match settings.backend {
        Backend::Say => fallback(),
        Backend::Auto | Backend::Daemon => match daemon::try_speak(&settings, &parsed.text) {
            Ok(()) => Ok(()),
            Err(why) => {
                if debug_enabled() {
                    eprintln!("notify: falling back to say - {why}");
                }
                // Ask launchd to bring the daemon back for *next* time. Rate
                // limited internally, and never blocks this call.
                daemon::maybe_kickstart(&settings);
                fallback()
            }
        },
    }
}
