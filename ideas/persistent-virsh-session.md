# A persistent `virsh` session as a spawn-free libvirt transport

**Status:** **built, and the default transport since 2026-08-23** — the trial
concluded on real-host observation and the `VIRTUI_VIRSH_SESSION=1` opt-in is
gone (DECISIONS.md D-virsh-session). Everything decided has graduated; what
keeps this page alive is the *evidence* below plus the two gotchas a daemon-less
box cannot reach (wedged `qemu-ga`, libvirtd restart under a live session). Spun
out of `swap-via-qemu-guest-agent.md` on 2026-08-21, where it appeared as a
footnote.

**Verified 2026-08-21 against `virsh` 12.0.0 (Ubuntu `libvirt-clients`
12.0.0-1ubuntu5.3) on the dev box.** The dev box has no libvirt daemon, so the
probes ran against **`test:///default`** — libvirt's in-process test driver,
which needs no socket and no daemon and still answers `list`, `dominfo`,
`domstats`, `dumpxml`, `event`. That works because every gotcha below except two
is a property of `vsh.c`, GNU readline and libc stdio, not of the hypervisor
driver. The two exceptions are called out as **still unverified**: a genuinely
wedged `qemu-ga`, and a server-side disconnect.

The headline: the framing gotcha was **misdiagnosed** and is worse than the note
first claimed — *and* it has a clean two-environment-variable fix. The quoting
gotcha, billed as "the deep one", is a non-issue.

## The idea

`virsh` is not only a one-shot CLI. Run with no command it enters an interactive
REPL, reading commands from stdin and holding **one** libvirt connection for the
whole session. So instead of

```ruby
Run.sync("virsh qemu-agent-command '#{dom}' '#{json}'")   # new process, new connection, every call
```

keep a single long-lived `virsh` child per VM, write command lines to its stdin,
read replies from its stdout. The process spawn and the connection handshake are
paid once at startup instead of per call.

## What it buys

Measured on the host 2026-08-21 (`virsh qemu-agent-command Flow
'{"execute":"guest-ping"}'`, five runs): **31.16 ms** per call, of which
**17.78 ms (57 %)** is CPU inside `virsh` — the spawn, the dynamic link of
~50–70 shared objects, and client init.

The dev-box probes size that fixed overhead directly, because `test:///default`
does *no* connection work — so a one-shot call against it is spawn + dynamic
link + client init and nothing else. That is exactly the component a persistent
session deletes:

| | per call |
|---|---|
| one-shot `virsh -q -c test:///default echo hi` (20 runs) | **8.32 ms** |
| in-session framed call, incl. its sentinel (2000 runs) | **0.092 ms** |
| in-session command execution alone (`virsh -t` self-report) | 0.103 ms |

**~90× less fixed overhead**, and `ldd $(which virsh) | wc -l` = **61** shared
objects explains where the 8.32 ms goes. (8.32 ms here vs the host's 17.78 ms of
CPU is box-to-box variation plus the host's real connection; the *shape* — a
fixed multi-millisecond cost per call, fully removable — is confirmed.)

Crucially it keeps the property that makes `virsh` preferable to the Ruby
binding in the first place: **process isolation.** `ruby-libvirt` 0.8.4 imports
no `rb_thread_call_without_gvl` at all, so an in-process libvirt call freezes
every Ruby thread including the UI thread (measured; see the parent note's *GVL
trap*). A subprocess cannot do that — `Process.wait`/`IO#read` release the GVL.

So a persistent `virsh` session is the only option on the table that is **both**
spawn-free **and** GVL-safe, with no new dependency and no Ruby child to write:

| | spawn-free | GVL-safe | complexity |
|---|---|---|---|
| `virsh` per call (today) | no | yes | none |
| `ruby-libvirt` in-process | yes | **no** | low |
| Ruby helper subprocess + binding | yes | yes | high (IPC + lifecycle) |
| **persistent `virsh` session** | yes | yes | medium (this page) |

**Be honest about the size of the prize.** The existing 2 s poll is O(1) — one
`virsh domstats` for the whole fleet — so this saves it ~8–18 ms of 2000 ms,
about 1 % *of latency*. It pays much better on an **O(running-VMs)** workload,
which today means exactly one hypothetical consumer: per-VM guest-agent reads.
At N=10 that is 312 ms/tick, of which ~180 ms is pure per-call overhead.

**But latency is the wrong metric for the existing poll**, and the first draft
of this page judged it on latency alone. See the next section.

## Is it worth it for the *existing* O(1) poll?

The first draft said no. That verdict was reached on the wrong axis — 8 ms out
of a 2000 ms tick is invisible as *latency*, but the question that matters on a
hypervisor host is *load*, and VirTUI re-pays the spawn every 2 s for as long as
the TUI is open. Measured 2026-08-21, 200 iterations of `domstats` each way:

| per call | CPU (user+sys) | minor page faults |
|---|---|---|
| one-shot `virsh` | **7.8 ms** | **1065** |
| in-session | **0.100 ms** | **0.015** |

**78× less CPU, and ~70000× fewer minor faults.** The fault count is the more
interesting number: 1065 per spawn is the kernel mapping 61 shared objects,
applying relocations and churning page tables, all of it thrown away
milliseconds later. Holding a session open instead costs **0.0 ms of CPU over
5 s idle** — it blocks in `read()` — for 8.3 MB PSS resident.

At the real 2 s tick that is:

- **today:** 7.8 ms CPU per 2000 ms = **0.39 % of one core**, continuously,
  plus ~530 minor faults per second;
- **with a session:** 0.005 % of a core, plus 8.3 MB held.

**Two corrections to the first draft's reasoning.**

1. **The page-fault and CPU churn is real, and the mechanism argument is
   right:** a long-lived child with pipe comms is unambiguously less taxing on
   the host than re-execing a 61-library binary every two seconds. The first
   draft never measured this because it was only looking at wall-clock.
2. **This page conflated two different proposals.** All the per-VM sharding
   machinery — the circuit breaker, the fault-isolation argument, the RSS
   table — exists only to serve the O(N) guest-agent workload. Replacing the
   *existing fleet-wide `domstats` poll* needs **one** child, one command type,
   and no sharding at all. "Not worth it" was argued against the big version and
   silently inherited by the small one.

**What argued against it was never resources.** 0.39 % of one core is noise on
any box that runs VMs, and so is 8.3 MB — both sides of the resource ledger are
rounding errors. The real objection was that `domstats` is the one call feeding
*every number on screen*, and `Run.sync` turns a broken `virsh` into a non-zero
exit status and an exception. That objection was **answered rather than
accepted**: keeping the child's stderr on its own stream (gotcha 4) reproduces
`Run.sync`'s raise-with-stderr contract, so the loudness survives. What is left
of it is one prefix test on `error:`, named in gotcha 4 as the weakest joint.

**The measurement that would actually flip this is missing, and it is
daemon-side.** Everything above is *client* CPU, against a driver that does no
I/O. The current path also makes libvirtd, every 2 s, accept a unix socket, run
authentication, negotiate an RPC version, allocate a client object and a worker
thread, then tear it all down. That cost lands on the host too, competing with
real VM management, and it is plausibly the larger half — a persistent session
pays it once. `test:///default` cannot measure it. **Measure total system CPU
(client + libvirtd) for connect+domstats+disconnect versus an in-session
`domstats` on the real host**; if the daemon side is substantial, the verdict for
the existing poll flips on load grounds alone, independent of the guest-agent
consumer.

That missing number is why the transport shipped **opt-in** rather than as the
default: the client-side saving is real and measured, but the figure that would
justify flipping it on for everyone does not exist yet.

## One session per VM, not one shared

The parent note argued for a single shared helper on RSS grounds. That was
wrong, and the reason is the GVL finding: **inside one process, libvirt calls
cannot be overlapped at all.** Threads don't help — the GVL is held for the
call's full duration — so a shared session serialises every VM behind every
other VM, and one wedged `qemu-ga` delays *every* VM's sample by up to the
timeout, every tick. At a 2 s tick that is not a rounding error.

Per-VM sessions buy three things a shared one cannot:

1. **Fault isolation.** A wedged guest agent stalls only its own VM's stream.
2. **Independent recovery.** Kill and respawn one child; the others never notice.
3. **A natural circuit-breaker unit.** "This VM's agent is unhealthy" is a
   property of one child process, not a table the parent has to maintain.

**The RSS cost is now measured, and the note's guess was right.** `Pss` from
`/proc/<pid>/smaps_rollup`, children warmed with one command each:

| children | Σ RSS | Σ PSS | marginal PSS per extra child |
|---|---|---|---|
| 1 | 20.3 MB | 8.2 MB | — |
| 5 | 101 MB | 20.6 MB | 3.03 MB |
| 10 | 202 MB | 34.9 MB | 2.87 MB |
| 20 | 404 MB | 62.6 MB | 2.77 MB |

So **~2.8 MB per extra VM** — a ten-VM fleet costs ~35 MB. Summing RSS
overstates that by ~6.5× because almost all of those 61 shared objects are
shared pages; quote PSS, not RSS, if this ever needs defending. 20 sessions
stayed responsive at 0.37 ms per `dominfo`.

## The gotchas

Ordered as originally written, with the verdict from the probes.

### 1. You lose `argv`, so hand-escaping comes back — **NOT A PROBLEM, AND THE PREMISE WAS WRONG**

Billed as "the deep one". It isn't — and worse for the original framing, the
`argv` safety it claimed we would be giving up **does not exist in this
codebase**. {Run.sync} and {Run.async} take a command *String* and hand it to
`Open3`, which runs it through `/bin/sh` (verified: `Open3.capture3('echo *')`
comes back glob-expanded). {Virsh} therefore already hand-quotes, with plain
single quotes and no escaping:

```ruby
Run.sync("virsh setmem '#{domain_name}' '#{new_actual / 1024}'")
```

**That is a live latent bug, independent of this idea.** libvirt permits an
apostrophe in a domain name, and a VM called `it's` produces
`virsh setmem 'it's' '262144'` → `sh: 1: Syntax error: Unterminated quoted
string`, today, on every command that interpolates a name: `set_actual`,
`set_mem_stats_period`, `start`, `shutdown`, `reboot`, `reset`, `force_off`.

So a persistent session's `quote` (below) is **strictly safer than the status
quo**, not a regression: it is the same single-quote discipline with the
`'\''` case actually handled. `virsh`'s tokenizer follows POSIX-shell quoting
closely enough that the standard idiom just works:

| input line | `echo` returns |
|---|---|
| `{"execute":"guest-ping"}` | `{execute:guest-ping}` — unquoted strips `"` |
| `'{"execute":"guest-ping"}'` | intact |
| `'{"a":"b c","d":["e","f"]}'` | intact — spaces survive `'…'` |
| `'back\slash'` | `back\slash` — **`'…'` is fully literal, backslash included** |
| `"back\slash"` | `backslash` — `\` *is* an escape inside `"…"` |
| `'a'\''b'` | `a'b` — the shell idiom works; adjacent tokens concatenate |

So the rule is one line, and it is the one everybody already knows:

```ruby
# Wrap for virsh's tokenizer: single-quote, and close/escape/reopen around any
# embedded single quote. Identical to POSIX sh.
def self.quote(str) = "'#{str.gsub("'", "'\\\\''")}'"
```

`'…'` being *literal* is what makes this safe for JSON: `JSON.generate` emits
`\"`, `\\` and `\n` as two-character sequences, and single quotes pass them
through untouched where double quotes would eat the backslash. **Wrap in single
quotes, never double.**

**`virsh` blesses this algorithm itself.** `echo --shell` re-quotes for shell
use, and for input `it's` it emits exactly `'it'\''s'` — the same bytes `quote`
produces. It is a ready-made oracle; `echo --help` confirms
`--shell --xml --split --err --prefix` all exist.

Verified byte-exact round-trip for all of: the guest-ping payload, a payload
with spaces in values, `it's`, `back\slash`, the full nested `guest-exec`
payload with an embedded single quote, and a JSON blob containing `"`, `'`, `\`
*and* the literal prompt string.

**The one real constraint that replaces it: no raw control bytes, ever.**
Because readline is in the loop (gotcha 3), control characters in the input are
interpreted as *editing keys*, not data. All seven tested — TAB `\x09`
(readline's completion key), `\x01`, `\x0b`, `\x0d`, `\x15` (kill-line!),
`\x1b`, `\x7f` — corrupt the command and desync the session. This is survivable
only because JSON escapes them:

```ruby
JSON.generate({ 'k' => (0..0x1f).map(&:chr).join })   # no raw C0 byte in the output
```

**But `JSON.generate` passes `\x7f` (DEL) through raw.** So a wrapper must, on
top of `JSON.generate`, reject or escape DEL and assert no byte below `0x20`.
That is the whole of the escaping burden — much smaller than the note feared,
but not zero, and it is the kind of thing that only shows up in a fuzz test.

### 2. Block buffering will deadlock you — **FALSE ALARM**

There is no deadlock and no need for `stdbuf`. With `Open3.popen2e`, stdin held
open and never closed, replies arrive in **0.09–0.37 ms**: a one-line reply, a
16-line `dominfo`, and a silent `setmaxmem` all came back promptly without the
pipe ever being closed.

The reason is gotcha 3: `virsh` writes a prompt after every command and readline
flushes it, so the stream is pushed out whether you wanted a prompt or not. The
mitigation the note proposed (`stdbuf -oL`) is unnecessary.

### 3. There is no reply framing — **MISDIAGNOSED, AND WORSE — BUT FIXABLE**

The note assumed the stream is command outputs concatenated with nothing between
them. It is not. **`virsh` drives GNU readline even when stdin is a pipe**, so
the stream also carries:

- a **`virsh #` prompt** after every command — on a plain pipe, no pty needed;
- an **echo of your own input line**, written by readline, not by you;
- with an inherited `TERM`, **ANSI redisplay escapes** — a probe caught a
  cursor-home + clear-screen pair at the head of a reply;
- for a line longer than readline's idea of the terminal width,
  **non-deterministic re-emission** of the line as readline re-wraps it. A
  16 KB payload came back with 16351 `x`s where 8175 were sent — the line
  emitted roughly twice, and *how many times* varied run to run.

That last one is why an early bisect for a "line length limit" produced the
nonsense non-monotonic answer 4081✗ 4096✓ 4200✗ 5000✓. There is no length
limit. There was a redisplay race.

Neither `-q` nor anything else suppresses prompt or echo, and **there is no
`-f`/`--file` option in 12.0.0** (`error: unsupported option '-f'`), so there is
no clean-stream mode to switch to.

**The fix is two environment variables on the child.**

```ruby
CHILD_ENV = { 'TERM' => 'dumb', 'COLUMNS' => '1000000' }.freeze
Open3.popen3(CHILD_ENV, 'virsh', '-q', '-c', uri)   # popen3: see gotcha 4
```

- `TERM=dumb` (or unset) removes every ANSI byte: 0/20 trials contained an
  escape, against 20/20 with `TERM=tmux-256color` or `vt100`.
- `COLUMNS` larger than the longest line stops the re-wrap, and **the input-line
  ceiling is then exactly `COLUMNS`** — that is the whole mechanism:

| | 8 K line | 16 K | 64 K | 256 K |
|---|---|---|---|---|
| `COLUMNS=10000` | OK | ✗ | ✗ | ✗ |
| `COLUMNS=100000` | OK | OK | OK | ✗ |
| `COLUMNS=1000000` | OK | OK | OK | OK |

With both set, the stream is **byte-exact and fully deterministic** — 15/15
trials at every size from 40 B to 4 KB, versus 0/15 for `TERM=dumb` alone at
anything ≥ 79 characters (readline defaulting to 80 columns).

The structure is then precisely, with no separator you did not ask for: the
echoed command line, a newline, the reply bytes, then the next prompt. Note the
reply is **glued to the prompt with no intervening newline** (`echo` emits no
trailing newline), so "read a line" is still wrong — read bytes.

**Prompt-as-delimiter is unsafe, and not for the reason the note gave.** The
note worried a *reply* might contain the prompt string. The real hazard is the
*echo*: send a payload containing it and the read terminates on your own echoed
request, one frame early, desyncing everything after it. Observed exactly — a
payload of `virsh # FORGED tail` terminated the first read on its own echo, and
the next call received the previous frame's leftovers.

**The primitive that works is an asymmetric sentinel.** Split a nonce with a
quote so the tokenizer reassembles it: the *output* byte-sequence then cannot
occur in the echoed *input*, whatever the payload contains.

```
send:    echo 'VT66'f1f0f93679
stream:  echo 'VT66'f1f0f93679 \n VT66f1f0f93679 <prompt>
         input has no "VT66f1f0f93679"  |  output has exactly one
```

### 4. No per-command exit code, and errors land on stderr — **CONFIRMED, and the loudness regression is avoidable**

Confirmed as described: errors are human text on stderr, `error: failed to get
domain 'nosuchdomain'`, and the session exit code stays 0 no matter how many
commands failed. A failed command **does not desync** — the next call is clean.

**But the note's own mitigation was wrong.** It said to merge stderr into stdout
(`popen2e`) so error text orders deterministically against the marker. Merging
does work — ordering is preserved, verified by alternating stdout and
`echo --err` commands — but it destroys the more valuable property: the parser
must be fed *stdout only*, exactly as `Run.sync` feeds it today, or stray
libvirt chatter becomes parser input.

**Keep the streams separate (`popen3`) and the loudness regression disappears.**
The sentinel is on stdout, so framing is unaffected by stderr timing; and
because `virsh` is strictly serial, anything sitting on stderr by the time the
sentinel appears on stdout **belongs to this frame**. That is the same serialism
argument that makes the framing sound, reused for error attribution. Measured:

| frame | stdout | stderr |
|---|---|---|
| `domstats`, healthy | 48 B, byte-identical to one-shot | `""` |
| `dominfo nosuchdomain` | `""` | `error: failed to get domain 'nosuchdomain'\n` |
| next call after that failure | 48 B | `""` — no contamination |

So `sync` can reproduce `Run.sync`'s contract exactly: return stdout, raise with
stderr when stderr is non-empty. **Do not use "empty stdout" as the failure
signal** — a host with zero VMs returns an empty `domstats` legitimately.

### 5. A timeout desyncs the stream — **CONFIRMED, and the framing makes it SAFE**

`event --loop --all --timeout 30` is a usable stall simulator. Confirmed: the
read times out, **the child stays alive**, and kill + respawn recovers (the
replacement session answered correctly).

The important new result is that the desync *is detected*. Abandon a call, let
its reply land in the pipe, then issue the next one: asserting that the buffer
starts with the exact command you just sent raises rather than mis-attributing.

```
gave up on the stalled call
next call raised Desync: echo mismatch: "event loop timed out\nevents received: 0\n…
```

**The readline echo — the thing that looked like pure pollution in gotcha 3 — is
what makes desync detectable.** Silently attributing VM A's numbers to VM B was
the scenario worth fearing; the echo assertion closes it.

`qemu-agent-command`'s in-band bounding is confirmed to exist, so the child can
fail fast and stay usable: `[--timeout <number>] [--async] [--block] [--pretty]`.

**Still unverified:** a genuinely wedged `qemu-ga`. The test driver rejects
`qemu-agent-command` instantly (`error: this function is not supported by the
connection driver: virDomainQemuAgentCommand`) rather than blocking, so
`event --loop` is a stand-in for the *stall*, not for the agent.

### 6. Connection loss now needs explicit handling — **PARTLY ANSWERED, LESS SCARY**

A failed in-session `connect` is **non-destructive**, which the note assumed it
would not be. Connecting to the dead `qemu:///system` fails in 9 ms, prints its
two `error:` lines — and the **previous connection keeps working**: `list --all`
still returned the test domain afterwards. A subsequent `connect test:///default`
then succeeded in place, and `list --all` still worked.

So in-place `connect` is a genuine recovery option, not just a state-machine
liability, and `-k/--keepalive-interval` exists as a detection knob. Respawn is
still the simpler policy.

**Still unverified:** a server-side disconnect — libvirtd restarting under a live
session. No daemon on this box, and the test driver cannot be made to drop a
connection. This is the one gotcha the dev box genuinely cannot reach.

### 7. It is a human REPL, not a stable IPC protocol — **UNCHANGED**

Mitigation stands and is now cheap to state: route only machine-shaped output
(`qemu-agent-command`'s JSON) through the session; leave human-formatted
commands on `Run.sync`, where an exit code still exists.

## Built (2026-08-21), default (2026-08-23)

Landed as {Virt::VirshSpawn} and {Virt::VirshSession} behind the runner seam, opt-in
behind `VIRTUI_VIRSH_SESSION=1` for the trial and the unconditional read transport in
`bin/virtui` since. The recipe and the file plan that used to sit here are now the code
and its yardoc; the decision and its rejected alternatives are DECISIONS.md
D-virsh-session. What stays on this page is the *evidence* — the measurements above and
the gotcha verdicts — plus the two open questions below that need a real host.

End-to-end through the real {Virt::Virsh} parser, 100 `domstats` reads against
`test:///default`: **7.79 ms/read spawning, 0.121 ms/read in-session — 64x**.

Verified on the way in, beyond the specs:

- a host with no libvirtd raises loudly per call (`error: failed to connect to the
  hypervisor`) and does **not** degrade — the session is healthy, the host is not;
- `close` reaps the child; no `virsh` survives the process;
- both transports pass `-q`, so their output is byte-identical (a spec asserts it).

## What is left to verify, and it needs a real host

Everything cheap is done. Only two things remain, and neither can be reached
from a daemon-less box:

1. **Daemon-side connection cost** — total system CPU for
   connect+`domstats`+disconnect versus an in-session `domstats`, on a real
   `qemu:///system`. No longer a decider (the session is the default on field
   evidence, and this can only widen the win, never narrow it); just a number
   nobody has put on it. See the O(1) section above.
2. **A wedged `qemu-ga`** — does `qemu-agent-command --timeout N` really return
   control to the session, or does the child need killing? (gotcha 5)
3. **libvirtd restarting under a live session** — does the session notice, and
   does in-place `connect` recover it? (gotcha 6)
4. Then re-measure the win on the host against the 31.16 ms baseline before
   deciding it is worth the remaining gotchas.

## Honest summary — revised

The mechanism is more attractive than the first draft concluded, and the cost is
differently shaped than feared.

- The quoting gotcha, billed as the deep one, is **one line of POSIX
  single-quoting that `virsh echo --shell` itself validates**. What replaces it
  is narrower and sharper: no raw control bytes, which JSON almost gives you
  free — except DEL.
- The buffering gotcha **does not exist**.
- The framing gotcha was **misdiagnosed**: the stream is polluted by readline,
  not merely unframed, and with an inherited `TERM` it is not even
  deterministic. Two environment variables make it byte-exact, and an asymmetric
  sentinel makes it payload-proof.
- The desync gotcha is **real but detectable** — and detectable precisely
  because of the readline echo that gotcha 3 treats as noise.
- Connection loss is **less destructive** than assumed.

- The **load** argument for doing it even at O(1) is real and was missed
  entirely by the first draft: 78× less CPU and ~70000× fewer minor page faults
  per call, against a spawn re-paid every 2 s for the life of the TUI.

The objection that survived two drafts — that this trades a loud, quoting-proof,
self-healing call path for one with prefix-matched errors — **is answered twice
over, and neither answer is an argument.**

- **By scope:** route only `domstats` and `nodeinfo` through the session and
  every mutating command keeps `Run.sync` and its exit status. The session then
  carries one argument-free command, so the quoting analysis is dormant, and a
  failed session degrades to `VirshSpawn` — today's behaviour exactly.
- **By `popen3`:** keeping stderr separate means a failed read raises with its
  stderr text, which *is* `Run.sync`'s contract. The note recommended merging
  the streams; that was the mistake, not the transport.

**One honest correction to that second point.** An earlier draft of this section
claimed "no prefix matching in the design at all". Too strong. Without an exit
code, *something* must decide whether stderr content means "the command failed"
or "libvirt was chatty", and libvirt's own log lines do reach stderr in a
different shape from `vshError`'s `error: ` prefix. Treating *any* stderr as
failure would raise spuriously on a deprecation or cgroup warning. So the design
classifies: `error:`-prefixed lines fail the call, anything else is logged at
`warn` and the call succeeds.

That is still a much smaller heuristic than the one the earlier verdict rejected
— it classifies a *dedicated error channel* rather than sniffing failure out of
the data stream, and stdout reaches the parser byte-identical either way. But it
is a heuristic, and it is the single weakest joint in the design. Logging the
unclassified remainder at `warn` rather than `debug` is deliberate, and stayed
that way when the session became the default: a misclassification here must not
be quiet.

What is left is a bounded optimisation on the one call that runs 30 times a
minute for hours, whose output is byte-identical to what it replaces.

Two things made the earlier "no" wrong rather than merely narrow:

- it judged **latency** (1 % of a tick) when the cost that matters on a
  hypervisor host is **load** (78× CPU, ~70000× page faults per call);
- it assumed `Open3` gave **argv safety we do not actually have** — `Run.sync`
  goes through `/bin/sh` and `Virsh` already hand-quotes, badly enough to break
  on an apostrophe in a VM name.

So: **build it**, as a second transport behind the existing `Run.sync` seam. The
O(running-VMs) guest-agent case remains the thing that would justify the *per-VM
sharding*; the O(1) read path justifies the *session* on its own.

## Where the nuggets landed, and what is still owed

Landed with the implementation:

- the transport choice and its roads not taken → **DECISIONS.md D-virsh-session**
- the quoting rule (single quotes, never double, because `'…'` is literal) →
  **yardoc** on {Virt::VirshSession.quote}, now the project's only quoting code.
  The shell-quoting bug this page kept flagging — `virsh setmem 'it's' …` — is
  fixed by structured arguments instead → **DECISIONS.md D-argv-not-shell**
- `TERM=dumb` + oversized `COLUMNS` are load-bearing, and why → **yardoc** on
  {Virt::VirshSession::CHILD_ENV}. The single most surprising fact on this page,
  and the one most likely to be "cleaned up" by a later reader
- completeness comes from `virsh`'s serialism, not a timeout; the echo assertion
  is the desync guard rather than a sanity check; command vs transport failure
  → **yardoc** on the class and on `#query`
- `popen3` not `popen2e`, so the parser gets stdout alone → **yardoc**
- don't read the backend from the UI thread → **CLAUDE.md** § *Threading*
- `virsh -c test:///default` as a daemon-free way to exercise a real `virsh` →
  used by `spec/virt/virsh_session_spec.rb`

Still owed, and deliberately not written yet:

- **the no-raw-control-bytes rule** including the `JSON.generate` DEL hole. The
  session carries no caller-supplied payload today, so nothing can carry a control
  byte; this lands with the first guest-agent command, not before
- **the daemon-side connection cost** — was billed as the measurement deciding
  whether the session becomes the default; the field trial decided that first
  (see *Is it worth it for the O(1) poll?*)
- the 31.16 ms / 57 % host baseline and the dev-box figures are evidence and live
  here; they die with this file
