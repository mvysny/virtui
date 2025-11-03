require_relative 'virt'

virt = VirtCmd.new
domains = virt.domains
domains.each do |domain|
  puts domain
  puts virt.dominfo(domain)
  puts virt.memstat(domain) if domain.running?
end

