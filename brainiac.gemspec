require_relative "lib/brainiac/version"

Gem::Specification.new do |s|
  s.name        = "brainiac"
  s.version     = Brainiac::VERSION
  s.summary     = "Multi-agent orchestration layer for developer workflows"
  s.description = "Core orchestration engine that manages AI agent identity, long-term memory (brain), " \
                  "prompt construction, and dispatch. Communication channels are provided by plugins: " \
                  "brainiac-discord, brainiac-fizzy, brainiac-github, and more."
  s.authors     = ["Andy Davis"]
  s.homepage    = "https://github.com/stowzilla/brainiac"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.files = `git ls-files -z`.split("\x0").reject { |f| f.start_with?("test/", "tmp/", ".") }
  s.executables = ["brainiac"]

  s.add_dependency "puma", "~> 7.2"
  s.add_dependency "rackup", "~> 2.3"
  s.add_dependency "sinatra", "~> 4.1"

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.75"
  s.add_development_dependency "rubocop-performance", "~> 1.25"
  s.metadata["rubygems_mfa_required"] = "true"
end
