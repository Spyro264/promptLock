# Touch ID Lock for Claude Code (Admin-Protected)

A simple guide to make Claude Code ask for your Mac fingerprint (or password) before it accepts any prompt, with the lock itself protected so nobody can remove it without your fingerprint.

> **Scope:** Built and tested with **Claude Code inside VS Code** on a Mac with Touch ID. Because the lock lives in Claude Code's **system-wide managed settings**, it also covers Claude Code in the terminal and other places Claude Code runs on your Mac. See "Where this lock works" below.
>
> **Windows and Linux:** coming soon. See the `windows/` and `linux/` folders.

---

## Files in this repository

| File | What it is |
|---|---|
| `mac/touchid-check.swift` | Source code of the Mac fingerprint/password program (built in Step 2) |
| `mac/claude-prompt-guard.sh` | Mac guard script with the 60-second timer (installed in Step 4) |
| `mac/managed-settings.json` | Mac managed settings example (installed in Step 5) |
| `windows/` | Windows support: coming soon |
| `linux/` | Linux support: coming soon |

The guide below contains copy-paste commands that create these same files, so you can follow it with or without downloading this repository.

---

## Why I built this

If my laptop is open and I walk away for a minute, anyone sitting at it could:

- Type a prompt into Claude Code
- Ask it to delete my code or add harmful code
- Get those changes committed, all within seconds

Because the changes are made on **my** laptop, they look like **my** work. There would be almost no trace that someone else did it.

With this lock:

- **Every prompt sent to Claude Code needs my fingerprint or Mac password.**
- **If nobody gives a fingerprint within 60 seconds, the prompt is blocked.** Waiting it out doesn't work.
- **The lock is protected by admin rights.** Removing or changing it also needs my fingerprint.
- **Every attempt is written to a log**, so I can see if someone tried while I was away.

---

## Where this lock works

| Product | Protected? | Why |
|---|---|---|
| Claude Code extension in VS Code | ✅ Yes (tested) | Reads the managed settings file |
| Claude Code in the terminal (`claude` command) | ✅ Yes (tested) | Reads the same managed settings file |
| Claude Code in other editors or the desktop app’s Code tab | ✅ Should be | Reads the same managed settings file |
| Claude website (claude.ai) or the Claude chat app | ❌ No | Separate products that don’t use this file |
| Git commands or anything typed directly in the terminal | ❌ No | Not Claude Code, so needs its own lock |

**Quick test for the terminal:** open a terminal, type `claude`, press Enter, and send `hi`. If the Touch ID popup appears, the terminal version is protected too.

---

## How it works (simple version)

1. Claude Code has a feature called **hooks**. A hook is a small program that runs automatically at a certain moment.
2. We use the **"UserPromptSubmit"** hook, which runs **after you press send but before the prompt reaches Claude**.
3. Our hook shows the Mac **Touch ID popup**.
4. Fingerprint OK → the prompt goes to Claude.
   Cancelled, failed, or no answer within 60 seconds → the prompt is **blocked**, and Claude never sees it.
5. The hook is set in Claude Code's **managed settings file**, a system file that only an admin can change. The lock files are owned by the system (`root`), so they can't be edited or deleted without `sudo`, which we set to use Touch ID.

---

## What you need

- A Mac. **Touch ID is optional.** On a Mac without Touch ID (or if you skip the fingerprint), the popup asks for your **Mac password** instead, and the lock works the same way.
- **macOS Sonoma (14) or newer** (needed for the easy Touch ID `sudo` setup in Step 3; on a Mac without Touch ID, skip Step 3 and `sudo` will simply ask for your password)
- An **Administrator** account on the Mac
- VS Code with the Claude Code extension
- The Terminal (the one at the bottom of VS Code is fine)

**Check that you're an admin:**

```bash
id -Gn | grep -qw admin && echo "You are an ADMIN" || echo "You are a STANDARD user"
```

If you're a Standard user (common on work or school Macs), you'll need your IT team to do this setup.

---

## Step 1: Check that Swift is installed

Swift is needed to build the small fingerprint program.

```bash
swiftc --version
```

- If you see a version number, go to Step 2.
- If you see an error, run `xcode-select --install`, click **Install**, wait for it to finish, then continue.

---

## Step 2: Build the fingerprint program

Create a folder for the source code:

```bash
mkdir -p ~/touchid-src
```

Paste this whole block into the terminal and press Enter:

```bash
cat > ~/touchid-src/touchid-check.swift <<'EOF'
import Foundation
import LocalAuthentication

let reason = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "authorize this action"
let context = LAContext()
var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    fputs("Touch ID unavailable: \(error?.localizedDescription ?? "unknown")\n", stderr)
    exit(1)
}
let sema = DispatchSemaphore(value: 0)
var ok = false
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
    ok = success
    if !success { fputs("Authentication failed\n", stderr) }
    sema.signal()
}
sema.wait()
exit(ok ? 0 : 1)
EOF
```

Build it:

```bash
swiftc ~/touchid-src/touchid-check.swift -o ~/touchid-src/touchid-check
```

Test it:

```bash
~/touchid-src/touchid-check "test" && echo PASSED || echo FAILED
```

- Touch the sensor → **PASSED**
- Run it again and press **Cancel** → **FAILED**

**What this program does:** it shows the Touch ID popup and returns "success" only if you give your fingerprint or password.

---

## Step 3: Make `sudo` use Touch ID

`sudo` is the command that runs things with admin power. This step makes it ask for your fingerprint instead of typing your password.

```bash
sed -e 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local
```

Enter your Mac password this one time (it's hidden as you type, which is normal). Then open a **new terminal tab** (`Cmd + T`) and test:

```bash
sudo -k; sudo echo OK
```

**Expected:** a Touch ID popup, then `OK`.

---

## Step 4: Install the lock files in a protected folder

This copies the fingerprint program into a system folder and creates the guard script there.

```bash
sudo mkdir -p /usr/local/libexec/claude-touchid
sudo cp ~/touchid-src/touchid-check /usr/local/libexec/claude-touchid/

sudo tee /usr/local/libexec/claude-touchid/claude-prompt-guard.sh > /dev/null <<'EOF'
#!/bin/bash
LOG="$HOME/.claude/touchid-hook.log"
LIMIT=60
mkdir -p "$HOME/.claude"
echo "$(date '+%H:%M:%S') hook started" >> "$LOG"
cat > /dev/null

/usr/local/libexec/claude-touchid/touchid-check "send a Claude Code prompt" &
pid=$!
( sleep $LIMIT; kill $pid ) > /dev/null 2>&1 &
watcher=$!

wait $pid 2>/dev/null
code=$?
kill $watcher > /dev/null 2>&1

echo "$(date '+%H:%M:%S') touchid exit code: $code" >> "$LOG"
if [ $code -ne 0 ]; then
  if [ $code -gt 128 ]; then
    echo "Blocked: no fingerprint within $LIMIT seconds" >&2
  else
    echo "Blocked: fingerprint not verified" >&2
  fi
  exit 2
fi
exit 0
EOF

sudo chown -R root:wheel /usr/local/libexec/claude-touchid
sudo chmod 755 /usr/local/libexec/claude-touchid /usr/local/libexec/claude-touchid/*
ls -l /usr/local/libexec/claude-touchid
```

**Expected:** two files (`claude-prompt-guard.sh` and `touchid-check`), both owned by `root  wheel`.

**What the guard script does:**

1. Shows the Touch ID popup.
2. Starts a **60-second timer**. If no fingerprint is given in time, it closes the popup.
3. Writes the result to a log file.
4. If the fingerprint wasn't given, it sends **exit code 2**, which tells Claude Code to block the prompt.

---

## Step 5: Create the protected managed settings file

Claude Code reads this file for every user on the Mac, and only an admin can change it.

```bash
sudo mkdir -p "/Library/Application Support/ClaudeCode"

sudo tee "/Library/Application Support/ClaudeCode/managed-settings.json" > /dev/null <<'EOF'
{
  "allowManagedHooksOnly": true,
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/libexec/claude-touchid/claude-prompt-guard.sh",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
EOF

sudo chown root:wheel "/Library/Application Support/ClaudeCode/managed-settings.json"
sudo chmod 644 "/Library/Application Support/ClaudeCode/managed-settings.json"
python3 -m json.tool "/Library/Application Support/ClaudeCode/managed-settings.json" > /dev/null && echo "VALID"
```

**Expected:** `VALID`

**What the two settings mean:**

- **`"timeout": 300`** is how long Claude Code waits for the guard script. If this time runs out, Claude Code **lets the prompt through**. That's why it must always be **longer** than the script's own 60-second timer, so the script always decides first and blocks.
- **`"allowManagedHooksOnly": true`** means only hooks from this protected file run. A project folder can't sneak in its own hooks. The tradeoff is that any personal hooks you add in `~/.claude/settings.json` won't run.

---

## Step 6: Remove any old hook from your personal settings

If you set up an earlier version of this lock in `~/.claude/settings.json`, remove it, or you'll get two popups per prompt.

Check for one:

```bash
grep -c "hooks" ~/.claude/settings.json
```

- `0` or "No such file": nothing to remove, so go to Step 7.
- Above `0`: open `~/.claude/settings.json` and delete the whole `"hooks": { ... }` section (and the comma before it). Keep your other settings. Then check the file:

```bash
python3 -m json.tool ~/.claude/settings.json > /dev/null && echo "VALID"
```

---

## Step 7: Restart and test

Fully quit VS Code with `Cmd + Q` (closing the window is not enough), then reopen it. Send `hi` in Claude Code and try each case:

| What you do | What should happen |
|---|---|
| Touch the sensor | Claude replies normally (one popup only) |
| Press Cancel | Prompt blocked: "Blocked: fingerprint not verified" |
| Do nothing for 60 seconds | Popup closes, prompt blocked: "Blocked: no fingerprint within 60 seconds" |

Then check that the settings file is locked:

```bash
echo test >> "/Library/Application Support/ClaudeCode/managed-settings.json"
```

**Expected:** `Permission denied`

> When a prompt is blocked, Claude Code shows the path of the guard script in its message. That's not dangerous: the files are protected, and knowing where they are doesn't let anyone change them.

---

## Step 8: Read the log

Every attempt is saved here:

```bash
cat ~/.claude/touchid-hook.log
```

Example:

```
15:18:14 hook started
15:19:14 touchid exit code: 143   ← blocked (60-second timer ran out)
15:20:02 hook started
15:20:05 touchid exit code: 1     ← blocked (cancelled)
15:20:30 hook started
15:20:32 touchid exit code: 0     ← allowed (fingerprint OK)
```

| Exit code | Meaning |
|---|---|
| `0` | Fingerprint OK, prompt allowed |
| `1` | Cancelled or failed, prompt blocked |
| Above 128 (like `143`) | 60-second timer ran out, prompt blocked |

If you see blocked attempts at a time you were away, someone tried to use Claude Code on your laptop.

To clear the log:

```bash
> ~/.claude/touchid-hook.log
```

> The log is in your home folder, so it isn't admin-protected. Someone could clear it. Treat it as a helpful record, not proof.

---

## Files created

| File | Purpose | Protected? | Safe to delete? |
|---|---|---|---|
| `/usr/local/libexec/claude-touchid/touchid-check` | Shows the Touch ID popup | ✅ Admin | **No** |
| `/usr/local/libexec/claude-touchid/claude-prompt-guard.sh` | Runs the check, the 60-second timer, the log, and the block | ✅ Admin | **No** |
| `/Library/Application Support/ClaudeCode/managed-settings.json` | Tells Claude Code to run the hook | ✅ Admin | **No** |
| `/etc/pam.d/sudo_local` | Makes `sudo` use Touch ID | ✅ Admin | **No** |
| `~/touchid-src/touchid-check.swift` | Source code, used to rebuild | No | Better to keep |
| `~/touchid-src/touchid-check` | Built copy before install | No | Yes |
| `~/.claude/touchid-hook.log` | Record of all attempts | No | Yes, can be cleared |

Tip: `.claude` is a hidden folder. In Finder, press `Cmd + Shift + .` to show hidden files.

---

## Changing the time limit

To change 60 seconds to something else (for example, 30):

```bash
sudo sed -i '' 's/^LIMIT=60$/LIMIT=30/' /usr/local/libexec/claude-touchid/claude-prompt-guard.sh
grep "^LIMIT" /usr/local/libexec/claude-touchid/claude-prompt-guard.sh
```

Always keep the limit **well below 300** (the Claude Code timeout in Step 5).

---

## How to turn it off

This needs your fingerprint, which is the point.

```bash
sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"
```

Restart VS Code. To also remove the lock files:

```bash
sudo rm -r /usr/local/libexec/claude-touchid
```

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Popup closed by itself and Claude still replied | Claude Code's timeout ran out before the script finished | Make sure `"timeout"` is `300` and `LIMIT` is well below it |
| Two popups per prompt | Old hook still in `~/.claude/settings.json` | Do Step 6 |
| No popup at all | Managed settings not loaded or file invalid | Check it says `VALID` (Step 5), then fully quit and reopen VS Code |
| `sudo` still asks for a typed password | Touch ID for `sudo` not set up | Redo Step 3 and open a new terminal tab |

---

## Limits to know

- This protects **Claude Code prompts** on your Mac. It doesn't protect the Claude website or chat app. Someone at your unlocked laptop could still type commands directly in the terminal or use VS Code's git buttons.
- The check happens **once per prompt**. After you approve a prompt, Claude may do several steps (edit files, run commands) without asking again.
- **Your Mac password is the master key.** Touch ID protects the admin step, but macOS always allows the account password as a fallback. Keep it strong and private.
- **The best protection is still locking your Mac** whenever you walk away: press `Control + Command + Q`.
