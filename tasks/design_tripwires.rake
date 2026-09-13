# frozen_string_literal: true

# Hooks the doc-layer checks into rake (the layout is described in AGENTS.md, "Design docs").
# The bash script is the single implementation; this task only runs it.
#
# Install: copy to tasks/design_tripwires.rake and make sure the Rakefile loads it —
#   Dir.glob('tasks/*.rake').each { |r| load r }
# — then make it part of the umbrella check so the agent's inner loop and CI both run it:
#   task check: %i[test design_tripwires]

desc 'Design docs: cited slugs resolve, headings and caps hold, CLAUDE.md is a symlink'
task :design_tripwires do
  sh 'design/verify_design_tripwires.sh'
end
