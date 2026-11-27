require "yaml"

def jobs(workflow)
  path = File.join(__dir__, "..", ".github", "workflows", workflow)
  YAML.safe_load(File.read(path)).fetch("jobs")
end

release = jobs("release.yml")
gate = release.fetch("simulator-tests")
publish = release.fetch("release")
abort "Publishing must require the simulator" unless publish.fetch("needs").include?("simulator-tests")
abort "Publishing must require successful test jobs" if publish.key?("if")
abort "The release simulator may not be skipped" if gate.key?("if") || gate["continue-on-error"]
workflow = gate.fetch("uses")
pull_request_workflow = jobs("tests.yml").fetch("simulator-tests").fetch("uses")
abort "Pull requests and releases must exercise the same simulator suite" unless pull_request_workflow == workflow
simulator = jobs(File.basename(workflow)).fetch("simulator-tests")
test = simulator.fetch("steps").find { |step| step["run"].to_s.include?("xcodebuild test") }
abort "The simulator must run XCTest" unless test
abort "An XCTest failure must fail the job" if [simulator, test].any? { |item| item.key?("if") || item["continue-on-error"] }
puts "Publishing requires the simulator XCTest suite"
