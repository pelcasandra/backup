#!/usr/bin/env ruby
# encoding: utf-8

number_of_nodes = Integer(ENV.fetch("NUMBER_OF_NODES", "1"))
node_index = Integer(ENV.fetch("CI_NODE_INDEX", "0"))

abort "NUMBER_OF_NODES must be greater than zero" unless number_of_nodes > 0
unless node_index.between?(0, number_of_nodes - 1)
  abort "CI_NODE_INDEX must be between 0 and #{number_of_nodes - 1}"
end

shards = Array.new(number_of_nodes) { { size: 0, specs: [] } }

Dir["spec/**/*_spec.rb"].sort_by { |spec| [-File.size(spec), spec] }.each do |spec|
  shard = shards.min_by { |candidate| candidate[:size] }
  shard[:specs] << spec
  shard[:size] += File.size(spec)
end

specs = shards.fetch(node_index)[:specs].sort
abort "No specs assigned to shard #{node_index}" if specs.empty?

puts "Running shard #{node_index + 1}/#{number_of_nodes} (#{specs.length} spec files)"
exec "bundle", "exec", "rspec", *specs
