# One request, one execution: the Zygote bootstrap defect

Scope: Sony NW-WM1AM2, Android 11, firmware `1.09.00`, incremental `68`,
security patch 2024-02-01. Static analysis of this repository plus the supplied
diagnostic; no device was accessed, nothing was written, no exploit was run.

The helper reaches a vendor HAL through CVE-2024-31317 by putting a crafted value
into `hidden_api_blacklist_exemptions`. That gets a process inside the
`platform_app` SELinux domain **as UID 1000, not UID 0**. Nothing here changes
that boundary.

## 1. What actually happened

### Confirmed by the supplied evidence

| Fact | Source |
|---|---|
| One host `read` produced **two complete device executions**: two `ev=begin`, sixteen `ev=field`, two `ev=summary status=OK` with `written=0 verified=8` | run-id-filtered logcat |
| `Read` only calls HAL `get`, never `set` | `src/org/maniac79/nvptool/Read.java:36-54` |
| The host stopped collecting at the **first** summary, so the second execution never entered the snapshot | `tools/lib.sh` collection loop (pre-fix) |
| The parser required exactly one begin and one summary - but only of that truncated snapshot | `nl_parse` |
| `ZygoteProcess.setApiBlacklistExemptions` forwards the exemptions to **both** the primary and the secondary Zygote connection | vendor disassembly, cited in the diagnostic |
| Zygote logged `Error reading pid from wrapped process`; ActivityManager announced `Start proc 5371:com.android.settings/1000` for a pid that had already exited, then `No pending application record for pid 5417; dropping process`; the API-blacklist status codes were child pids | process logcat |
| Settings opened white after the read and normally after a reboot | owner observation |

### Mechanism (derived, unambiguous)

1. **The payload is state, not a message.** It lives in a global setting that Zygote
   reads at *every* fork, so it does not fire once - it fires for as long as it is
   installed.
2. **`--invoke-with` replaces the child's entry point.** The app the trigger asked
   for (Settings) never starts; our command runs instead and exits.
3. **ActivityManager treats that as a retryable failure.** Each retry is another
   fork, and therefore another execution. The observed second execution ~1.2 s after
   the first is one such retry.
4. **Both Zygote connections carry the exemption**, so either path can execute it;
   the count of executions is bounded only by arming time x fork attempts, not by
   anything in the payload.
5. **Reply/PID association breaks because the wrapped child never performs Zygote's
   pid handshake.** The parent therefore cannot associate the child with the fork
   request (`Error reading pid from wrapped process`), the pid ActivityManager was
   told is not the pid that ran, and the `setApiBlacklistExemptions` status is a
   child pid rather than a boolean.
6. **The white Settings screen is the same defect seen from the UI side**: the
   process that should host Settings is replaced and dies, ActivityManager keeps a
   pending record, and only a reboot clears that state.

### Inferred, not measured

- The exact retry policy and timeout ActivityManager applied to this activity start.
- Whether the two executions came from two forks on one connection or one fork on
  each connection. The evidence proves two executions, not their socket origin.
- How many further executions would have occurred had the setting stayed armed
  longer. The arming window was the whole poll loop (up to 20 s); the duplicate
  arrived inside the first ~1.2 s.

### What the old host did wrong, precisely

`nl_parse` demanded `begins == 1` and `summaries == 1`. That is a correct rule
applied to the wrong object: the snapshot was taken the moment the first summary
appeared, so the rule could only ever see one execution. The invariant was
"exactly one record in what we happened to read", never "exactly one execution on
the device".

## 2. Two repair approaches

**A - device-side single-shot claim (prevention).** Before touching the HAL, the
payload atomically claims the run: `open(O_CREAT|O_EXCL)` on
`<host-prepared-dir>/claim-<runid>`, then writes its pid. The winner does the work;
losers emit a complete `begin` + `summary status=SKIPPED reason=already_claimed`
pair and exit without touching the HAL. Guarantees at most one HAL operation and
keeps every fork's reply attributable to a pid.
*Needs:* a directory the payload's domain may create files in, atomically.

**B - host-side bounded arming plus accept-exactly-one (detection + bounding).**
Arm, trigger and disarm in one round trip; wait for a summary; then keep reading
for a settle window and take one final snapshot; require the whole window to
contain exactly one `OK` summary, with begin/summary pid agreement.
*Needs:* nothing from the device. Turns an invisible duplicate into a hard failure
and shrinks the arming window from seconds to a round trip, which removes most of
the retry opportunity - but it cannot prevent a retry that lands inside that
round trip.

## 3. Recommended design

Both, in this order of authority:

1. **Host (implemented, effective now):** arm -> trigger -> **disarm immediately** ->
   bounded wait for a summary -> settle window -> one final read -> strict check.
   Any second `OK` summary, any begin/summary count above one, and any
   begin/summary pid mismatch is a hard failure (exit 4 / parse error), never a
   success.
2. **Device (designed, not enabled):** the claim above, with `SKIPPED` as a
   first-class, non-success outcome that still emits a complete pair so the reply
   stays attributable.
3. **Writes stay closed until 1 and 2 are validated on hardware** - see the write
   hold in `tools/lib.sh` / `tools/nvptool.ps1` (exit 13,
   `NVPTOOL_ALLOW_UNVALIDATED_WRITE=1` to bypass deliberately).

The property this buys: **at most one accepted HAL result per request**, and every
record attributable to the process that produced it. The property it does *not*
yet buy: a hard guarantee that a second fork cannot execute the payload at all -
that is what A adds, and it is why the hold stays.

## 4. Change made, and why it fixes the mechanism

| Change | Where | Why it is not cosmetic |
|---|---|---|
| Every record carries `pid=` | `src/org/maniac79/nvptool/Result.java` | Makes one execution distinguishable from two, and a summary provably its own begin's |
| Disarm before collecting | `tools/lib.sh`, `tools/nvptool.ps1` | Cuts the arming window from the whole poll loop to one round trip: removes the seconds in which ActivityManager retried |
| Settle window + single final read | same | The snapshot now covers the window in which a late duplicate lands - the exact case that was invisible |
| Reject >1 begin, >1 summary, pid mismatch | `nl_parse`, `Assert-Result` | The "one execution" rule is now applied to the whole window instead of the first summary |
| Write hold, exit 13 | `nl_require_write_enabled`, `Assert-WriteEnabled` | A duplicate read wastes work; a duplicate write is an unbounded number of NVRAM operations |

It still does not make the payload single-shot. A retry that lands inside the
disarm round trip can still execute twice; that is detected and refused, not
prevented. Saying otherwise would be the same mistake as before, one layer up.

## 5. Stopped branch: the claim needs one missing fact

Approach A depends on the payload's process being able to create and unlink a file
in a host-prepared directory. DAC is solvable from the host (create the directory
`0777`; the shell owner can do that). **SELinux is not decidable from this
repository**, and the payload domain is the vendor's
`platform:targetSdkVersion=29:complete` mapping, not a name I can assert.

Exact artifact needed, and nothing else will do:

- the compiled policy of this build plus its `seinfo` mapping, queried with
  `sesearch --allow -s <platform_app domain> -t tmpfs -c file`, showing
  `create`/`unlink`/`write`; **or**
- one `avc: denied` observation from a device-side attempt confined to
  `O_CREAT|O_EXCL` on that directory (a device action, not permitted in this
  review).

Until one of those exists, A stays a design. Do not infer it from "shell can write
there" - the shell domain is not the payload domain, and UID 1000 is not shell.

## 6. Isolated Android 11 validation plan (read-only, no NVRAM writes)

Preconditions: helper APK byte-identical to the bundled one, no
`hidden_api_blacklist_exemptions` present, no lock directory, fresh boot, owner
watching Settings.

| Step | Action | Pass condition | Stop condition |
|---|---|---|---|
| 1 | `status` | runs with no app start | any device-side record |
| 2 | one `read`, settle 3 s | exactly one `OK`, one pid, no `SKIPPED`, exit 0 | two `OK`, any parse error |
| 3 | repeat `read` immediately after step 2 | one accepted `OK`; duplicates refused | two accepted `OK` |
| 4 | `read` while forcing a second Settings launch from the UI | refused as duplicate, or one `OK` | accepted duplicate |
| 5 | `read` with the HAL unavailable (bootstrap failure path) | one `FATAL` summary, cleanup verified, setting absent | no summary / setting left behind |
| 6 | open Settings normally afterwards | UI renders, no white screen | white screen -> stop, reboot, report |
| 7 | post-run audit | setting absent, payload and lock removed, recovery record closed, eight NVRAM values unchanged vs the pre-run read | any residue |

Lifting the write hold requires: steps 2-7 passing twice on this build, **and**
approach A implemented and showing `SKIPPED` (not `OK`) for the loser executions
in steps 3 and 4. A delay, an ABI filter or a file lock alone is not sufficient
proof; the claim must be atomic, owned by the right UID, and permitted by the
payload's own SELinux domain.

## 7. Hardware measurements (2026-10-25, NW-WM1AM2, firmware 1.09.00)

Three privileged reads were run on the owner's device, each with writes held and
no NVRAM modification (`written=0` in every summary). All three are evidence, not
inference.

**A - claim only.** Two executions (pids 5521, 5590, 0.53 s apart). Both logged
`claim_unavailable` and `REFUSED phase=preflight`; neither touched the HAL. The
claim directory was `0777 shell:shell u:object_r:shell_data_file:s0`, so the
payload's own domain cannot create there, and the `FileLock` fallback failed as
well. **Approach A is not viable on this filesystem.** The host refused the run
(`bad_begin_count`), which is the intended fail-closed behaviour.

**B - claim + self-disarm.** The disarm itself **works**: the first execution
deleted the setting and verified `null`. It did not stop the second execution:

```
12:11:45.061 pid=1606 summary status=OK
12:11:45.624 pid=1693 note msg=disarm_ok      <- setting deleted, verified null
12:11:45.637 pid=1693 summary status=OK
12:11:45.106 ZygoteProcess: Failed to set API blacklist exemptions; status 1657
12:11:45.667 ZygoteProcess: Failed to set API blacklist exemptions; status 1667
```

Deleting the *setting* does not revoke the copy **cached inside Zygote**: the
release travels through `setApiBlacklistExemptions`, which fails with a child pid
as its status - the same reply/PID desynchronisation as before, now blocking the
release instead of the arming. So approach A's intended mechanism cannot work
from the payload side on this firmware.

**C - linger (retry-suppression).** Hypothesis: the duplicate is ActivityManager
retrying a start whose process died, so keeping the child alive should remove it.
The retry timing was confirmed and the prevention was not:

```
12:17:18.835 pid=4440 begin ... summary      <- execution 1, then linger 8 s
12:17:27.534 pid=4540 begin ... summary      <- execution 2, exactly on its exit
```

While the child lives there is no retry; the moment it exits, ActivityManager
retries and Zygote - still holding the stale exemption - executes the payload
again. Worse, that second execution landed **after** the host's settle window, so
the host reported success (exit 0) while a duplicate happened. This variant was
reverted; it hides the defect instead of fixing it.

**Conclusion.** On this firmware, with this technique, one armed request costs
exactly two executions, and no payload-side or host-side timing trick can prevent
the second: the exemption lives in Zygote's memory, it can only be replaced by a
call the payload's own fork breaks, and it cannot be cleared by deleting the
setting. Every run therefore also leaves Settings without a process until a
reboot, because the retried start is what replaces it.

**Consequences for the tool (current state).** The payload requires a claim, which
this filesystem does not provide, so every privileged run now refuses at
`preflight` and reaches no HAL. `status` works; `read` reports the refusal; all
NVRAM writes stay held. That is fail-closed, not a fix.

**What would still change the outcome**: a claim medium the payload can write
(not on `/data/local/tmp` here), or a trigger that ActivityManager never retries.
Both are open questions; neither can be settled by another read.

## 8. Broadcast trigger measured (2026-10-25, same unit)

Hypothesis: the duplicate is ActivityManager retrying an *activity* start, so a
trigger with no activity record - a broadcast to a receiver in our own package -
should fork once and leave the Settings UI alone.

Implemented: a bare `Trigger` receiver in the helper manifest, and
`am broadcast -a org.maniac79.nvptool.TRIGGER -n org.maniac79.nvptool/.Trigger`
as the trigger. Settings is no longer touched by the tool at all.

Result - the duplicate is **not** gone, and the collateral damage is **not**
reduced:

```
12:22:16.116 pid=4553  begin ... summary      <- first execution
12:22:26.812 pid=4640  begin ... summary      <- second execution, 10.7 s later
```

The gap is the broadcast delivery timeout: when the process dies without the
receiver running, delivery is retried once more before the broadcast is dropped.
So *any* start that must deliver something is retried, not just activity starts.

Worse: after the run, `com.android.settings` could not be started at all
(`pidof` empty immediately after `am start`), and the tool had not touched
Settings in this run. That is the documented "disturbed later process starts"
from the public analysis, observed directly: the exemption is cached in Zygote
for the whole boot session, deleting the setting does not clear it, and from
then on **every** new app process is replaced by the payload. Only a Zygote
restart - a reboot - clears it.

### Consequence, final for this technique on this firmware

- One armed request costs exactly **two** executions, whatever the trigger.
- After that request the device cannot start app processes until it is rebooted.
- Therefore: at most **one privileged operation per boot**, followed by a reboot;
  single execution cannot be enforced from the payload or the host.
- A read is idempotent and safe in that model. A write is not *unsafe* (the payload
  paths are idempotent per field) but it cannot be verified in the same boot,
  because verification needs an app start.

The broadcast trigger was reverted together with the rest of the experiment; the
tree stays at the fail-closed state where a run without a claim refuses.
