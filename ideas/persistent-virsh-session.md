# A persistent `virsh` session as a spawn-free libvirt transport

**Status:** brainstorm, nothing decided, nothing built. Spun out of
`swap-via-qemu-guest-agent.md` on 2026-08-21, where it appeared as a footnote.

**Nothing on this page has been verified against a real `virsh`.** There is no
`virsh` on the dev box; every claim below is reasoning from how `virsh` and libc
stdio work, and each gotcha ends with what to run to confirm it. Treat the
gotcha list as a test plan, not as findings.

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
~50–70 shared objects, and client init. That 17.78 ms is what a persistent
session removes. Some unknown further slice of the remaining 13.39 ms is the
libvirt connection handshake, also removed; see the parent note for the
three-command decomposition that would size it.

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
`virsh domstats` for the whole fleet — so this saves it ~18 ms of 2000 ms, about
1 %. Not worth doing for the current loop. It only pays on an **O(running-VMs)**
workload, which today means exactly one hypothetical consumer: per-VM guest-agent
reads. At N=10 that is 312 ms/tick → ~134 ms. Since that consumer is itself on
hold, so is this.

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
   This matters more than it looks — see gotcha 5, where kill-and-respawn is the
   *only* safe recovery from a timeout.
3. **A natural circuit-breaker unit.** "This VM's agent is unhealthy" is a
   property of one child process, not a table the parent has to maintain.

The cost is N resident processes. Worth measuring rather than assuming: `virsh`
links a large dependency tree, but most of it is shared pages across identical
processes, so marginal RSS per extra child should be well under a private copy.
`ps -o rss= -C virsh` with one child vs five answers it.

## The gotchas

Ordered roughly by when they will bite.

### 1. You lose `argv`, so hand-escaping comes back

**This is the deep one, and it is the honest answer to "what's the problem".**

With `Open3` you pass the JSON as one element of an argv array. No shell, no
tokenizer, no quoting — a payload containing quotes, braces, spaces and
backslashes arrives at `virsh` byte-for-byte. Quoting simply isn't a category of
bug that exists.

An interactive session has no argv. You write a **line of text** that `virsh`
tokenizes itself, with its own quoting rules (`vsh.c`'s command-string parser:
unquoted whitespace splits; `'…'` and `"…"` group; backslash escapes). The
guest-agent payload is exactly the hostile case:

```
qemu-agent-command Flow '{"execute":"guest-exec","arguments":{"path":"/bin/sh","arg":["-c","cat /proc/meminfo"],"capture-output":true}}'
```

Double quotes throughout, and once you nest a guest command containing a single
quote (`sh -c "echo it's"`), single-quote wrapping fails the same way it does in
shell — there is no escaping a `'` inside `'…'`.

So this design **reintroduces precisely the bug class that killed the first
working attempt** in the parent note, whose hard-won rule was *never hand-escape
the JSON; build it with `JSON.generate`*. `JSON.generate` still gets you correct
JSON — but you must then correctly escape that JSON *for virsh's tokenizer*,
which is a second, separate escaping layer that argv had made unnecessary.

*Mitigation.* Write one `virsh_quote(str)` and test it hard, because `virsh` ships
the perfect oracle: the `echo` command, which exists specifically to inspect
quoting. Believed to support `--shell` and `--xml` re-quoting — verify with
`virsh echo --help`. Round-trip every nasty payload through it and assert the
bytes come back intact:

```
echo '{"a":"b c","d":["e","f"]}'
echo "it's"
echo 'back\slash'
```

Do this **before** writing any session plumbing: if virsh's tokenizer cannot
round-trip the payloads, the whole idea is dead and it costs five minutes to find
out.

### 2. Block buffering will deadlock you

When stdout is a pipe rather than a TTY, libc gives `virsh` a **fully buffered**
stream (4–8 KB) instead of a line-buffered one. A reply that doesn't fill the
buffer may sit inside `virsh` indefinitely: the parent blocks reading a reply
that was already produced. This is the classic pipe deadlock and the most likely
first failure.

*Mitigation.* `stdbuf -oL -eL virsh …` forces line buffering from outside (works
because `virsh` uses ordinary stdio and doesn't install its own buffer). Or run
it under a pty, where libc line-buffers by default — but see gotcha 3b.
`virsh` may well flush after each command anyway; that is the single most
important thing to test first.

*Test.* Spawn it, send one command, and see whether the reply arrives before the
process is closed:
`printf 'hostname\n' | timeout 5 virsh` should print promptly; then hold the pipe
open (`Open3.popen3`, write, `sleep`, read) and check the reply still arrives.

### 3. There is no reply framing

Command outputs arrive concatenated on one stream with nothing marking where one
ends and the next begins. Multi-line replies and **empty** replies (many `virsh`
commands succeed silently) make "read until blank" and "read one line"
both wrong. Correlating reply to request is your problem.

*Mitigation (recommended).* Send a sentinel after every real command and read
until you see it:

```
qemu-agent-command Flow '{"execute":"guest-ping"}'
echo __VIRTUI_7f3a__
```

Everything before the marker is the reply; the marker is unambiguous because you
chose it. Use a fresh nonce per request and you also detect desync (gotcha 5)
instead of silently mis-attributing a reply.

*3b. Mitigation (not recommended): use the prompt.* Under a pty `virsh` prints
`virsh # ` and you could delimit on that. It drags in terminal echo (your own
command line comes back at you and must be stripped), `\r\n` translation, and
`PTY.spawn` lifecycle handling — and it makes you depend on the prompt string,
which is cosmetic and unversioned. The explicit marker is strictly better.

### 4. No per-command exit code, and errors land on stderr

`Run.sync` raises on a non-zero exit status; that is the whole basis of
CLAUDE.md's *Errors are loud* / *don't swallow failures from `virsh`* rule. An
interactive session has **one** exit code, at the end of the session. Per-command
failure is reported only as human text (`error: …`) on **stderr**, whose
interleaving with stdout is not ordered relative to your marker.

*Mitigation.* Merge stderr into stdout at spawn so ordering against the marker is
deterministic, then treat any `error:`-prefixed line before the marker as a
failure and raise. This is textual error detection — strictly weaker than an exit
code, and a real regression in loudness that should be stated wherever this lands.

### 5. A timeout desyncs the stream — and kill is the only safe recovery

If the guest agent wedges, `virsh` blocks mid-command and the reply never comes.
The parent times out — and is now in an unrecoverable position: a late reply may
still arrive later and be read as the *next* command's reply. Silently attributing
VM A's memory numbers to VM B is far worse than a missing sample.

*Mitigation.* On read timeout, **kill the child and respawn.** Do not attempt to
resync. Per-request nonces (gotcha 3) turn any residual desync into a detected
error rather than corrupt data.

This is what makes per-VM sharding structural rather than nice-to-have: the only
safe recovery destroys the session, so the session must not be shared. It also
argues for bounding the call in-band as well — `qemu-agent-command` takes
`--timeout N` (believed also `--async`, `--block`; check `virsh
qemu-agent-command --help`), so the child can fail fast and stay usable, with the
parent-side timeout as the backstop.

### 6. Connection loss now needs explicit handling

Per-call `virsh` reconnects every time, for free: if libvirtd restarts, the next
call just works. A persistent session holds one connection; when libvirtd is
restarted (package upgrade, crash) the session survives as a process but every
subsequent command fails. Persistence converts a self-healing property into
something you must implement.

*Mitigation.* Simplest is to treat it like gotcha 5 — on repeated errors, kill
and respawn. `virsh`'s in-session `connect` command could reconnect in place, but
respawning is fewer states to reason about.

### 7. It is a human REPL, not a stable IPC protocol

`virsh`'s interactive output is a UI for people: wording, alignment and column
layout carry no compatibility guarantee across versions. For
`qemu-agent-command` this is mild — the payload is raw JSON passed through — but
any other command parsed this way is a version-coupling risk that the one-shot
path shares only for the commands it already parses.

*Mitigation.* Only route commands through the session whose output is
machine-shaped (`qemu-agent-command`'s JSON). Leave human-formatted commands on
`Run.sync`, where an exit code still exists.

## Verify in this order

Each step can kill the idea; do them cheapest-first.

1. `virsh echo --help`, then round-trip the hostile payloads of gotcha 1. If the
   tokenizer can't carry them, stop.
2. Hold a pipe open, send one command, read the reply *without* closing stdin —
   does it arrive? If not, retry under `stdbuf -oL`. If neither works, stop.
3. `echo` as a sentinel: confirm a marker line comes back verbatim and
   distinguishably after a multi-line and an empty reply.
4. Break it on purpose: `systemctl restart libvirtd` mid-session (gotcha 6), and
   an agent-less or paused domain (gotcha 5).
5. Only then measure the actual win — per-call latency in-session vs the 31.16 ms
   one-shot baseline — and compare against the parent note's cost table before
   deciding it is worth the seven gotchas.

## Honest summary

The mechanism is genuinely attractive: spawn-free *and* GVL-safe with no new
dependency, which nothing else on the table manages. But it trades a clean,
loud, quoting-proof, self-healing call path (`argv` + exit code + fresh
connection) for a hand-framed, textually-error-detected, hand-escaped stream
that must be killed and respawned to recover. That is a real downgrade in
exactly the properties CLAUDE.md's conventions single out.

Worth building only once something actually needs O(running-VMs) libvirt calls
per tick. Nothing does today.

## Where the nuggets land if this graduates

- the transport choice, with per-call `virsh` / in-process binding / helper
  process as the roads not taken → **DECISIONS.md**
- the quoting and framing contract, and "recovery is kill-and-respawn" → **yardoc**
  on whatever wraps the session
- "a persistent-session call must never run on the UI thread, and must be bounded
  by both `--timeout` and a parent-side read timeout" → **CLAUDE.md**
- the 31.16 ms / 57 % baseline is evidence and lives in the parent note; it dies
  with these files
