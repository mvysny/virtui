# frozen_string_literal: true

# Binary (power-of-1024) byte-size helpers: constructors on {Numeric} (`4.GiB`) and the
# inverse renderer {#format_byte_size} (bytes → human string). Both are loaded manually
# from {Virtui} (see `lib/core_ext/`) since neither defines a matching constant, so the
# Zeitwerk loader ignores them.

# Adds binary (power-of-1024) byte-size unit helpers to every number, so large byte
# counts read as `4.GiB` instead of `4 * 1024 * 1024 * 1024`.
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

# Pretty-formats a byte count with a binary (1024-based) unit suffix `K`/`M`/`G`/`T`/`P`,
# showing one decimal place only when it adds precision. Negative values keep their sign;
# zero renders as `"0"`. Magnitudes above petabytes are capped at `P`.
#
# @param bytes [Integer] size in bytes
# @return [String] e.g. `"0"`, `"1.0K"`, `"23.8M"`, `"8.0G"`, `"-512K"`
def format_byte_size(bytes)
  return '0' if bytes.zero?
  return "-#{format_byte_size(-bytes)}" if bytes.negative?

  units = ['', 'K', 'M', 'G', 'T', 'P']

  # Use 1024-based units (KiB, MiB, etc.)
  exp = Math.log(bytes, 1024).floor
  exp = 5 if exp > 5 # Cap at petabytes

  value = bytes.to_f / (1024**exp)

  # Show one decimal if it's not a whole number, otherwise none
  decimals = value >= 10 || value.round == value ? 0 : 1
  "#{value.round(decimals)}#{units[exp]}"
end
