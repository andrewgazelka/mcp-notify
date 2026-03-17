<p align="center">
  <img src="assets/header.svg" alt="notify" width="400">
</p>

`notify` speaks a message out loud on macOS using `say`.

Useful when an agent, script, or long-running task finishes and you are not looking at the screen.

## Run

```bash
nix run github:andrewgazelka/notify -- "build finished"
```

If installed locally:

```bash
notify "tests passed"
```

## What It Does

`notify "..."` returns immediately.

It spawns a background process, and that process:

1. acquires an exclusive lock at `~/.notify-lock/say.lock`
2. runs macOS `say`
3. exits, releasing the lock

That means multiple notifications queue naturally instead of talking over each other.

## Claude Code

Add this to `CLAUDE.md`:

~~~markdown
When you finish a task, speak a short status update:

```bash
nix run github:andrewgazelka/notify -- "your message here"
```

Use phonetic spelling when text-to-speech pronunciation matters.
~~~
