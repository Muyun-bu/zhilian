source, target = ARGV
abort "usage: make_cidr_rules.rb china-ip-ranges.txt china-ip-cidrs.txt" unless source && target

def each_cidr(first, last, width)
  while first <= last
    alignment = first.zero? ? width : [((first & -first).bit_length - 1), width].min
    remaining = (last - first + 1).bit_length - 1
    host_bits = [alignment, remaining].min
    yield first, width - host_bits
    first += 1 << host_bits
  end
end

File.open(target, "w") do |file|
  File.foreach(source) do |line|
    type, first_value, last_value = line.strip.split("|")
    next unless type && first_value && last_value
    width = type == "4" ? 32 : 128
    first = type == "4" ? first_value.to_i : first_value.to_i(16)
    last = type == "4" ? last_value.to_i : last_value.to_i(16)
    each_cidr(first, last, width) do |address, prefix|
      if width == 32
        text = [24, 16, 8, 0].map { |shift| (address >> shift) & 255 }.join(".")
      else
        groups = 8.times.map { |index| (address >> (112 - index * 16)) & 0xffff }
        text = groups.map { |group| group.to_s(16) }.join(":")
      end
      file.puts "#{text}/#{prefix}"
    end
  end
end
