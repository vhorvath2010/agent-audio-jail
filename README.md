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
`~/.local/bin/agent-audio-jail`, and starts a LaunchAgent. macOS asks for
**System Audio Recording** permission, and the jail can't do anything until you click
Allow. The app is ad-hoc signed, so macOS asks again after every rebuild. Requires Xcode
or the Command Line Tools.

`./scripts/uninstall.sh` removes it.

## Knowing what's muted, and unmuting it

A muted page looks broken unless you know the jail exists, so the app tells you:

- **A bar on the muted window.** While an agent-started app is playing sound, every
  window it owns gets a bar along the bottom: "Audio muted by Agent Audio Jail: started by
  claude in my-app", with an **Unmute** button. After you unmute, the bar stays and offers
  **Mute**. It follows the window as you drag it. Because it's a separate window from
  another app, it can trail by about a frame. It only needs the window's position, so it
  doesn't need Screen Recording permission.
- **Menu bar icon.** A crossed-out speaker means the jail is running. It turns filled,
  with a count, while it's muting agent audio *right now*; hover over it to see which agent.
  The menu lists each agent session by its project folder (for example
  "claude in my-app: muted, playing now") and the process making the sound. Each session
  has **Unmute This Agent** / **Mute Again** and **Show Muted Clips in Finder**. The menu
  also has **Pause: Let All Agent Audio Through** and **Quit**.
- **Notification.** The first time a session is muted you get one notification, such
  as "Muted audio from claude in my-app", with an **Unmute** button. You get one per
  agent session, so test runs don't spam you. Turn it off from the menu. In testing,
  macOS refused notifications for an ad-hoc signed build without ever asking; the bar
  and the menu bar icon still work without them.

Unmuting applies to the whole agent session (everything that agent started) until you
mute it again or the agent exits. Quit keeps it stopped. Open AgentAudioJail from
Spotlight to start it again.

## Command line

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
- State lives in `~/.agent-audio-jail` (override with `AGENT_AUDIO_JAIL_HOME`).

## License

MIT
