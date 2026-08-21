# frozen_string_literal: true

module Virt
  # The default `virsh` transport: one process per command.
  #
  #   runner = VirshSpawn.new
  #   runner.query('domstats')                  # => "Domain: 'vm1'\n  state.state=1\n…"
  #   runner.sync('setmem', vm_name, '262144')  # => "" — raises if virsh fails
  #   runner.async('start', vm_name)            # => Thread; failures logged, not raised
  #
  # One argument per word, never a pre-joined string: that is what keeps a VM named
  # `it's` from needing an escaping layer (see {Run}). The word `virsh` is never among
  # them. {VirshSession} serves the same three methods from a persistent REPL, which is
  # why {#query} is spelled separately from {#sync} even though they are identical here:
  # it marks the calls a session is allowed to serve, so switching transport moves the
  # read path and nothing else.
  #
  # Every command runs under `-q`, which is what makes the two transports return the same
  # bytes: without it `virsh` appends a blank line that an interactive session does not.
  class VirshSpawn
    # A read whose stdout the caller parses. Identical to {#sync} in this transport; see
    # {VirshSession#query} for the one where it differs.
    #
    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [String] the command's stdout
    # @raise [RuntimeError] if the command fails (via {Run.sync})
    def query(*args)
      sync(*args)
    end

    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [String] the command's stdout
    # @raise [RuntimeError] if the command fails (via {Run.sync})
    def sync(*args)
      Run.sync('virsh', '-q', *args)
    end

    # Runs a command without waiting for it, for the ones too slow to block on
    # (`virsh start` takes ~800ms).
    #
    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [Thread] the thread running the command (see {Run.async})
    def async(*args)
      Run.async('virsh', '-q', *args)
    end

    # Releases nothing — this transport holds no state. Present so a caller can close
    # whichever runner it holds without testing its type.
    #
    # @return [void]
    def close; end
  end
end
