# Troubleshooting & Technical Notes

Detailed symptoms, root causes, and fixes for the Blackboard download pipeline. Load this file when a step fails or when debugging the environment.

## 1. Daemon fails to start: `write daemon.json` / `Operation not permitted (os error 1)`

**Symptom (macOS):** `bsk daemon start` prints `daemon lock acquired`, then `ws server listening`, then `error: write daemon.json`, and exits. A `daemon.json.tmp.<pid>` file appears but no `daemon.json`.

**Root cause:** The browser-skill daemon writes its state file with an atomic temp-file + `rename`. On macOS the app sandbox blocks that `rename` under `~/.bsk`, while ordinary `echo`/`mv`/`cp` from the shell succeed (the sandbox applies to the detached daemon process differently).

**Fix:** Point `BSK_HOME` at a writable path outside the restricted area:

```bash
BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0 bsk daemon start
```

Prefix every `bsk` command in the session with the same `BSK_HOME` (or `export BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0`). Verify with `bsk status --json` that `daemon_version` and `protocol_version` are reported.

**Note:** `/tmp` is cleared on reboot; recreate and restart the daemon after a reboot. This limitation is macOS-specific — Windows/Linux use the default `~/.bsk`.

## 2. Extension never connects: `no_browser_connected` / `(no browsers connected)`

**Symptom:** `bsk browsers` shows nothing even though the daemon is up on port 52800.

**Causes, in order of likelihood:**
1. **Version mismatch** — CLI and extension versions differ (e.g. CLI `0.1.10`, extension `0.3.0`). Run `bsk --version`; update the CLI with `bsk update -y`, or download the matching release from `https://github.com/Tencent/BrowserSkill/releases` (asset naming: `bsk-v<ver>-<triple>.tar.gz`, where `aarch64-apple-darwin` = macOS arm64).
2. **Extension not activated** — the MV3 service worker sleeps when Chrome has no window or no user activity. Ask the user to click the BrowserSkill toolbar icon and wait for "connected".
3. **Stale daemon** — the previous daemon may have left an unfinished command. Wait for it to time out, or `bsk session stop <id>` / restart the session.

## 3. `request-help` returns `previous session command is still running`

**Symptom:** A follow-up command fails with "session already has an unfinished command", often after a prior `request-help` was killed (e.g. the shell timed out and sent SIGTERM).

**Cause:** The daemon still tracks the killed command as in-flight until its own timeout elapses.

**Fix:** Wait for the previous command's timeout (default 5m), or stop/restart the session, then re-issue. When running `request-help` in a shell with a short default timeout, launch it with `run_in_background` and a generous `--timeout` (e.g. `10m`) so it is not killed mid-wait.

## 4. Download URL opens a doc viewer instead of downloading

**Symptom:** Navigating to a derived URL lands on `basic-doc-viewer.sgc.api.blackboard.com/…` (a preview) instead of triggering a download; no file appears in the downloads folder.

**Cause:** The iframe `src` contains several query params: `locale`, `isInlineRender=true`, `xythos-download=true`, `render=inline`. Keeping `isInlineRender=true` or `render=inline` forces inline preview.

**Fix:** Keep only `?xythos-download=true`:

- iframe src: `https://…/bbcswebdav/pid-<pid>-dt-content-rid-<rid>_1/xid-<rid>_1?locale=en_US&isInlineRender=true&xythos-download=true&render=inline`
- download URL: `https://…/bbcswebdav/pid-<pid>-dt-content-rid-<rid>_1/xid-<rid>_1?xythos-download=true`

A successful download makes `navigate` report `net::ERR_ABORTED` — treat that as success, not an error.

## 5. `evaluate` cannot call Blackboard's REST API (`Failed to fetch` / S3 `NoSuchKey` 404)

**Symptom:** `fetch('/learn/api/v1/courses/<id>/contents/ROOT')` or `XMLHttpRequest` returns `Failed to fetch` or a CloudFront/S3 `NoSuchKey` error, even though the page itself loaded the same endpoint with 200.

**Cause:** The `bsk evaluate` execution context does not route those requests to the Blackboard origin the same way the page's own fetch does (CSP/context differences).

**Workaround:** Do **not** rely on the REST API. Enumerate files via the DOM instead (see Step 5 of SKILL.md): expand folders, then read `a[href*="/file/"]` links. Read the per-file iframe `src` for the `bbcswebdav` download URL.

## 6. Files only appear after expanding folders (lazy loading)

Blackboard Ultra loads each folder's children on demand. A fresh outline page shows only top-level folders; `document.querySelectorAll('a[href*="/file/"]')` returns `[]` until every parent folder is clicked open. Expand recursively (click each `button "文件夹，…"`), waiting ~2s between clicks, before collecting file links.

## 7. Filename collisions produce `(1)` suffixes

Chrome appends ` (1)` when a file with the same name already exists in the downloads folder (e.g. an old unrelated `Lecture 1.pdf` from a prior year). When organizing, strip the ` (1)` before the extension, but first confirm the target archive folder does not already contain a file with the correct name — skip duplicates rather than overwriting.

## 8. Clean shutdown

After finishing, stop the session and daemon:

```bash
bsk session stop <id>
bsk daemon stop
```

`session stop` may time out waiting for the extension; that is harmless if all files are already downloaded — `daemon stop` still tears the backend down.
