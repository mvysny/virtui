# frozen_string_literal: true

# Adds binary byte size units to all numbers,
# to allow for easier construction of large byte sizes.
class Numeric
  def KiB
    self * 1024
  end

  def MiB
    self * 1024 * 1024
  end

  def GiB
    self * 1024 * 1024 * 1024
  end
end
