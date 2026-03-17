<p align="center">
  <img src=".github/header.svg" alt="notify" width="360">
</p>

`notify` speaks a message out loud on macOS using `say`.

Useful when an agent, script, or long-running task finishes and you are not looking at the screen.

## Install

```bash
cargo install --path .
```

## Usage

```bash
notify "build finished"
```

## What It Does

`notify` is for short spoken status updates.

Use it when:

- a build finishes
- tests pass or fail
- an agent completes a task
- you are multitasking away from the screen

If several notifications happen close together, they wait their turn using a lock at `~/.notify-lock/say.lock` so they do not speak over each other.

## Claude Code

Add this to `CLAUDE.md`:

~~~markdown
When you finish a task, speak a short status update:

```bash
notify "your message here"
```

Use phonetic spelling when text-to-speech pronunciation matters.
~~~
