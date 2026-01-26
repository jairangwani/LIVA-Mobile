#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the Runner target
target = project.targets.find { |t| t.name == 'Runner' }

# Find the Runner group
runner_group = project.main_group.groups.find { |g| g.name == 'Runner' } || project.main_group

# Add the plugin file if it doesn't exist
plugin_file_path = 'Runner/LIVAAnimationPlugin.swift'
file_ref = runner_group.files.find { |f| f.path == 'LIVAAnimationPlugin.swift' }

if file_ref.nil?
  # Add file reference
  file_ref = runner_group.new_file(plugin_file_path)

  # Add to compile sources build phase
  target.source_build_phase.add_file_reference(file_ref)

  puts "✅ Added LIVAAnimationPlugin.swift to Xcode project"
else
  puts "ℹ️  LIVAAnimationPlugin.swift already in project"
end

# Save the project
project.save

puts "✅ Project saved successfully"
