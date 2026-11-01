# frozen_string_literal: true

# sig/virtui.rbs is written by sord from the YARD tags, never by hand; State's types come from
# there (Typemap::Mapper::RBSTypes). CI fails on a stale file: `git diff --exit-code sig/`.

namespace :sig do
  desc 'Regenerate sig/virtui.rbs from the YARD tags via sord; fails on any sord warning'
  task :generate do
    require 'English'
    rm_rf '.yardoc'
    mkdir_p 'sig'
    out = `bundle exec sord gen sig/virtui.rbs --rbs --regenerate --no-sord-comments 2>&1`.gsub(/\e\[[0-9;]*m/, '')
    print out
    raise 'sord exited non-zero' unless $CHILD_STATUS.success?

    # One line per object, `[WARN ] (UI::Tint.pane_bg) lib/ui/tint.rb:50: …`; the closing
    # summary (`There were 73 important warnings…`) only repeats them, outside constants counted.
    # Parlour, which writes the file for sord, warns on its own: a parameter named after an RBS
    # keyword (`type`) is renamed `_type` in the file.
    offenders = out.lines.grep(/^\[(OMIT|INFER|WARN|ERROR)\s*\] \(/).reject { |line| outside_constant?(line) } +
                out.lines.grep(/^Parlour warning/)
    raise "sord emitted #{offenders.size} warning(s):\n#{offenders.join}" unless offenders.empty?
  end

  # sord resolves names only among this project's YARD objects, so it warns on every type from a
  # gem or the stdlib (`Tuile::Color`, `REXML::Element`) and writes the name through unchanged —
  # right, since RBS resolves it from that gem's own signatures. Such a warning is let through
  # when Ruby itself resolves the name from the top level. One that Ruby resolves only inside an
  # `include Tuile` (a bare `Size`) is still an error: RBS does not see the include.
  #
  # @param line [String] one line of sord's output
  # @return [Boolean] whether the line is that warning, for a constant Ruby does define
  def outside_constant?(line)
    name = line[/\) \S+: (\S+) wasn't able to be resolved to a constant in this project$/, 1]
    return false unless name

    load_app
    Object.const_defined?(name)
  end

  # @return [void]
  def load_app
    @load_app ||= begin
      require_relative '../lib/virtui'
      require 'rexml/document'
      Zeitwerk::Loader.eager_load_all
      true
    end
  end
end

desc 'Regenerate sig/virtui.rbs; see sig:generate'
task sig: 'sig:generate'
