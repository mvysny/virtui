# A persistent `virsh` session as a spawn-free libvirt transport

**Status:** **decided to implement** (2026-08-21) as a second `virsh` transport,
on host-load grounds — see *Is it worth it for the O(1) poll?* and
*Implementation sketch*. Nothing built yet. Spun out of
`swap-via-qemu-guest-agent.md` on 2026-08-21, where it appeared as a footnote.

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

**What still argues against it, and it is not resources.** 0.39 % of one core is
noise on any box that runs VMs, and so is 8.3 MB — both sides of the resource
ledger are rounding errors, so resources do not decide this. What decides it is
that `domstats` is the one call feeding *every number on screen*, and today it
runs through `Run.sync`, where a broken `virsh` is a non-zero exit status and a
raised exception. Routing it through a session swaps that for `error:`-prefix
matching on a text stream (gotcha 4) — trading the loudest failure detection in
the app, on its most load-bearing path, for a fraction of a percent of a core.
CLAUDE.md's *Errors are loud* points the other way.

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

Until that number exists: still no, but for a *much* narrower reason than the
first draft gave — not "the saving is negligible" (it is 78×) but "the saving is
in a resource nobody is short of, and it is paid for in error-reporting
fidelity on the app's most important call".

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
Open3.popen2e(CHILD_ENV, 'virsh', '-q', '-c', uri)
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

## The tested recipe

Everything above collapses to about forty lines. Kept here rather than in `lib/`
because nothing has decided to build it.

```ruby
class Framed
  PROMPT = 'virsh # '
  # Both are load-bearing: virsh drives readline even on a pipe, so TERM=dumb
  # suppresses ANSI redisplay and a huge COLUMNS stops it re-wrapping (and
  # re-emitting) long input lines. Without both, the stream is not deterministic.
  CHILD_ENV = { 'TERM' => 'dumb', 'COLUMNS' => '1000000' }.freeze

  def self.quote(str) = "'#{str.gsub("'", "'\\\\''")}'"

  # popen3, not popen2e: the parser must be fed stdout only (see gotcha 4).
  # @return [String] the command's stdout, byte-identical to `Run.sync`'s
  def call(cmd, timeout: 5.0)
    nonce = "VT#{SecureRandom.hex(6)}"
    # Asymmetric: the tokenizer strips the quotes, so the *output* bytes cannot
    # appear in the echoed *input* line, whatever the payload contains.
    sentinel = "echo '#{nonce[0, 4]}'#{nonce[4..]}"
    @w.write("#{cmd}\n#{sentinel}\n")   # pipelined: one write, two commands
    @w.flush

    buf, st = read_until(@out, "#{nonce}#{PROMPT}", timeout: timeout)
    raise Timeout, 'no sentinel' unless st == :ok
    # This assertion is the desync guard — it catches an abandoned late reply.
    raise Desync, 'echo mismatch' unless buf.start_with?("#{cmd}\n")

    body = buf[(cmd.bytesize + 1)..]
    i = body.rindex("#{PROMPT}#{sentinel}\n#{nonce}#{PROMPT}")
    raise Desync, 'sentinel tail not found' unless i

    # virsh is serial, so whatever is on stderr now belongs to this frame.
    errors = slurp(@err)
    raise CommandFailed, errors unless errors.empty?

    body[0, i]
  end
end
```

Read until the sentinel **and** the prompt that follows it, so the stream is
always left positioned immediately after a prompt; forgetting the trailing
prompt shifts every subsequent frame by eight bytes.

## Implementation sketch

### How do we know the output is complete?

This is the load-bearing question, and the answer is *not* a timeout.

You cannot conclude "the command finished" from the pipe going quiet — absence
of bytes is indistinguishable from latency, and a reply that arrives 1 ms later
would then be attributed to the *next* command. What makes this sound is that
**`virsh`'s REPL is strictly serial**: read a line → execute → write output →
write prompt → read the next line. It never overlaps two commands.

So send **two** commands, the real one and a sentinel `echo`, and `virsh`
physically cannot emit the sentinel's output until the real command's output is
finished. **Seeing the sentinel's output is proof of completeness** — an
ordering guarantee from the producer, not a heuristic.

That gives *both* boundaries positively identified, with no timeout in the
correctness path:

| boundary | how it is found | why it holds |
|---|---|---|
| start of reply | readline echoes the input line; assert the buffer opens with `"#{cmd}\n"` | echo precedes execution |
| end of reply | the asymmetric sentinel's output bytes | virsh is serial |

The read timeout stays, but only as a **liveness** backstop — "this VM's agent is
wedged" — never as the thing that decides where a reply ends.

**On interleaving:** the note's framing is right that two commands cannot be in
flight *unmatched*, but the constraint is narrower than "drain before sending".
Replies come back **strictly in order**, so you may *pipeline* — the recipe above
writes `cmd\nsentinel\n` in one `write`, which is a pipeline of two, not an
interleave. What is genuinely forbidden is **two concurrent callers on one
session**, so a session needs a mutex (or a single owning thread).

### Where it plugs in: a second transport, not a second client

`Virsh` is 190 lines, of which ~150 is `domstats`/`nodeinfo` *parsing* — the
valuable, fixture-tested part. A peer `Virt::VirshSession` implementing the whole
client role would either duplicate that parser or inherit to share it, which is
the anti-pattern the `cop` skill forbids outright.

The seam is one level lower, and **it already exists**: every method of `Virsh`
reaches the outside world through exactly `Run.sync` / `Run.async`. Make that a
collaborator.

```ruby
# The role, in full. Two implementations; `subcommand` excludes the `virsh` word.
#   sync(subcommand)  -> String   (stdout; raises on failure)
#   async(subcommand) -> Thread   (fire-and-forget; logs failure)
Virt::VirshSpawn    # today's behaviour: Run.sync("virsh #{subcommand}")
Virt::VirshSession  # the persistent REPL from the recipe above
```

`Virsh.new(runner: VirshSpawn.new)` by default, so nothing changes unless asked.
`Virsh` keeps every line of parsing and gains no knowledge of pipes; the runner
knows nothing of `DomainData`. Dependencies point toward data, and the runner is
a service in the `cop` sense — one purpose, no rendering surface, independently
testable.

Defining the seam as *virsh subcommand* rather than *shell command* is what
makes one interface serve both: the session must write `domstats`, not
`virsh domstats`.

### Only the read path goes through the session

This is the decision that shrinks the risk to almost nothing.

| command | transport | why |
|---|---|---|
| `domstats` (every 2 s) | **session** | this is the entire load saving |
| `nodeinfo` (once, at startup) | session | free, same path |
| `setmem`, `dommemstat`, `start`, `shutdown`, `reboot`, `reset`, `destroy` | **spawn** | they mutate, and must stay loud |

Two consequences worth stating plainly:

1. **Every mutating command keeps `Run.sync`'s non-zero-exit loudness.** The
   objection that killed the first verdict — trading exit codes for `error:`
   prefix matching — applies only to reads, whose failure surfaces as stale data
   anyway. This is also gotcha 7's rule (route only machine-shaped output) and
   the answer to `Run.async`: a long `virsh start` would block the *whole
   session* for ~800 ms, since one child has no internal concurrency. Async work
   must spawn. That is not a workaround; it is the correct split.
2. **The quoting problem evaporates.** The session carries exactly one recurring
   command, `domstats`, **with no arguments**. No payload, no `quote`, no
   control-byte exposure. The entire gotcha-1 analysis is dormant insurance,
   needed only if guest-agent commands later join. (`quote` is still worth
   writing — it fixes the apostrophe bug above on the spawn path.)

### Failure policy: two classes, and they must not be confused

An earlier draft of this section said "retry once, then degrade to spawn" for
*any* failure. **That is wrong**, and the probe that shows why is worth keeping:
interactive `virsh` with no reachable hypervisor **stays in the REPL**. It does
not exit, and it does not even complain at startup — the connect is *lazy*, so
the prompt appears immediately and the failure surfaces per-command:

```
virsh # list --all
error: failed to connect to the hypervisor
error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': No such file…
virsh # echo --prefix B: still-alive      <- session is fine
B: still-alive
```

So on a daemon-less host **every** call fails while the session is perfectly
healthy. Respawning or degrading there would be pointless churn forever. Split
the two:

| class | signal | response |
|---|---|---|
| **command failure** | stderr non-empty for the frame | `raise` with the stderr text — exactly `Run.sync`'s contract. Do **not** touch the session. |
| **transport failure** | `Desync`, `Timeout`, `EOF` | kill the child, respawn, retry **once**; if that fails too, log once and degrade permanently to `VirshSpawn`. |

The whole feature is an optimisation, so it must never become a new failure
mode. Degrading restores exactly today's behaviour, which also covers the one
gotcha the dev box cannot test (a libvirtd restart, gotcha 6) without needing to
reason about it: the session dies, reads keep working, and a warning says why.

Lazy connect has a pleasant corollary: the connection handshake is paid on the
first `domstats`, not at startup, so nothing has to be sequenced around it.

### Two findings that make this a transport-only change

- **In-session output is byte-identical to one-shot output.** Verified for both
  commands the session will carry: `domstats` (48 B) and `nodeinfo` (205 B),
  exact string equality against `Open3.capture3`. So the parsers in {Virsh} need
  no change, and every recorded fixture in `spec/` stays valid. The diff really
  is confined to *how the text is fetched*.
- **Don't hardcode `virsh # `.** The prompt is cosmetic and unversioned, which
  gotcha 7 flags as a coupling risk — but it is also the *first thing the child
  writes*. Read it during the startup handshake and use those bytes as the
  prompt for the rest of the session. A read-until-quiescent timeout is
  acceptable there and only there: at startup there is no previous frame, so
  there is nothing to desync from.

### Threading and lifecycle

- **One owner thread.** `Cache#update` runs on the timer thread and is the only
  caller of the read path, so the session is touched from one thread. Guard
  `sync` with a `Mutex` anyway — it is two lines, and `hostinfo` is called from
  `Cache#initialize` on the main thread. This joins CLAUDE.md's existing
  threading rule: the session is a *timer-thread* resource, never touched from
  the UI thread.
- **Explicit shutdown.** The child must be reaped in `bin/virtui`'s existing
  `ensure`, or every run of VirTUI leaks a `virsh`.
- **`Virsh.available?` still gates everything**; with no `virsh` the demo fleet
  runs as now.

### Testing

`virsh -c test:///default` is a **real `virsh` with no daemon**, which is how this
whole page was probed — so the session is testable in CI-ish conditions, not only
against a hypervisor:

- transport specs against `test:///default`, skipped unless `Virsh.available?`;
- the desync guard: stall the session with `event --loop --all --timeout 30`,
  abandon it, assert the next call *raises* rather than returning the stale
  reply — this is the spec that protects the property nothing else can;
- framing: a payload containing `virsh # ` round-trips (guards the sentinel);
- a fuzz spec over control bytes, asserting the wrapper rejects them.

The existing `Virsh` parser specs are untouched — they pass canned text straight
to `domain_data(fixture)` and never reach a runner. That is the payoff of putting
the seam below the parsing.

### Rough shape of the change

- new `lib/virt/virsh_spawn.rb`, `lib/virt/virsh_session.rb` (one constant per
  file, per the Zeitwerk rules)
- `lib/virt/virsh.rb`: add `runner:` to the constructor, replace the
  `Run.sync("virsh …")` calls with `@runner.sync("…")`, drop the `virsh` prefix
  from each command string
- `bin/virtui`: build the session runner, pass it to `Virsh`, close it in
  `ensure`
- `DECISIONS.md`: the transport choice and the roads not taken
- README: nothing — this is invisible to users

## What is left to verify, and it needs a real host

Everything cheap is done. Only two things remain, and neither can be reached
from a daemon-less box:

1. **Daemon-side connection cost** — total system CPU for
   connect+`domstats`+disconnect versus an in-session `domstats`, on a real
   `qemu:///system`. This is the one that could flip the verdict for the
   *existing* poll; see the O(1) section above.
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
  stderr text, which *is* `Run.sync`'s contract. There is no prefix matching in
  the design at all. The note recommended merging the streams; that was the
  mistake, not the transport.

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

## Where the nuggets land if this graduates

- the transport choice, with per-call `virsh` / in-process binding / helper
  process as the roads not taken → **DECISIONS.md**
- **`TERM=dumb` + oversized `COLUMNS` are load-bearing, and why** (readline runs
  on a pipe; `COLUMNS` *is* the line-length limit) → **yardoc** on the session
  class. This is the single most surprising fact on the page and the one most
  likely to be "cleaned up" by a later reader.
- the quoting rule (single quotes, never double, because `'…'` is literal), the
  no-raw-control-bytes rule incl. the `JSON.generate` DEL hole, the asymmetric
  sentinel, and "recovery is kill-and-respawn" → **yardoc**
- the echo assertion is the desync guard, not a sanity check → **yardoc**, as a
  warning against deleting it
- **`virsh`'s serialism is what licenses both the framing and the stderr
  attribution** — the sentinel cannot precede the previous output, and stderr
  seen by sentinel-time belongs to that frame → **yardoc** on the session; it is
  the reason the design needs no timeout in its correctness path
- **`popen3`, not `popen2e`, and why** (the parser gets stdout only, so
  `Run.sync`'s raise-with-stderr contract survives) → **yardoc**
- command failure vs transport failure are different classes with different
  responses, because a daemon-less host fails every call from a healthy session
  → **yardoc** on the failure path
- the pre-existing shell-quoting bug on the spawn path (a VM named `it's` breaks
  `setmem`) is **not** part of this idea — it wants its own fix, whatever
  happens here
- "a persistent-session call must never run on the UI thread, and must be bounded
  by both `--timeout` and a parent-side read timeout" → **CLAUDE.md**
- `virsh -c test:///default` as a daemon-free way to exercise a real `virsh`
  (this whole page was probed that way) → worth a line wherever the specs
  explain their fakes, alongside `Virt::VMEmulator`
- the 31.16 ms / 57 % host baseline and the 8.32 ms → 0.092 ms dev-box numbers
  are evidence and live here; they die with this file
