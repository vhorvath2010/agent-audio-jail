# agent-audio-jail

Coding agents run browsers, test suites and scripts that play sound. When one starts
blasting audio while you are on a call, that's a jumpscare. `agent-audio-jail` keeps that
audio off your speakers and hands it to the agent that made it.

It is a small macOS daemon built on Core Audio process taps (macOS 14.2+):

- Any process started by a `claude` or `codex` process (Playwright, Chrome's audio
  helper, `afplay`, Node tests, …) is **muted** with a process tap.
- Each agent session gets its own tap. What it plays is saved as **WAV clips** under
  `~/.agent-audio-jail/sessions/pid-<agent pid>/`, so the agent can confirm that
  audio really played, and inspect it, without you hearing it.
- Your own apps (Music, Zoom, your own browser) are untouched.

## Install

```sh
git clone https://github.com/vhorvath2010/agent-audio-jail
cd agent-audio-jail
./scripts/install.sh
```

This builds `AgentAudioJail.app` into `~/Applications`, links the CLI to
`~/.local/bin/agent-audio-jail`, and starts a LaunchAgent. macOS asks once for
**System Audio Recording** permission. The app is ad-hoc signed, so it asks again after
every rebuild. Requires Xcode or the Command Line Tools.

`./scripts/uninstall.sh` removes it.

## Use

```
agent-audio-jail status          # every session that has played audio
agent-audio-jail hear pid-1234   # let one session through to the speakers
agent-audio-jail mute all        # jail everything again
agent-audio-jail pause           # turn the jail off; `resume` turns it back on
```

### For agents

An agent can run `agent-audio-jail mine --json` to get its own session: the processes
playing audio, the peak level, when it last made sound, and the paths of its clips.
A clip starts at the first non-silent buffer and ends after 2 seconds of silence (or
120 seconds). The last 20 clips per session are kept, and a session's clips are deleted
when the agent process exits.

Add something like this to your `CLAUDE.md` / `AGENTS.md`:

> Audio you play is muted by agent-audio-jail. To check what you played, run
> `agent-audio-jail mine --json` and inspect the WAV files it lists.

## Options

```
agent-audio-jail run --agent claude --agent my-agent   # which executables count as agent roots
agent-audio-jail run --bundle com.example.app          # also jail an app by bundle ID prefix
```

To change the LaunchAgent's arguments, edit `~/Library/LaunchAgents/io.github.vhorvath2010.agent-audio-jail.plist`.

## How it works

1. The daemon listens for changes to Core Audio's process list
   (`kAudioHardwarePropertyProcessObjectList`) and also re-checks every second.
2. For each process using audio, it walks up the parent-PID chain to the nearest
   `claude`/`codex` executable. That PID identifies the session.
3. For each session it creates a private `CATapDescription` over all of that session's
   processes with `muteBehavior = .muted`, plus a private aggregate device that reads
   the tap into a `ClipRecorder`.
4. When the session's processes change, it builds the new tap before destroying the
   old one, so there is no audible gap.

## Limits

- **Only processes started by an agent are covered.** An agent that drives a browser
  you started yourself (for example through a Chrome extension) plays through *your*
  browser, which is not jailed. The same goes for processes that detach and are
  re-parented to `launchd`.
- **A process can be audible for a few milliseconds** between connecting to Core Audio
  and its tap being created. In practice the tap is in place before playback starts.
- Embedded browser panes inside an agent's desktop app run in that app's own helper
  processes. Jail them with `--bundle <the app's bundle ID>`. That also mutes anything
  else the app plays.
- The daemon state lives in `~/.agent-audio-jail` (override with `AGENT_AUDIO_JAIL_HOME`).

## License

MIT
