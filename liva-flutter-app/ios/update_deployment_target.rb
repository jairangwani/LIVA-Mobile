#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Update deployment target for all targets
project.targets.each do |target|
  puts "Updating deployment target for #{target.name}..."
  target.build_configurations.each do |config|
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  end
end

# Update deployment target for the project
project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

project.save

puts "✅ Updated iOS deployment target to 15.0"
