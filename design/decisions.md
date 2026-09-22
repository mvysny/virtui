# Decisions

Why this project is the way it is and not otherwise — FAQ-shaped: each entry is a question and
its current answer. Rewrite the answer when it changes; delete the entry when nobody asks any
more. An entry is earned by what it would cost to reverse — half the code base — or by research
the next person would otherwise redo (cited as its `R_`). Not an entry: windows → panels
"because that's the trend", this red over that red, `get_foo` over `is_foo?`, the testing library,
the CI host, a version bump — a comment at the site of the choice, or nothing; nothing about
`design/` itself. Cite by slug, `D_<slug>`, never by position; `grep '^## D_' design/decisions.md`
is the index. The first entry is the ruler: every later one trims to its length.

---

## D_virsh_cli — Why shell out to `virsh` rather than use the ruby-libvirt binding?

VirTUI needs per-VM runtime data (state, CPU time, balloon stats, per-disk sizes) and issues
power and memory commands, and `Virt::Virsh` gets both by running `virsh` and parsing its text
output; with no `virsh` on the `PATH`, `bin/virtui` falls back to the `Virt::VMEmulator` demo
fleet. Why not the [ruby-libvirt](https://ruby.libvirt.org/) binding: a `Virt::LibVirtClient`
was written against it and deleted — it does not expose everything virtui displays, and closing
the gap is blocked by [bug #1](https://github.com/mvysny/virtui/issues/1). The harder objection
came later: the binding never releases the GVL (`R_ruby_libvirt_gvl`), so a slow or wedged
libvirtd freezes the whole TUI — no repaint, no keyboard — where a `virsh` child costs one late
update, because `Process.wait` releases it. The process spawn is not waste; it buys thread
isolation, and anything built on the binding would need a short timeout plus a per-VM circuit
breaker, or its own process, before it is safe near the event loop. The cost we carry: every
read is a text parse, so the parsers take a fixture parameter and the specs feed recorded
`virsh` output (`spec/virt/domstats*.txt`); every call costs a spawn, so slow or failure-prone
commands (`start`, `shutdown`, `set_mem_stats_period`) go through `Run.async`; and `virsh` is a
hard runtime prerequisite, documented in the README's *Setup*. The binding stays in the
README's *Future plans* — revisit when bug #1 moves, and start from the GVL problem.

## D_virsh_session — Why a persistent `virsh` REPL for the reads rather than a process per command?

`Virt::Cache#update` polls `virsh domstats` every 2 s, and each spawn re-execs a binary that
links 61 shared objects. Measured on the dev box against `test:///default` (libvirt's
in-process driver, so pure per-call overhead), 200 iterations each way: one process per command
costs 7.8 ms CPU and 1065 minor page faults per call; a persistent session 0.100 ms and 0.015 —
78× the CPU, all discarded milliseconds later, and through the real `Virt::Virsh` parser the
end-to-end read is 64× faster. At the 2 s tick that is 0.39 % of one core held for as long as
the TUI is open, against 8.3 MB PSS to keep a child resident. So the backend has a *runner*
seam — `query`/`sync`/`async`, the subcommand without the word `virsh` — with two
implementations: `Virt::VirshSession` serves `query` from one long-lived `virsh` child,
`Virt::VirshSpawn` runs every mutating command in its own process with its own exit status, and
the session degrades to spawning by itself when the child misbehaves. Replies are framed by an
asymmetric sentinel — a nonce split by a quote `virsh`'s tokenizer removes, so the bytes
searched for cannot appear in readline's echo of the request (`R_virsh_repl`).

Why not leave it alone: 0.39 % of a core is noise on the latency axis — 8 ms of a 2000 ms tick
— and that is the axis the first two verdicts were reached on; the axis that matters is host
load, on a box whose job is running VMs. Why not a peer class implementing the whole
`Virt::Virsh` role: it would duplicate ~150 lines of `domstats`/`nodeinfo` parsing, where a seam
*below* the parser leaves the parser specs and fixtures untouched. Why not one session per VM
with per-VM circuit breakers: that machinery is justified only by an O(running VMs) workload,
and the guest-agent reads that exist (`D_guest_swap_level`) are served fine by the one child —
serialised behind its mutex, bounded by a per-call `--timeout`, with `Virt::GuestSwapSampler`'s
write-off as the breaker. Revisit only if a wedged guest is measured delaying the fleet poll;
the price is ~2.8 MB PSS per extra child (quote PSS, not the ~6.5× larger summed RSS, which is
mostly shared pages). Why not frame replies on the `virsh # ` prompt: readline echoes the
request, so a payload containing the prompt terminates the read on its own echo — measured.
Why not decide a reply is complete when the pipe goes quiet: indistinguishable from latency,
and the failure is one VM's numbers reported as another's; `virsh` is strictly serial, so a
sentinel sent after the command cannot answer before it. Why not merge the child's stderr into
stdout: the parser must get stdout alone, exactly as `Run.sync` delivers it, and split streams
keep its raise-with-stderr contract.

The consequences we carry: without an exit status, stderr is classified by an `error:` prefix —
the weakest joint, and why unclassified stderr stays at `warn`. A host with no libvirtd leaves
`virsh` failing every command in a healthy REPL, so a *command* failure must never be read as a
broken child or it respawns forever. Both transports pass `-q`, or the spawn appends a blank
line the session does not. A wedged `qemu-ga` under `--timeout` and libvirtd restarting under a
live session are unverified on a real host; both land in the transport failure path, whose
floor is spawning. The `VIRTUI_VIRSH_SESSION=1` opt-in that gated the trial is gone — a
fallback that costs a one-line edit in `bin/virtui` is cheap to keep, an environment variable
that has to keep working is not.

## D_argv_not_shell — Why does `Run` take one argument per word rather than a command string?

`Run.sync(*argv)` / `Run.async(*argv)`: with more than one element Open3 execs directly, no
shell, and an argument holding quotes, spaces, `*` or `$HOME` arrives byte for byte; the runner
role (`query`/`sync`/`async`) splats the same way, so `Virt::Virsh` writes
`@runner.sync('setmem', domain_name, kib)`. A single string is still accepted, for literal
commands with nothing interpolated. The reason: `Run` once took one `String`, which Ruby hands
to `/bin/sh` whenever it holds a metacharacter, and three call sites interpolated
user-controlled text wrapped in single quotes — `virsh setmem '#{name}'`, the `virt-manager`
launch, the qcow2 paths into `df -P`. A single quote cannot contain a single quote, libvirt
allows one in a domain name, and a VM named `it's` died with
`sh: 1: Syntax error: Unterminated quoted string` in every command that names a VM, while the
`df` case silently mis-reported disk usage. Why not escape correctly with `Shellwords.escape`,
the first sketch: it keeps a shell in the path for no benefit, every future call site must
remember to escape, and forgetting is silent until someone names a VM oddly; argv removes the
category. Why not one escaping helper shared by both transports: `Virt::VirshSpawn` needs no
escaping at all, while `Virt::VirshSession` must quote for `virsh`'s *own* tokenizer, which is
not the shell's — near-identical grammars, which is exactly what would make a shared helper
look right until it wasn't. Structured arguments let each transport do its own thing from one
call site that knows about neither; `Virt::VirshSession.quote` is now the only quoting code in
the project. The costs: `Run`'s messages join the argv with spaces, so a name containing a
space is ambiguous in the *message*; and a splat cannot carry a yardoc `@param` when forwarded
anonymously, hence the `Style/ArgumentsForwarding` exclusion in `.rubocop.yml`.

## D_virsh_own_pgroup — Why does the `virsh` session child run in its own process group?

`Virt::VirshSession#start` passes `pgroup: true` to `popen3`, so no terminal-generated signal
— `SIGWINCH` on a resize, `SIGINT` on `^C`, `SIGTSTP` on `^Z` — reaches the child. Spawned
into virtui's own group it received every one of them, because the kernel signals the whole
foreground group, and GNU readline reacts to them even on pipes (`R_virsh_repl`): on the dev
box a resize put 521 bytes into the child's stdout — `"\r"`, 513 spaces, `"\r"`, a fresh
prompt — which sat unread in the pipe and arrived as the prefix of the *next* reply, where the
echo assertion caught it as `expected an echo of "'domstats'"; respawning`. Recovery worked,
but the lost read is a whole fleet poll, and the log accused the wrong thing. The quieter
damage is why the bytes are not simply tolerated: after `SIGWINCH` readline re-derives its
width from the terminal and never consults `COLUMNS` again, so
`Virt::VirshSession::CHILD_ENV`'s line-length guard silently expires and any command line past
~512 bytes is echoed in horizontal-scroll mode, desynchronising every read until a respawn — a
landmine today, since the longest line (the guest-agent JSON) is ~130 bytes. Losing the
signals costs nothing: the child has no terminal, and it is shut down by `#close` or by its
stdin closing when virtui dies, measured to leave no orphan. Why not drain the stdout pipe
before each command: the only *other* thing that leaves bytes there is a frame abandoned
mid-read, which is what `Desync` exists to shout about; a quiet discard blunts the guard
against one VM's numbers being reported as another's and leaves the width collapse in place.
Why not accept a leading `\r`-and-spaces prefix in the echo assertion: it hard-codes one
readline version's redisplay into our framing. Why not `sh -c 'trap "" WINCH; exec virsh …'`:
it fixes the one signal we saw and puts a `/bin/sh` in the one transport that must not
re-learn quoting (`D_argv_not_shell`). Why not swap `TERM=dumb` for a terminfo with a real
`ce`: a shorter repaint, and ANSI escapes in the bytes the parser reads. The consequence: the
`COLUMNS` cap and `pgroup: true` are one mechanism — anything that puts the child back in
virtui's group re-arms both failures, the second silently. `^C` no longer reaches the child;
nothing depended on it, since tuile holds the terminal raw, but a non-TUI entry point expecting
`^C` to clean up must kill the child itself. `Virt::VirshSpawn` needs none of this: its
children start no readline.

## D_mem_stats_self_armed — Why does virtui arm guest mem-stat collection itself rather than have the user configure it?

libvirt's collection period defaults to off, and until something sets it the guest-reported
balloon fields freeze at their boot-time values while the host-sourced fields keep moving
(`R_libvirt_balloon_stats`) — a VM looks alive, its RAM looks stuck, and the controller resizes
a busy VM on numbers taken seconds after boot. So `Virt::Cache#update` arms the period
(`Virt::Cache::STATS_PERIOD_SECONDS`) through `Virt::Virsh#set_mem_stats_period` on every
not-running → running transition, fire-and-forget through `Run.async`. Why not have the user
add `<stats period='3'/>` to the `<memballoon>` device: it works, and the README still offers
it as the way to make the period survive a power-off, but as the *only* mechanism it silently
degrades every VM nobody remembered to edit, and "no balloon device" and "period never set"
then present identically as frozen numbers. Why not arm it synchronously: a VM without a
balloon device makes `virsh dommemstat --period` fail, and raising there would abort the whole
2 s refresh for every other VM — don't "clean this up" into a `Run.sync`. Why on the
transition and not once at startup: the period is a live property of the running QEMU process,
surviving a guest reboot but not a power-off. A VM that still reports frozen data — no balloon
device, no guest tools — is caught downstream by the staleness check (`D_wall_clock_mem_age`).

## D_wall_clock_mem_age — Why is balloon-data age measured against the sample clock rather than between polls?

`Virt::Cache::VMCache#mem_data_age_seconds` is true wall-clock age — the snapshot's own
`sampled_at` minus the guest's `balloon.last-update` — and `VMCache#stale?` trips at 12 s,
which is what draws the 🐢 and makes `Virt::BallooningVM` refuse to resize on frozen numbers.
Why not diff `last_updated` between two consecutive polls: the obvious formulation, the
original implementation, and it cannot work — the delta is 0 both when the data is perfectly
fresh *and* when it is frozen, so it never fired once. Don't re-derive it. Why not a tighter
threshold than 12 s: libvirt refreshes balloon data only every ~5 s regardless of the period
asked for (`R_libvirt_balloon_stats`), and we poll every ~2 s on top, so healthy data is
routinely 5–7 s old and anything much under 10 s turns the turtle into a flicker. The 12 s is
tied to that ~5 s floor: if the poll interval or the collection period changes, re-derive it
rather than nudge it. The check is a backstop, not a diagnosis — it says the guest stopped
reporting, not why; the README's ballooning prerequisites are the why.

## D_guest_swap_level — Why read the guest's swap level through the QEMU guest agent rather than derive it from the balloon counters?

`domstats` gives `balloon.swap_in`/`swap_out`, since-boot I/O counters that never fall when
swap slots are freed, so no sampling rate can turn them into a level — measured in
`design/ideas/swap-despite-ballooning.md`, where a guest drained 1.14 GiB of swap with
`pswpout` flat. The level is the number an operator wants ("how much is this guest still
paying?") and the one the controller needs, because swapping erases its own evidence: evicting
N bytes raises `MemAvailable` by ~N. Only the guest knows it, and `qemu-guest-agent` — a
virt-manager default, already in the managed VMs — is a channel to it that needs nothing
installed. So `Virt::GuestAgent` reads the guest's `/proc/meminfo` with the
`guest-file-open`/`read`/`close` trio (`R_qemu_guest_agent`) and parses it through
`System::MemoryStat.parse`, the same parser the host's copy goes through; every failure raises,
and `Virt::GuestSwapSampler` above it answers `nil` and writes off a guest that keeps failing
(`D_guest_agent_backoff`, `D_swap_sampler_split`), because no agent, or an agent with the RPC
blocked, is a normal state that must never break the poll. The read is paired with
`Virt::VirshSession` and not offered on `Virt::VirshSpawn`: three agent calls per VM per tick is
where the ~18 ms spawn stops being noise (~120 ms per VM per tick against a 2 s tick), while
the session leaves only the ~13 ms libvirtd + QMP + virtio-serial round-trip. Sampling sits on
the timer thread in `Virt::Cache#update`, not inside `Virsh#domain_data`: `domstats` is one call
for the fleet, this is O(running VMs) calls that fail per VM.

Why not `guest-exec` + `guest-exec-status`: two calls instead of three and one `sh -c` could cat
several files, but it is remote root exec made a hard dependency of monitoring, it spawns a
guest process every tick, and it is asynchronous — the first reply carries only a PID, the
output needs a second round-trip after the process exits. Reconsider only if PSI, `vmstat` and
meminfo are all wanted per tick. Why not reconstruct the level from the counters (the
`swap_debt` estimate in the idea note): a known bias — slots freed with no fault-in inflate it,
forcing a decay half-life nobody has a number for — where this reads the real figure; it stays
the fallback for guests with no agent. Why not ship a virtui agent into the guest: the whole
appeal is a channel that already exists, unmaintained by us — the promise **Nothing is
installed in the guest**. Why not `Libvirt::Domain#qemu_agent_command` via ruby-libvirt: it
never releases the GVL, so one wedged `qemu-ga` freezes the entire TUI (`D_virsh_cli`). What
follows: two figures now describe guest swap — the *rate* from the counters, every guest, and
the *level*, agent-capable guests only — and whatever shows them must survive the level being
absent; `qemu-guest-agent` is an optional prerequisite the README documents; and the channel
is deliberately read-only — widening it to `guest-exec` for a swap drain was decided against
separately (`D_no_force_drain`).

## D_guest_os_from_xml — Why does the guest OS come from the domain's libosinfo declaration rather than from the running guest?

The `/proc/meminfo` read is Linux-only, and virtui had no idea which guests were Linux: a
Windows guest's `guest-file-open` fails with a phrase none of
`Virt::GuestAgent::EXPECTED_FAILURES` matches, so it produced a `warn` per boot for a guest that
is merely not Linux and spent three doomed RPCs a tick until the write-off bounded it —
forever. So `Virt::GuestOS` reads what the domain *declares*:
`virsh metadata --uri http://libosinfo.org/xmlns/libvirt/domain/1.0 <dom>` returns the
`<libosinfo><os id="http://ubuntu.com/ubuntu/25.10"/></libosinfo>` element that virt-manager
and `virt-install --os-variant` write (`R_osinfo_db`), the id is classified by vendor host plus
first path segment into a family, `GuestOS#no_proc_meminfo?` is the plain `!linux?`, and
`Virt::Cache` memoizes one lookup per domain. `Virt::GuestOS::FAMILIES` is a one-time extraction
of osinfo-db — every `<os id>` reduced to its `vendor-host/short-id` and tagged with its own
`<family>`, 980 entries collapsing to 76 keys and 12 families — because the part virtui reads
barely moves: osinfo-db gains OS *versions* constantly and *vendors* rarely, and a new vendor
is one row plus a `debug` line naming the unmatched id.

Why not `guest-get-osinfo` through the agent — the live, truthful source and the first design:
it needs the agent up, and the agentless Windows guest is the *common* Windows guest
(`virtio-win` is a manual install), so the guest that caused the problem is the one an
agent-based detector can never classify; beside that it is blind for the 20–40 s of boot and
for a shut-off VM, needs its own `--timeout`, and drags in the whole strike-count machinery.
Don't re-add it as a second source either, which this entry first proposed: `GuestOS` feeds
two consumers, `Cache#update`'s gate on the swap read and the VM pane's per-row glyph, and the
gate needs no classification at all because **the read is its own test** — `guest-file-open
/proc/meminfo` succeeding or failing observes exactly the capability the gate tries to predict,
and it already happens. That leaves a flag emoji paying for a second classifier vocabulary (the
reply carries the guest's `/etc/os-release` `id`, not an osinfo-db URL, so `VENDORS` cannot
consume it), its own failure bookkeeping (a pre-2.10 `qemu-ga` refuses `guest-get-osinfo` while
`guest-file-*` works, so sharing `D_guest_agent_backoff`'s strike count would cost such a guest
the very swap level detection exists to protect), and a per-domain observation sticky enough to
survive a shutdown and a reinstall. Probing `/proc/meminfo` once and feeding the result to the
glyph is free of the first bill and pays the other two, for the same cosmetic gain. Why not
`virsh guestinfo --os`: no `--timeout` flag, which is the one thing keeping a wedged agent from
becoming a session read timeout that kills the child. Why not `dumpxml` plus a parser:
`metadata --uri` returns the element alone — one regex over three lines, no XML dependency. Why
not vendor osinfo-db or shell out to `osinfo-query`: virtui needs a family, not a version tree,
and not a build-time dependency shipped separately from libvirt. Why not hand-write the table
from the naming scheme: the first cut did, ~15 rows, and three were wrong in ways nothing on
the author's host could reveal — `alpinelinux.org/alpine` (the short-id is `alpinelinux`, so
every Alpine guest silently lost its swap level), plus two vendors osinfo-db has never had. Why
not key on the vendor host alone: `microsoft.com` ships `win/*` and `msdos/*`. Why not gate on
`windows? || freebsd?` and let `:unknown` fall through to the read: a gate that grows with every
family; `!linux?` let nine families arrive without touching the gate, the cache or the agent.
Why not memoize on `Virt::Virsh`, next to the lookup: `Virsh` is reachable from the UI thread,
so a memo there is state two threads share and an invitation for a future OS column to take
the session mutex on the render path — the memo lives on `Virt::Cache`, the timer thread's own.

What it costs: a domain that declares no OS reports no swap level — invisible on a
virt-manager fleet, every VM on a hand-rolled one, hence the README line saying the level needs
the declaration and not just the agent; the declaration records what the *creator* said and can
be stale; and the memo never expires, so editing a definition while virtui runs takes a restart
to notice. `EXPECTED_FAILURES` gained `no such file or directory` for a non-Linux guest that
declared nothing; the exact libvirt phrasing is unverified, and a miss costs one `warn` per
boot of such a guest.

## D_guest_agent_backoff — Why is a mute guest written off for 60 s and logged only on a failure we did not foresee?

The write-off first shipped as three strikes then 300 s, announced at `info` — both numbers
picked against the guest that will *never* answer, and both wrong for the guest that cannot
answer *yet*: at a 2 s poll three strikes are spent 6 s after libvirt calls a domain running,
and no guest has `qemu-ga` connected 6 s after `virsh start`, so every VM start wrote its own
healthy guest off for five minutes and said so; shutdown produced the same line from the other
side. So `Virt::GuestSwapSampler` writes off for a flat 60 s (`BACKOFF_SECONDS`) — a booting
guest is retried a minute later, by which point its agent is up, and the guest that never
answers costs a probe a minute, accepted rather than optimized because a well-maintained fleet
has the agent installed. The failures a healthy host produces on its own —
`Virt::GuestAgent::EXPECTED_FAILURES`, matched once against the error text and published as
`GuestAgent::Unavailable` (`D_swap_sampler_split`) — log at `debug`, since a missing swap level
is an enhancement declining; anything else logs `warn` once, at the write-off, so a broken
guest costs one line per episode. The strike count survives a lapse — only a success clears it
— so a still-mute guest re-arms on the one probe rather than spending a fresh three, or the
attempt rate against a *wedged* agent, the case that costs a full `TIMEOUT_SECONDS` of the
timer thread, would rise 4.5× over what `D_virsh_session` assumed. `Virt::Cache#update` calls
`#forget` for every VM it sees not running, so strikes burned during a shutdown do not greet
the next boot.

Why not an escalating backoff, 60 s doubling to 300 s: it serves both guests exactly and is
tuning for the special case — the cost it saves is one refused RPC per minute per agentless
VM, not worth a second constant and a doubling rule to reason about at every read. Why not a
grace window of 1–2 minutes after a VM starts, the first proposal: it needs a boot clock virtui
does not have — libvirt's state stays `running` across a guest-induced reboot, so the window
never re-arms for the case that most needs it — and it keeps polling a wedged agent for the
whole window, 2 s of timer thread per tick, which is precisely what the write-off bounds. Its
state-transition half survives as `#forget`. Why not key the write-off itself on the error text
(`is not connected` = transient): it hangs virtui's *behaviour* on libvirt's error strings,
which are not an API — a rephrasing upstream silently changes how long a guest is skipped and
no test goes red; keying only the *log level* on them is a different bet, where a miss costs
one line in the log. Don't promote the match from the level to the backoff. Why not warn on
every unexpected failure: for a persistent fault that is the same line every 60 s forever; the
cost of once-per-episode is that an *intermittent* unexpected error never landing three strikes
stays at `debug`, accepted since anything misconfigured is persistent and surfaces within 6 s.
Why not one strike: a single hiccup then blanks a healthy guest's gauge for a minute. What
remains: nothing in the UI says a guest is written off, and at the default `:info` level
nothing in the log does either; `EXPECTED_FAILURES` is a list of another project's phrasings
and rots by definition, benignly — a renamed phrase shows up as a `warn` on a healthy host; and
a guest-induced reboot is still not detected, healing within the 60 s instead, which is what
makes the short backoff load-bearing and `forget` mere hygiene.

## D_swap_sampler_split — Why is the guest-agent client split from the sampler that owns the write-off?

`Virt::GuestAgent` keeps the `qemu-agent-command` protocol, the file channel and the
`/proc/meminfo` read, holds no state, and *raises* — `GuestAgent::Unavailable` for the failures
a healthy host produces (`EXPECTED_FAILURES`), anything else for a reply the agent does not
document — so `#swap` always returns a `ResourceUsage`, and a guest with no swap device reports
a `total` of 0 because that is what its meminfo says. `Virt::GuestSwapSampler` holds the strike
counts and the write-off, swallows every failure into `nil`, and picks the log level off the
*class* of the error, never re-matching libvirt's phrasings. The seam is deliberately not a
decorator: the sampler does not preserve the agent's interface and does not re-expose
`#read_file`, so a caller wanting a one-shot raw read reaches the agent and is visibly opting
out of the write-off.

Why not one class — the status quo, tempting with exactly one client: it had four jobs, the
policy was ~90 of its 256 lines and the only reason it held state, and three costs were present
with one client. `#swap`'s `nil` meant four unrelated things (no swap device, no agent, a
blocked RPC, currently written off), so no caller could tell "has no swap" from "we did not
ask"; `#read_file`, public and advertised as the raw channel, sat outside the write-off it
looked protected by, so a second sampled read would have hammered a wedged guest twice a tick;
and the two halves want opposite fixtures — scripted JSON and base64 with no clock versus
`Uptime.travel` and an agent that merely raises. Why not move the policy into `Virt::Cache`,
the strongest alternative: `Cache#update` *is* the poller, already applies the other two gates
and already memoizes a backend read, and it would delete the `forget_guest` forwarders — but it
pays with a third per-domain hash and a `debug`/`warn` branch inside the densest method in the
project, the one swallow in the tree landing in the class that is otherwise strictly loud, the
tight write-off specs moving behind a fake backend, and `Virsh#guest_swap` re-acquiring the
two-meanings-for-`nil` problem one level up. Why not a generic per-key circuit breaker beside
`Cooldown`: one client today, and to be generic it needs a logging callback and an
is-this-expected predicate injected — knobs ahead of the second concrete step; revisit if a
second polled guest read appears, until then duplicating ~40 lines is the cheaper mistake. What
it costs: `GuestSwapSampler` names one read and needs renaming or a sibling if a second arrives;
`#read_file` is now explicitly unpoliced — fine for a one-shot read, wrong for a polled one,
which belongs behind a sampler.

## D_no_force_drain — Why does virtui never drain a guest's swap?

Once the level was readable (`D_guest_swap_level`) the question came due: should virtui drain
a guest's swap after a burst, to erase the scar? No — parked swap is accepted as damage
already done, `Virt::GuestAgent` stays a read-only channel and `guest-exec` stays out of the
project. The kernel mechanics decide it (`R_linux_swap`): pages in swap are the cold tail of
the anon LRU, out there because nobody has touched them since eviction, so demand paging *is* a
drain, and an optimally ordered one — pages return when they matter, batched by readahead —
where a forced drain re-implements it sorted by slot order instead of usefulness. Observed
2026-08-20: a guest drained 1.14 GiB on its own as the balloon grew, ~515 MiB faulted back on
demand and the rest freed by writes and exits. The honesty problem parked swap leaves — a guest
holding swap looks comfortable to the controller — is fixed by making the controller *see* the
level, never by moving pages.

Why not `swapoff -a && swapon -a`, the only drain needing no code in the guest:
`try_to_unuse()` faults every page back synchronously — minutes of scattered 4K reads — while
the guest has *no swap at all* and the drain consumes `MemAvailable` at top speed, so a spike in
that window goes to the OOM killer, and if only-in-swap exceeds `MemAvailable` at the start
`swapoff` itself OOMs the guest: a performance blemish converted into an availability incident.
It also needs `guest-exec` as root in every VM, a remote-root *write* where everything shipped
reads a file. Why not a rate-limited `process_madvise(MADV_WILLNEED)` sweep over the swapped
ranges in `/proc/*/smaps`: no CLI exists, so it means a binary deployed into the guest —
against the promise **Nothing is installed in the guest** — and below the ~50 %-full
slot-retention threshold it does not even lower the visible level, since a read fault keeps the
slot. Why not any forced drain on the merits: it converts free RAM into resident cold anon,
spending the burst headroom on pages nobody will touch, which are the first thing re-evicted on
the next pressure event, and it raises `MemTotal − MemAvailable`, so `MemLevelRaiseVoter` grows
the VM and the host pins RAM under untouched pages — virtui inducing the signal it acts on. The
steelman, paying the latency debt off-peak with an idle-time prefault: the warm pages that
cause the jank fault back within minutes of resumed use anyway, and the long tail a prefault
drags in is the part that was never coming back. Don't re-add as a loop behaviour; if the itch
returns the shape is an operator keypress on a confirmed-idle guest with confirmed headroom,
and even that is weak — zram in the guest dissolves the question, a zram fault-back being a
decompression. An *operator* running `swapoff`/`swapon` by hand is unaffected; this rejects
virtui doing it.

## D_ballooning_voters — Why does `Virt::BallooningVM` run a list of voters and vetoers rather than a chain of `if`s?

Every consideration is a small object under `lib/virt/ballooning_vm/`, fed each tick's
`Cache::VMCache` through `observe` and asked one question it answers with a `String` reason or
`nil`: a **voter** (`vote_reason`) asks for a change, a **vetoer** (`veto_reason`) blocks one.
`BallooningVM` holds three lists — raise voters, lower voters, lower vetoers — and applies three
rules: any raise vote wins outright; otherwise a lower needs a voter for it and no vetoer
against it; otherwise nothing happens. The line that makes it work: an input decides *whether*
and says *why*; the framework decides *how much*. So each threshold lives on the input that
reads it, both rates live on the framework, and the reasons compose straight into the status
line — the call that makes the decision produces the sentence explaining it,
`VM reports 1.2G (65%), raising memory by 30% to 2.6G: usage is at or over the 65% trigger, the
guest is swapping out 20M/s`. The controller began as two thresholds and a back-off timer —
three `if`s, four ivars, a size at which a branch chain is right — but `D_swap_shrink_veto`
and `D_swap_raise_vote` each arrived as another clause spliced into `update` plus more ivars in
a constructor where nothing said which served which rule, and the queue in
`design/ideas/swap-despite-ballooning.md` is more of the same.

Why not extract only the swap inputs and leave the two thresholds inline as the primary rule:
not true — `SwapOutRaiseVoter` fires on evidence `MemLevelRaiseVoter` is structurally blind to,
so they are peers, and leaving one peer as an `if` keeps `update` shaped around it. Why not
leave `BackOffShrinkVetoer` inline, since it observes the controller's own actions rather than
the guest: it answers the same question the swap vetoer answers, and hoisting it is what puts
*all* lowering suppression in one place. Why not weighted votes or a vote carrying a size:
nothing wants a different-sized answer to a different input (a gentler swap hop was argued down
in `D_swap_raise_vote`), and a size per vote puts a tuning number on every input class — the
field soup this exists to undo. Why not raise vetoes for symmetry: rule 1 says nothing stands
between a VM that needs RAM and the RAM, and a list "for completeness" invites a use. The cost:
the deadband is split across two classes with nothing enforcing it — `MemLevelRaiseVoter`'s
trigger must stay above `MemLevelShrinkVoter`'s or both vote on one sample and the VM hunts
(the root invariant). Adding an input is write the class, add it to a list; every input has a
`forget` the framework calls on stop and on the user disabling ballooning, so one that holds
state gets its lifecycle free and one that omits `forget` fails loudly.

## D_swap_shrink_veto — Why does a swapping guest veto a shrink on the swap-out rate rather than the swap level?

`BallooningVM` steers by `(MemTotal − MemAvailable) / MemTotal`, and evicting anon pages to swap
*raises* `MemAvailable`, so the one input falls exactly when the guest is suffering — swap is
an unmodelled second actuator competing with the balloon for the same variable. Both failures
were measured (`design/ideas/swap-despite-ballooning.md`): a guest at 61 % used, mid-deadband,
controller idle, with 2 GiB parked in swap; and, watched live on 2026-08-26 while IntelliJ
started, the figure *pinned* at 55 % — allocation and eviction cancelling — while swap climbed
~2.5 GiB. 55 % is the shrink trigger exactly: one point more eviction and virtui would have
shrunk the VM mid-burst. So `SwapOutShrinkVetoer` vetoes the decrease outright while the guest
is seen writing to swap: `VMCache#swap_out_rate` at or above a 1 MiB/s noise floor on any
*guest sample* (libvirt refreshes every ~5 s, we poll every ~2 s, so one sample arms it once),
held for 60 s from that sample. The increase branch is untouched. The choice of *rate* is what
makes the veto finite: swap-used is a high-water scar, not a pressure gauge.

Why not veto while the *level* is non-zero — the obvious reading, and implementable since
`D_guest_swap_level`: slots are freed by write faults and process exit with no `swap_in`, and a
page swapped out at boot can sit for hours, so gating on the level means a VM that swapped once
is never shrunk again — a permanent ratchet dressed as a safety check. Don't re-add it just
because `VMCache#guest_swap` is right there; it answers "what did this guest already pay?", not
"is it paying now?". Why not veto only while the rate is non-zero *this* sample: the idea note
caught a shrink firing with 853 MiB in swap and `pswpout` flat — a guest that just swapped and
went quiet is the one that *least* wants shrinking, its usage figure deflated by exactly the
pages it is about to want; the cooldown is the level-free proxy for "when is it safe again".
Why not count `swap_in` as activity: inverted — `swap_in` is the guest healing. Why not reuse
the existing back-off timer: mechanically identical, but `back_off` means "we just moved this
VM, let it settle" and the veto means "the guest says it is short", and the status line has to
say which. Why not tune the shrink trigger down: the guest was pinned *at* 55 % with swap
climbing, so any threshold has a figure that satisfies it while the guest swaps — and prior art
says the knob is already over-tight, MoM, Hyper-V and VPA reserving 15–20 % where the 65 %
trigger reserves 35 % (`R_balloon_policy_survey`). What it costs: a VM that swaps once an hour
holds its memory a minute longer each time. The noise floor is uncritical on these guests
(`vm.swappiness=1`, disk swap, no zram — the rate is exactly 0 at rest); a guest with zram,
MGLRU or a systemd `MemoryHigh=` slice may trickle benignly and need it raised, and a floor
high enough to filter the trickle would blind a *grow* trigger, which is why the grow half owns
its own constant. This fixed the inversion, not the invisibility — the 61 % guest had no shrink
in flight — and `D_swap_raise_vote` is the other half.

## D_swap_raise_vote — Why grow a swapping guest on the spot, by the full 30 %, rather than wait for the usage figure?

`SwapOutRaiseVoter` votes to raise whenever the guest's swap-out rate is at or above its
1 MiB/s noise floor, and `BallooningVM` treats the vote exactly like the usage trigger firing:
+30 % of current `actual`, no back-off, one hop per guest sample. A guest writing pages to disk
is the plainest possible statement that it needs memory, so it gets the answer a guest at 65 %
gets. `D_swap_shrink_veto` closed half of the problem — it stops the controller *taking* memory
from a swapping guest — but the state actually measured, 61 % used with 2 GiB parked, had no
shrink in flight, and nothing was ever going to grow that VM: `percent_used` is the only thing
that could ask and swapping is what stops it asking. Watched live it did not even fall — it sat
pinned at 55 % while swap climbed 2.5 GiB.

It is a separate class from `SwapOutShrinkVetoer` though both read the same counter, because
the questions differ in *time*: the veto asks "has this guest swapped recently" and holds 60 s;
the vote asks "is it swapping now" and goes quiet the moment the guest does — a vote that
lingered like the veto would take a hop per sample for a minute after the burst, ×3.7 from
8 GiB in answer to something already over. Why not one class answering both: the floor would
then have one home, and the two answers could never disagree about whether the guest is
swapping — but they *should*: on a guest with zram, MGLRU or a `MemoryHigh=` slice a floor high
enough to ignore the benign trickle is high enough to blind the vote to a real burst, so the
two constants have different jobs. Why not wait for the usage figure to catch up: the
measurement is the refutation — 2.5 GiB went to disk while the figure never moved off 55 %,
and a *pinned* reading reaches no trigger however low. Why not a gentler hop (+10 %) because
the signal is indirect: backwards — the swap vote fires strictly *later* than the usage trigger
would have, since the guest is already paying disk I/O by the time the counter moves; later
evidence deserves at least as strong a response.

This is knowingly the naive form, unbounded on one axis: the vote reasserts every sample for as
long as reclaim hits the swap device, so a burst that takes several samples to absorb takes
several hops — 8 → 10.4 → 13.5 → 17.6 → 22.8 GiB in ~20 s against a 3 GiB allocation. Two
things bound it and neither is a design: `max_memory` is a hard ceiling, and the veto lapses
60 s after the swapping stops, after which the −10 % shrink unwinds the overshoot at ~100 s per
8 GiB. The pathological guest — cgroup-limited reclaim inside the guest, or MGLRU aging cold
anon forever — is raised every sample and parks at `max_memory`; this fleet is not that (the
rate is exactly 0 at rest on every VM), and the README tells such a guest's owner to turn
ballooning off with `mb`. What closes it properly is on the output side, per
`design/ideas/swap-despite-ballooning.md`: a bound on how far the swap signal alone may raise a
VM, plus a check that the raise helped.

## D_cooldown_monotonic — Why does `Cooldown` count uptime, with a writable clock, rather than `Time.now` under Timecop?

`Cooldown` holds the controller's suppression deadlines — `BallooningVM`'s back-off,
`SwapOutShrinkVetoer`'s 60 s veto, `GuestSwapSampler`'s write-off, `VirshSession`'s read
deadline — and what those mean is a *duration*: ten seconds is ten elapsed seconds, nothing
about a calendar. On `Time.now` they would not deliver that: NTP correcting an offset or a
manual `date` moves every live deadline. So `Cooldown` measures on `CLOCK_MONOTONIC`, read
through `Cooldown.clock` — a writable class-level callable defaulting to the real thing, which
production never assigns and specs travel through `Uptime.travel` (`spec/spec_helper.rb`), an
offset clock restored in an `ensure`. The complication that forced the seam: the project's
time-travel tool is Timecop, which patches `Time.now` and moves `CLOCK_MONOTONIC` by exactly
zero (`R_timecop_monotonic`) — the correct clock is the one no spec could move, and the
deadlines needing tests are 10–60 s inside callers whose specs travel 20–80 s. An explicit,
documented seam rather than a spec redefining a method makes the writability part of the
contract, where the yardoc names its one legitimate caller; anything in `lib/` assigning
`Cooldown.clock` is a bug.

Why not the wall clock, accepting what a step does — briefly taken: it redefines "ten seconds"
to "until this wall-clock instant", and a bounded wrong answer (one premature shrink, one veto
lapsing early, re-decided next poll) is still wrong, bought only by not writing
`Uptime.travel`. Its one real argument will come up again: for **suspend/resume**, the jump a
desktop KVM host actually sees, `CLOCK_MONOTONIC` excludes suspended time, so a 60 s veto armed
before an 8-hour sleep still has 60 s to run on wake. `CLOCK_BOOTTIME` fixes that case without
the NTP exposure; not worth diverging from the sampler today, at most one stale decision on
resume. Why not real `sleep`s in specs: fine for `Cooldown`'s own sub-second boundaries,
impossible for callers travelling 20–80 s. Why not make every duration a constructor parameter
so specs pass 0 (the old `backoff_seconds: 0` idiom): five new parameters across two classes,
and it stops the shipped 10/20/60 s from being exercised — "does it lapse at 60 s" is precisely
the assertion lost; injecting the *clock* tests the shipped constants. Why not store both a
wall and an uptime deadline: the uptime half never moves under Timecop, so specs would exercise
a path production never takes. What follows: `Uptime.travel` swaps a process-global and must
not run while another thread holds a live `Cooldown` — the session's read deadline is the one
cross-thread consumer, and its specs inject a short `read_timeout` instead. `Uptime.travel`
and `Timecop.freeze` now both exist and mean different things — a cooldown versus an
`Interpolator` ramp, which follows the wall clock by design because animation follows the clock
a human watches; `spec/virt/ballooning_vm_spec.rb` uses both a few lines apart and says so.

## D_panes_are_layouts — Why are the borderless panes `Layout::Vertical`s rather than frameless `Window`s?

Each of `UI::VMPane`, `UI::SystemPane` and `UI::LogPane` is a
`Tuile::Component::Layout::Vertical`: a one-row header (`Fixed[1]` — the focus chip, plus the
VM pane's column captions) over the content widget (`Expand[1]`), with the VM pane's search
field appearing as a third row while open; the log pane composes tuile's `LogTextView`
directly. The redesign that removed the window frames needed a home for what the `Window`
chrome carried — caption, footer, scrollbar, focus repair — and the first draft asked tuile for
a `Window#frame = false` mode. Why not that frameless `Window` upstream: once the border goes,
`Window` earns nothing — bending a class whose job is painting the border into not painting it
keeps the class for its name — and against tuile 0.13 everything the frame seemed to carry was
already elsewhere: `List`/`TextView` own their scrollbars, `Screen#focused=` sets `active` on
every ancestor so a `Layout` pane reads focus-within for free, and `List` paints its whole rect
so click-to-focus lands. Why not the search field as a popup or overlay, the design's first pick
for the screen's own focus repair: a `Popup` is modal — anchoring one under the pane is only an
`Overlay::At` placement now, but the list behind it stops taking keys — while tuile explicitly
forbids the lighter shape, a focusable non-modal `Overlay` — every keystroke goes dead until
Tab recovers. The embedded row costs one explicit `list.focus` in `VMPane#close_search`,
strictly simpler. Don't re-try the overlay without re-reading `overlay.rb`'s implementation
notes. What it costs: a `Layout` pane repairs nothing on child removal, so `close_search` must
re-focus the list itself; and while the search field is focused, digits are consumed by the
field before `AppLayout#handle_key?` sees them.

## D_tint_toward_grey — Why does the pane tint step the terminal background toward mid-grey rather than toward the theme's pole?

`UI::Tint` steps the background's HSL lightness toward mid-grey by `Tint::DELTA` (0.04), hue and
saturation held — hue preservation is the point of deriving at all, since Catppuccin Mocha
`#1e1e2e` is purple-blue and a neutral-grey sidebar next to a tinted pane looks dirty. A
contrast guard flips the step away from grey if it would drag a guarded token that clears
4.5:1 against the raw background under that floor; bar colors tuned as non-text (WCAG's line
there is 3:1) are not guarded. The hairlines derive the same way at `HAIRLINE_DELTA` (0.2)
from their actual grounds. The first decision went the other way — toward the pole, dark →
darker, light → lighter — argued from contrast, since the tokens were tuned against near-black
and near-white grounds; measurement reversed it the same day. WCAG ratios of the System-pane
tokens over six backgrounds (`#000`, Mocha, One Dark `#282c34`, `#fff`, Latte `#eff1f5`,
Solarized Light `#fdf6e3`; the table lives on as `spec/ui/tint_spec.rb`'s guard-table specs):
the default foreground never binds, 14–21:1 either way; the binding token is the LIGHT theme's
`:cpu` (DodgerBlue3, 5.8:1 on white, no headroom), which on Latte breaks at Δ=0.10, sits on the
4.5 line at 0.05 and clears at 0.03–0.04; dark caps in the same region. Both directions'
budgets are ~0.05, so toward-grey's contrast cost at 0.04 is real and never binding.

Why not the pole-directed step, then: mechanically it improves contrast and is irrelevant at
Δ≈0.04 — and its *exception* (can't darken past `#000`, can't lighten past `#fff`) fires at the
two most common terminal backgrounds, where the rule degenerates into a step-the-other-way
special case, whereas toward-grey's exception (a background already mid-grey) fires on no real
terminal. A rule whose primary branch is dead on the most common input is the wrong primary
branch. Why not a fixed `frame` hex: `#333333` is 1.11:1 on One Dark untinted — near-invisible
— and the tint walks it through 1.00:1 at Δ=0.03, exactly where the System/log separator is
load-bearing; a hairline must derive from the ground it rules on. Why not a per-token runtime
contrast search: over-machinery — the guard as shipped is one flip, expected dead on every real
background, and the spec table owns the assurance. Still open: the exact Δ and the fixed floors
(`Theme`'s `pane_bg` pair, used when OSC 11 goes unanswered) await an eyeball pass on real
terminals; HSL ΔL is not perceptually uniform, and OKLab is the upgrade if the dark step ever
reads weaker than the light one. Symbolic ANSI tokens can never be guarded — only the terminal
knows their RGB.
