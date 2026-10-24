# frozen_string_literal: true

# Raised by {Cancellation#check_canceled}: the user canceled the work, and nothing failed.
#
# An `Exception`, not a `StandardError`, so a `rescue => e` between the check and whatever
# runs the work cannot swallow the cancel; `ensure` blocks still run.
class CanceledError < Exception # rubocop:disable Lint/InheritException
end
