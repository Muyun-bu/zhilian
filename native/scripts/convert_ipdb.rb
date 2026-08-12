require "json"

source, target = ARGV
abort "usage: convert_ipdb.rb source.json target.txt" unless source && target
database = JSON.parse(File.read(source))

File.open(target, "w") do |file|
  database.fetch("ipv4").each { |start_value, end_value| file.puts "4|#{start_value}|#{end_value}" }
  database.fetch("ipv6").each do |start_value, end_value|
    file.puts "6|#{start_value.to_i.to_s(16).rjust(32, "0")}|#{end_value.to_i.to_s(16).rjust(32, "0")}"
  end
end
