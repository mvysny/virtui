# frozen_string_literal: true

# Adds binary (power-of-1024) byte-size unit helpers to every number, so large byte
# counts read as `4.GiB` instead of `4 * 1024 * 1024 * 1024`.
#
# Monkey-patch loaded manually from {Virtui} (see `lib/core_ext/`), since it defines no
# constant of its own and is therefore ignored by the Zeitwerk loader.
class Numeric
  # @return [Numeric] this number of kibibytes, in bytes (`self * 1024`)
  def KiB
    self * 1024
  end

  # @return [Numeric] this number of mebibytes, in bytes (`self * 1024**2`)
  def MiB
    self * 1024 * 1024
  end

  # @return [Numeric] this number of gibibytes, in bytes (`self * 1024**3`)
  def GiB
    self * 1024 * 1024 * 1024
  end
end
