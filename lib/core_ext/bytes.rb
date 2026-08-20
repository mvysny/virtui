# frozen_string_literal: true

# Binary (power-of-1024) byte-size helpers, an inverse pair:
#
#   format_byte_size(4.GiB)   # => "4G"

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
# @return [String] e.g. `"0"`, `"1K"`, `"1.5K"`, `"24M"`, `"-512K"`
def format_byte_size(bytes)
  return '0' if bytes.zero?
  return "-#{format_byte_size(-bytes)}" if bytes.negative?

  units = ['', 'K', 'M', 'G', 'T', 'P']

  exp = Math.log(bytes, 1024).floor
  exp = 5 if exp > 5 # Cap at petabytes

  value = bytes.to_f / (1024**exp)

  decimals = value >= 10 || value.round == value ? 0 : 1
  "#{value.round(decimals)}#{units[exp]}"
end
