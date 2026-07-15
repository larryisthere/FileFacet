require "xcodeproj"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "VideoTagManager.xcodeproj")
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2650"
project.root_object.attributes["LastUpgradeCheck"] = "2650"

app_target = project.new_target(:application, "VideoTagManager", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "VideoTagManagerTests", :osx, "14.0")
test_target.add_dependency(app_target)

main_group = project.main_group

source_directories = %w[App Core Features]
source_directories.each do |directory|
  group = main_group.new_group(directory, directory)
  Dir.glob(File.join(root, directory, "**", "*.swift")).sort.each do |path|
    reference = group.new_file(path.sub("#{root}/#{directory}/", ""))
    app_target.source_build_phase.add_file_reference(reference)
  end
end

config_group = main_group.new_group("Config", "Config")
config_group.new_file("Info.plist")
config_group.new_file("VideoTagManager.entitlements")

resources_group = main_group.new_group("Resources", "Resources")
asset_catalog = resources_group.new_file("Assets.xcassets")
app_target.resources_build_phase.add_file_reference(asset_catalog)

tests_group = main_group.new_group("Tests", "Tests")
Dir.glob(File.join(root, "Tests", "**", "*.swift")).sort.each do |path|
  reference = tests_group.new_file(path.sub("#{root}/Tests/", ""))
  test_target.source_build_phase.add_file_reference(reference)
end

[app_target, test_target].each do |target|
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["CLANG_ENABLE_MODULES"] = "YES"
    settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    settings["SWIFT_VERSION"] = "6.0"
    settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  end
end

app_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["APP_DISPLAY_NAME"] = "Video Tag Manager"
  settings["CODE_SIGN_ENTITLEMENTS"] = "Config/VideoTagManager.entitlements"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["COMBINE_HIDPI_IMAGES"] = "YES"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  settings["ENABLE_APP_SANDBOX"] = "YES"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "Config/Info.plist"
  settings["MARKETING_VERSION"] = "1.0.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.larryisthere.video-tag-manager"
  settings["PRODUCT_NAME"] = "VideoTagManager"
  settings["SDKROOT"] = "macosx"
end

test_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.larryisthere.video-tag-manager.tests"
  settings["PRODUCT_NAME"] = "VideoTagManagerTests"
  settings["SDKROOT"] = "macosx"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/VideoTagManager.app/Contents/MacOS/VideoTagManager"
end

project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, test_target, launch_target: true)
scheme.save_as(project_path, "VideoTagManager", true)
puts project_path
