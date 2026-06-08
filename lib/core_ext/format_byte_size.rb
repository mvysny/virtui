# frozen_string_literal: true

# Pretty-formats a byte count with a binary (1024-based) unit suffix `K`/`M`/`G`/`T`/`P`,
# showing one decimal place only when it adds precision. Negative values keep their sign;
# zero renders as `"0"`. Magnitudes above petabytes are capped at `P`.
#
# Top-level helper loaded manually from {Virtui} (see `lib/core_ext/`); defines no
# constant, so the Zeitwerk loader ignores it.
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
