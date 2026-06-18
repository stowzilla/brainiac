require "bundler/gem_tasks"
require "rubocop/rake_task"
require "minitest/test_task"

RuboCop::RakeTask.new

Minitest::TestTask.create(:test) do |t|
  t.test_globs = ["test/**/test_*.rb"]
  t.test_prelude = nil
end

task default: %i[test rubocop]
