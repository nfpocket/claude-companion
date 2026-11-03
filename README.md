# Claude Companion

A companion for the Claude Code sessions you run in Ghostty. Every open session sits around a small avatar, and whatever needs you floats to the top. The companion says out loud when a session finishes or waits on you, and you can talk to it: hold Space, ask what needs you, have a session summarized, send one a prompt, or start a new one. Ghostty stays the terminal underneath.

<p>
  <img src="screenshots/orbit.png" width="600" alt="The orbit window: sessions around the avatar, todos from Task Tracker on the left">
  <img src="screenshots/pill.png" width="220" alt="The companion opened from the notch">
</p>

## Install

Needs macOS 14, Swift 6, Ghostty 1.3 or later and Claude Code.

```sh
./scripts/build-app.sh --install
./scripts/install-hooks.sh
```

The first builds the app, copies it to `~/Applications` and starts it. Without `--install` it only builds `build/Claude Companion.app`. The second lets the app see when a session is waiting on you (see [Setup](#setup)).

Voice needs an ElevenLabs API key in the login Keychain:

```sh
security add-generic-password -a "$USER" -s elevenlabs -w
```

Without it the companion speaks with the Mac voice and voice input is off. The first launch asks for the microphone and for permission to control Ghostty.

## Keys

| Key | |
| --- | --- |
| Space (hold) | Talk, while the window is in front |
| ⌥ Space (hold) | Talk, from any app |
| Space or ⌥ Space (tap) | Stop the companion mid-sentence |
| Esc | Cancel a countdown, stop talking, close the detail |
| Return | Do the proposed action now |
| ⌘1 – ⌘9 | Open that Ghostty tab |
| ⌘0 | Show the window |

Click a session for where it stands, your last prompt, and buttons to open its tab, reply by voice, read it aloud, or stop it. When the window isn't in front, the companion folds into the notch (or a pill under the menu bar on screens without one); click it for the list.

## Talking

| Say | |
| --- | --- |
| “What needs me?” | Reads out only the sessions waiting on you |
| “Summarize everything” | A short spoken briefing, most urgent first, with captions |
| “What did the Outlook one do?” | Where one session stands |
| “Tell the fleet cleanup to also check the settings page” | Types that into its tab and presses Return, after 3 s |
| “Open the dashboard one” | Brings its Ghostty tab to the front |
| “Start a session in claude-hub: build the settings screen” | A new Ghostty tab running `claude '<prompt>'`, after 3 s |
| “Stop the deploy one” | Presses Esc in its tab, after 2.5 s |
| “Close the Outlook session” | Types `/exit` and closes the tab, after you confirm |
| “Only tell me when something needs me”, “Be quiet for an hour”, “You can talk again” | Announcements |
| “Sprich Deutsch”, “Speak English” | The language the companion speaks |

Sessions are matched loosely, and “number three” means the session in Ghostty tab 3. Follow-ups work: when the companion asks which session you mean, just say “the Outlook one”. Esc or “cancel” stops any countdown. English and German both work.

## Todos

Open tasks from [Task Tracker](https://github.com/nfpocket/task-tracker) (In Progress and Todo) show on the left; the Todos button in the header hides them. Add tasks in Task Tracker as usual, from the menu bar. Right-click one:

- **Start a new session with it** opens `claude` in a new Ghostty tab in the folder you pick and puts the task into its prompt once it's ready.
- **Paste into a session** puts the task into an open session's prompt and brings its tab forward.

Nothing is sent: edit it in Ghostty, then press Return. Images attached to a task are added as file paths, so Claude can read them. The companion only reads Task Tracker's file, never writes it.

## Language

**EN | DE** in the header switches the interface. What the companion says has its own setting in the voice menu at the bottom right: match each session (German sessions get German summaries and announcements in a German voice), always English, or always German. Both voices can be picked there too.

Spoken audio is cached by text, so repeated announcements cost nothing. When fewer than 500 ElevenLabs characters are left, the companion switches to the Mac voice on its own.

## Setup

The companion reads what Claude Code already writes: `~/.claude/sessions/` for which sessions are alive and busy, and each session's transcript for its title, last prompt, last answer and current tool. Ghostty's AppleScript dictionary tells it which tab holds which session (by tty) and lets it focus tabs, type and open new ones. Summaries and understanding what you said are quick `claude -p` calls with Haiku, on your normal Claude login, without tools, hooks or MCP servers.

To see when a session waits on you (a permission prompt, a question, a plan), `./scripts/install-hooks.sh` adds async hooks to `~/.claude/settings.json` that run `~/.claude/hooks/companion-hook.sh`. It backs up the settings first and is safe to run again; `--remove` takes the hooks out. Sessions that are already running may need a restart to pick them up.

## Data

Summaries are saved to `~/Library/Application Support/ClaudeCompanion/summaries.json`, spoken audio to `~/Library/Caches/ClaudeCompanion/tts`, hook events to `~/.claude/companion/events`, settings to `defaults read local.claude-companion`.

## Development

```sh
swift build
.build/debug/ClaudeCompanion --dump                              # what the app sees, without the UI
.build/debug/ClaudeCompanion --dump --route "what needs me" --summarize
scripts/companion-say.sh "summarize everything"                  # act on text as if it were spoken
COMPANION_DEMO=screenshots .build/debug/ClaudeCompanion          # made-up sessions: writes the screenshots, then quits
```
