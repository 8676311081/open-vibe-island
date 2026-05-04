# Migrating from the legacy `claude()` zshrc function to `claude-3`

Status: **READY** — applies to every Open Island user who installed
the proxy before the `claude-3` shim shipped.

This doc is **read-only guidance**. The Open Island app will not edit
your shell startup files automatically — too risky. You run the
edits yourself, in 3-5 minutes, and verify the result with the
copy-paste commands below.

## Why migrate

The old setup put a shell function named `claude()` in your `~/.zshrc`
that intercepted **every** invocation of `claude` and forced it
through Open Island's local proxy on `127.0.0.1:9710`. That worked
for users routing API-key traffic to DeepSeek / BuerAI / Anthropic
Console, but broke transparently for two real cases:

1. **Anthropic Max / Pro OAuth subscribers** — Anthropic enforces
   end-to-end client-identity verification on `sk-ant-oat…` tokens.
   The verification fails through any proxy. So when the active
   profile happened to be e.g. DeepSeek but you tried to use your
   subscription, the OAuth token got forwarded verbatim to
   `api.deepseek.com` and you got a confusing 401.

2. **Multi-terminal parallelism** — the function had no per-call
   override knob. Terminal A pinned to BuerAI Pro, terminal B
   couldn't simultaneously run a DeepSeek script without first
   alt-tabbing to the GUI and clicking a different card.

The new design replaces the global hijack with two discrete commands:

| Command | What it does | Use when |
|---|---|---|
| `claude` | The official binary, untouched. Direct-connects to `api.anthropic.com` with the ambient OAuth credential. | Max/Pro subscription |
| `claude-3` | Goes through the Open Island proxy. Uses the GUI-active profile by default. `OI_PROFILE=<id>` overrides for one invocation. | API-key routing (DeepSeek, BuerAI, custom) |

`claude-native` and `oi-claude` stay in `~/.open-island/bin/` for one
release as compatibility aliases — they keep working unchanged for
any scripts that already invoke them.

## Migration in 5 steps

### 1. Confirm the new shim is on disk

```sh
ls -la ~/.open-island/bin/claude-3
```

You should see an executable file, ~1.7 KB, mode `0755`. If it's
missing, you're on a build before T5 — relaunch Open Island Dev.app
(or upgrade to a release ≥ the one that includes T5) before
continuing.

Also confirm `~/.open-island/bin/` is on your PATH for the shim to
be invokable bare:

```sh
echo "$PATH" | tr ':' '\n' | grep open-island
```

If empty, add this line to your `~/.zshrc` (it's idempotent — the
old setup may already have it):

```sh
path+=("$HOME/.open-island/bin")
```

### 2. Find the legacy hijack code

Run from any terminal:

```sh
grep -n 'claude *() *{' ~/.zshrc ~/.zshenv ~/.zprofile ~/.profile ~/.bashrc 2>/dev/null
```

Typical hit looks like (line numbers will vary):

```
~/.zshrc:86:claude() {
```

### 3. Delete the function (and only the function)

Open `~/.zshrc` in your editor and delete the **entire** `claude()`
block. The exact lines to remove (yours will not be at the same line
numbers, but the shape is the same):

```diff
- claude() {
-     if [ "$OI_SKIP_PROXY" = "1" ]; then
-         env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN command claude "$@"
-     else
-         ANTHROPIC_BASE_URL="http://127.0.0.1:9710" command claude "$@"
-     fi
- }
```

The comment block immediately above the function is also stale once
the function is gone. You can keep it as historical context or rewrite
it to point at this migration doc — both fine.

#### What to keep

These lines stay — they are NOT part of the legacy hijack:

```sh
path+=("$HOME/.open-island/bin")              # KEEP — needed for claude-3 / claude-native to be found
export OPENAI_BASE_URL="http://127.0.0.1:9710" # KEEP — codex/openai routing has no OAuth conflict
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 # KEEP — silences claude CLI's telemetry pings; orthogonal
```

### 4. Sweep for stray `ANTHROPIC_BASE_URL` exports

The function above is the most common case, but a stray
`export ANTHROPIC_BASE_URL=…` anywhere in your dotfiles or in the
launchd environment would silently re-hijack `claude`. Check all the
places that feed your shell environment:

```sh
# Dotfiles
grep -n 'ANTHROPIC_BASE_URL' \
  ~/.zshrc ~/.zshenv ~/.zprofile ~/.profile ~/.bashrc \
  ~/.bash_profile 2>/dev/null

# launchd-injected environment (affects every GUI-launched process)
launchctl getenv ANTHROPIC_BASE_URL
# If this prints anything, unset it:
#   launchctl unsetenv ANTHROPIC_BASE_URL

# Per-user systemd-style overrides on macOS (rare but possible)
defaults read NSGlobalDomain | grep -i anthropic
```

If any line is left after the function deletion, decide:
- Was it inside the now-deleted function block? (already gone)
- Was it a separate `export`? Delete it too — it has the same
  hijack effect.

### 5. Reload + smoke test

```sh
# Reload the shell config without opening a new terminal.
exec zsh -l

# Verify `claude` now resolves to the official binary, NOT a function.
type claude
# Expected: claude is /Users/<you>/.local/bin/claude  (or wherever your
# Anthropic CLI lives — anything that is NOT "claude is a shell function")

# Verify `claude-3` is on PATH.
type claude-3
# Expected: claude-3 is ~/.open-island/bin/claude-3

# Smoke test the proxy flow without hitting the network.
curl -sS -m 3 'http://127.0.0.1:9710/_oi/profile/deepseek-v4-pro/healthz'
# Expected: ok
# Open Island Dev.app must be running for this.

# Smoke test the override path: bogus id should return 400 with
# the available list, NOT a 404 from upstream.
curl -sS -m 3 -X POST 'http://127.0.0.1:9710/_oi/profile/totally-bogus/v1/messages' \
     -H 'content-type: application/json' \
     -H 'authorization: Bearer fake' --data '{}'
# Expected JSON: {"type":"error","error":{"type":"unknown_open_island_profile",
#                  "id":"totally-bogus","available":[...],...}}
```

## Decision quick-reference

| Goal | Command |
|---|---|
| Use Anthropic Max / Pro subscription | `claude …` (plain — no env, no shim) |
| Use whatever the GUI-active card says | `claude-3 …` |
| Use DeepSeek V4 Pro just for this run | `OI_PROFILE=deepseek-v4-pro claude-3 …` |
| Use BuerAI Pro just for this run | `OI_PROFILE=buerai-<your-id> claude-3 …` (id from the routing pane) |
| List the profile ids you have | Send a request with a bogus `OI_PROFILE` — the 400 response carries the `available` list |

## If something feels off after the migration

### Rollback

Put the function back exactly as it was:

```sh
claude() {
    if [ "$OI_SKIP_PROXY" = "1" ]; then
        env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN command claude "$@"
    else
        ANTHROPIC_BASE_URL="http://127.0.0.1:9710" command claude "$@"
    fi
}
```

`exec zsh -l` to reload. You're back on the old behavior. File an
issue with what surprised you so the migration doc can address it.

### "I'm getting 401 from `claude`"

That means `claude` is still being routed through the proxy somehow.
Check:

```sh
type claude            # should be a binary, not a function
env | grep ANTHROPIC   # ANTHROPIC_BASE_URL must be unset
launchctl getenv ANTHROPIC_BASE_URL  # must be empty
```

If any of those show proxy URLs, the migration step that should
have removed it was missed. Step 4's sweep is the catch-all.

### "I'm getting 400 with `unknown_open_island_profile`"

The `OI_PROFILE` value you set isn't a registered profile id. The
400's body lists the ids you do have. Common typos:

- Display name (`BuerAI Pro`) instead of id (`buerai-<slug>`).
  Use the id; ids are alphanumeric + hyphen, no spaces or
  capitals.
- Stale id from a profile you've since deleted.

### "`claude-3` is not found"

`~/.open-island/bin/` is not on your PATH for the current shell.
Re-run step 1's verification. If the directory IS there but the
file isn't, the app's shim install never ran — restart
Open Island Dev.app and check the file appears within ~5 seconds.

## Deprecation timeline

`oi-claude` (the predecessor to `claude-3` without the `OI_PROFILE`
knob) stays bundled for **one release** as a compatibility alias for
any scripts already using it. After that release window, it will be
removed and any caller still on `oi-claude` will need to switch to
`claude-3`. The replacement is one-for-one (same proxy URL, same
default behavior); the only feature `claude-3` adds is the
`OI_PROFILE` override, which `oi-claude` does not have.
