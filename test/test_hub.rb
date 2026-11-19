# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/hooks"
require_relative "../lib/brainiac/hub"

class TestHub < Minitest::Test
  TOKEN = "node-token"

  # Stands in for Brainiac::Hub::Client. Records calls, answers from a script.
  class FakeClient
    attr_reader :calls
    attr_accessor :checkin_response

    def initialize
      @calls = []
      @checkin_response = { "leader" => nil, "jobs" => [] }
    end

    def post(path, payload)
      @calls << [:post, path, payload]
      path == "/nodes" ? @checkin_response : { "status" => "delivered", "machine" => "mini" }
    end

    def put(path, payload) = (@calls << [:put, path, payload]) && {}
    def get(path) = (@calls << [:get, path]) && { "assignments" => [{ "key" => "fizzy:1", "machine" => "mini" }] }
    def delete(path) = (@calls << [:delete, path]) && {}
  end

  def setup
    Brainiac.reset_hooks!
    @client = FakeClient.new
    use_config({})
  end

  def teardown
    Brainiac::Hub.node = nil
    Brainiac.reset_hooks!
    ENV.delete("BRAINIAC_HUB_TOKEN")
  end

  def use_config(config)
    @node = Brainiac::Hub::Node.new(config, client: @client)
    Brainiac::Hub.node = @node
  end

  def configure(extra = {})
    use_config({ "url" => "https://hub.test/prod", "token" => TOKEN, "machine" => "Mini PC",
                 "public_url" => "https://mini.test/", "priority" => 10 }.merge(extra))
  end

  def sign(timestamp, job, path, body, token = TOKEN)
    OpenSSL::HMAC.hexdigest("SHA256", token, "#{timestamp}.#{job}.#{path}.#{body}")
  end

  # --- off by default ---

  def test_disabled_without_config_and_always_leader
    refute Brainiac::Hub.enabled?
    assert Brainiac::Hub.leader?, "a single machine must keep running cron and Discord"
    assert_nil Brainiac::Hub.start!(port: 4567)
    assert_nil Brainiac::Hub.stop!
    assert_empty @client.calls
  end

  def test_needs_both_url_and_token
    use_config("url" => "https://hub.test")
    refute Brainiac::Hub.enabled?

    ENV["BRAINIAC_HUB_TOKEN"] = "from-env"
    assert Brainiac::Hub.enabled?
    assert_equal "from-env", Brainiac::Hub.settings.token
  end

  def test_machine_name_is_normalised
    configure
    assert_equal "mini-pc", Brainiac::Hub.machine_name
  end

  # --- check-in ---

  def test_checkin_sends_identity_and_strips_trailing_slash
    configure
    assert @node.check_in

    _, path, payload = @client.calls.first
    assert_equal "/nodes", path
    assert_equal "mini-pc", payload[:name]
    assert_equal "https://mini.test", payload[:url]
    assert_equal 10, payload[:priority]
    assert_equal 120, payload[:interval]
    assert payload[:wants_leader]
  end

  def test_checkin_is_skipped_until_there_is_a_public_url
    configure("public_url" => nil)

    refute @node.check_in
    assert_empty @client.calls
  end

  def test_failed_checkin_returns_false
    configure
    @client.checkin_response = nil

    refute @node.check_in
    refute Brainiac::Hub.leader?
  end

  # --- leader role ---

  def test_leader_follows_the_hub_and_fires_hooks_once
    configure
    events = Queue.new
    Brainiac.on(:hub_leader_acquired) { |ctx| events << [:acquired, ctx[:machine]] }
    Brainiac.on(:hub_leader_lost) { |ctx| events << [:lost, ctx[:machine]] }
    @node.start_leader_events

    refute Brainiac::Hub.leader?
    @client.checkin_response = { "leader" => "mini-pc", "jobs" => [] }
    @node.check_in
    @node.check_in
    assert Brainiac::Hub.leader?
    assert_equal [:acquired, "mini-pc"], events.pop(timeout: 2)

    @client.checkin_response = { "leader" => "main", "jobs" => [] }
    @node.check_in
    refute Brainiac::Hub.leader?
    assert_equal [:lost, "mini-pc"], events.pop(timeout: 2)
    assert events.empty?, "renewing the lease must not re-fire the hook"
  end

  def test_leader_steps_down_when_the_hub_is_unreachable_too_long
    configure("interval" => 60)
    @client.checkin_response = { "leader" => "mini-pc", "jobs" => [] }
    @node.check_in
    assert Brainiac::Hub.leader?

    # Two missed intervals: stop before the hub's lease (three intervals) can pass to someone else.
    @node.last_ok = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 121
    refute Brainiac::Hub.leader?
  end

  def test_leader_false_is_sent_when_configured
    configure("leader" => false)
    @node.check_in

    refute @client.calls.first[2][:wants_leader]
  end

  # --- signatures and dedupe ---

  def test_signature_checks_token_fields_and_age
    configure
    now = 1_800_000_000
    good = sign(now, "j1", "/fizzy/b", "{}")

    assert Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/fizzy/b", body: "{}", signature: good, now: now)
    refute Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/fizzy/b", body: "{ }", signature: good, now: now)
    refute Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/github", body: "{}", signature: good, now: now)
    refute Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/fizzy/b", body: "{}", signature: good, now: now + 301)
    refute Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/fizzy/b", body: "{}",
                                          signature: sign(now, "j1", "/fizzy/b", "{}", "wrong"), now: now)
    refute Brainiac::Hub.valid_signature?(timestamp: now.to_s, job_id: "j1", path: "/fizzy/b", body: "{}", signature: "", now: now)
  end

  def test_first_delivery_is_true_once
    configure
    assert Brainiac::Hub.first_delivery?("a")
    refute Brainiac::Hub.first_delivery?("a")
    assert Brainiac::Hub.first_delivery?("b")
  end

  # --- claims ---

  def test_worktree_branches_skip_the_main_checkout_and_detached_heads
    porcelain = <<~OUT
      worktree /code/app
      HEAD 1111
      branch refs/heads/main

      worktree /code/app--fizzy-12-fix
      HEAD 2222
      branch refs/heads/fizzy-12-fix

      worktree /code/app--detached
      HEAD 3333
      detached

      worktree /code/app--galen-review
      HEAD 4444
      branch refs/heads/galen/fizzy-9-x
    OUT

    assert_equal ["fizzy-12-fix", "galen/fizzy-9-x"], Brainiac::Hub::Claims.worktree_branches(porcelain)
  end

  def test_local_branch_keys_reads_real_worktrees
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "app")
      system("git", "init", "-q", "-b", "main", repo, exception: true)
      system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init",
             exception: true)
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "topic", File.join(dir, "app--topic"), exception: true)

      keys = Brainiac::Hub::Claims.local_branch_keys(
        "app" => { "repo_path" => repo, "github_repo" => "acme/app" },
        "no-github" => { "repo_path" => repo },
        "missing" => { "repo_path" => File.join(dir, "nope"), "github_repo" => "acme/nope" }
      )
      assert_equal ["branch:acme/app:topic"], keys
    end
  end

  # --- hub API helpers ---

  def test_relay_and_assign_and_assignments
    configure

    result = Brainiac::Hub.relay(path: "/hub/x", payload: { "a" => 1 }, keys: ["discord:1"], machine: "mini")
    assert_equal "delivered", result["status"]
    assert_equal [:post, "/relays", { path: "/hub/x", body: '{"a":1}', keys: ["discord:1"], machine: "mini", reassign: false }],
                 @client.calls.last

    Brainiac::Hub.assign("fizzy:1", "main")
    assert_equal [:put, "/assignments", { machine: "main", keys: ["fizzy:1"], overwrite: true }], @client.calls.last

    assert_equal [{ "key" => "fizzy:1", "machine" => "mini" }], Brainiac::Hub.assignments("fizzy:")
    assert_equal [:get, "/assignments?prefix=fizzy%3A"], @client.calls.last
  end

  def test_owner_reads_one_key_and_release_forgets_it
    configure

    assert_equal "mini", Brainiac::Hub.owner("fizzy:1")
    assert_equal [:get, "/assignments?key=fizzy%3A1"], @client.calls.last
    # A hub without the single-key read answers with the whole table: only an exact match counts.
    assert_nil Brainiac::Hub.owner("discord:galen:9")

    Brainiac::Hub.release("discord:galen:9")
    assert_equal [:delete, "/assignments?key=discord%3Agalen%3A9"], @client.calls.last
  end

  # --- tunnel ---

  def test_tunnel_reads_the_quick_tunnel_url_and_reports_changes
    seen = []
    tunnel = Brainiac::Hub::Tunnel.from_config("cloudflared", port: 4567) { |url| seen << url }

    tunnel.read_line("2026-11-17T12:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...\n")
    tunnel.read_line(%(ERR failed: Post "https://api.trycloudflare.com/tunnel": timeout\n))
    assert_nil tunnel.url

    tunnel.read_line("2026-11-17T12:00:01Z INF |  https://calm-river-demo.trycloudflare.com   |\n")
    tunnel.read_line("INF again https://calm-river-demo.trycloudflare.com\n")
    assert_equal "https://calm-river-demo.trycloudflare.com", tunnel.url
    assert_equal ["https://calm-river-demo.trycloudflare.com"], seen

    tunnel.read_line("INF https://new-name-here.trycloudflare.com\n")
    assert_equal 2, seen.size
  end

  def test_tunnel_accepts_a_custom_command_and_rejects_unknown_presets
    tunnel = Brainiac::Hub::Tunnel.from_config(
      { "command" => ["mytunnel", "--port", "%<port>d"], "url_pattern" => 'https://[a-z0-9.-]+\.example\.dev' }, port: 9999
    )
    assert_equal ["mytunnel", "--port", "9999"], tunnel.instance_variable_get(:@command)
    tunnel.read_line("ready at https://box1.example.dev now")
    assert_equal "https://box1.example.dev", tunnel.url

    assert_raises(ArgumentError) { Brainiac::Hub::Tunnel.from_config("nope", port: 1) }
  end
end

class TestHubInbox < Minitest::Test
  TOKEN = TestHub::TOKEN

  def setup
    Brainiac::Hub.node = Brainiac::Hub::Node.new(
      { "url" => "https://hub.test", "token" => TOKEN, "public_url" => "https://n.test" }
    )
    @seen = []
    app = lambda do |env|
      @seen << [env["PATH_INFO"], env["rack.input"].read, env["HTTP_X_WEBHOOK_SIGNATURE"]]
      [200, {}, ["ok"]]
    end
    @inbox = Brainiac::Hub::Inbox.new(app, async: false)
  end

  def teardown
    Brainiac::Hub.node = nil
  end

  def env_for(path, body, headers = {})
    { "PATH_INFO" => path, "REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body) }.merge(headers)
  end

  def hub_headers(path, body, job: "job-1", timestamp: Time.now.to_i, token: TOKEN)
    { "HTTP_X_BRAINIAC_HUB_JOB" => job, "HTTP_X_BRAINIAC_HUB_TIMESTAMP" => timestamp.to_s,
      "HTTP_X_BRAINIAC_HUB_SIGNATURE" => OpenSSL::HMAC.hexdigest("SHA256", token, "#{timestamp}.#{job}.#{path}.#{body}") }
  end

  def test_direct_requests_pass_straight_through
    status, = @inbox.call(env_for("/fizzy/board", '{"a":1}'))

    assert_equal 200, status
    assert_equal [["/fizzy/board", '{"a":1}', nil]], @seen
  end

  def test_hub_delivery_is_acknowledged_and_run_with_the_original_body
    body = %({"a":  1})
    env = env_for("/fizzy/board", body, hub_headers("/fizzy/board", body).merge("HTTP_X_WEBHOOK_SIGNATURE" => "sig"))

    status, _, response = @inbox.call(env)
    assert_equal 202, status
    assert_equal '{"status":"accepted"}', response.first
    assert_equal [["/fizzy/board", body, "sig"]], @seen
  end

  def test_same_job_runs_once
    body = "{}"
    2.times { @inbox.call(env_for("/github", body, hub_headers("/github", body))) }
    status, = @inbox.call(env_for("/github", body, hub_headers("/github", body)))

    assert_equal 200, status
    assert_equal 1, @seen.size
  end

  def test_bad_signature_is_refused_and_never_reaches_the_route
    body = "{}"
    wrong_token = hub_headers("/github", body, token: "other")
    tampered = hub_headers("/github", "{}").merge("PATH_INFO" => "/github")
    stale = hub_headers("/github", body, job: "old", timestamp: Time.now.to_i - 3600)

    assert_equal 401, @inbox.call(env_for("/github", body, wrong_token)).first
    assert_equal 401, @inbox.call(env_for("/github", '{"x":1}', tampered)).first
    assert_equal 401, @inbox.call(env_for("/github", body, stale)).first
    assert_empty @seen
  end

  def test_hub_only_paths_refuse_unsigned_requests
    assert_equal 401, @inbox.call(env_for("/hub/anything", "{}")).first
    assert_empty @seen

    body = "{}"
    assert_equal 202, @inbox.call(env_for("/hub/anything", body, hub_headers("/hub/anything", body))).first
    assert_equal 1, @seen.size
  end

  def test_hub_jobs_cannot_name_the_admin_api_or_dashboard
    body = "{}"
    ["/api/reload", "/API/reload", "/api", "/dashboard", "/hub/../api/reload", "/fizzy/../api/reload"].each do |path|
      status, = @inbox.call(env_for(path, body, hub_headers(path, body, job: "job-#{path}")))
      assert_equal 403, status, path
    end
    assert_empty @seen

    # Ordinary local requests to the admin API are not the inbox's business.
    assert_equal 200, @inbox.call(env_for("/api/status", "")).first
  end

  def test_hub_headers_are_ignored_when_no_hub_is_configured
    Brainiac::Hub.node = Brainiac::Hub::Node.new({})
    body = "{}"

    status, = @inbox.call(env_for("/github", body, hub_headers("/github", body)))
    assert_equal 200, status, "without a hub the request is an ordinary direct webhook"
    assert_equal 401, @inbox.call(env_for("/hub/x", body, hub_headers("/hub/x", body, job: "j2"))).first
  end

  def test_async_mode_acknowledges_before_the_route_finishes
    gate = Queue.new
    done = Queue.new
    slow = lambda do |_env|
      gate.pop
      done << :ran
      [200, {}, []]
    end
    inbox = Brainiac::Hub::Inbox.new(slow)
    body = "{}"

    status, = inbox.call(env_for("/github", body, hub_headers("/github", body, job: "slow")))
    assert_equal 202, status
    assert done.empty?, "the acknowledgement must not wait for the route"
    gate << :go
    assert_equal :ran, done.pop(timeout: 2)
  end
end

class TestHubCLI < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("hub-cli")
    @path = File.join(@dir, "brainiac.json")
    File.write(@path, JSON.generate("default_agent" => "Sherlock"))
    @out = StringIO.new
    @client = TestHub::FakeClient.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def cli(node: nil)
    require_relative "../lib/brainiac/hub/cli"
    Brainiac::Hub::CLI.new(config_path: @path, out: @out, node: node)
  end

  def saved = JSON.parse(File.read(@path))

  def test_setup_writes_the_hub_block_and_keeps_other_settings
    status = cli.run(%w[setup --url https://hub.test/prod/ --token abc123 --machine mini --priority 5 --tunnel cloudflared --no-leader])

    assert_equal 0, status
    assert_equal "Sherlock", saved["default_agent"]
    assert_equal({ "url" => "https://hub.test/prod", "token" => "abc123", "machine" => "mini", "priority" => 5,
                   "tunnel" => "cloudflared", "leader" => false }, saved["hub"])
    assert_equal "600", format("%o", File.stat(@path).mode & 0o777)
  end

  def test_setup_needs_a_way_to_reach_the_machine
    assert_equal 1, cli.run(%w[setup --url https://hub.test --token abc])
    assert_nil saved["hub"]
    assert_equal 1, cli.run(%w[setup --public-url https://x.test])
  end

  def test_public_url_replaces_tunnel_on_a_second_run
    cli.run(%w[setup --url https://hub.test --token abc --tunnel cloudflared])
    cli.run(%w[setup --public-url https://mini.example.test/])

    assert_equal "https://mini.example.test", saved["hub"]["public_url"]
    refute saved["hub"].key?("tunnel")
    assert_equal "abc", saved["hub"]["token"], "a re-run keeps what was already set"
  end

  def test_show_hides_the_token_and_disable_removes_the_block
    cli.run(%w[setup --url https://hub.test --token supersecret --tunnel cloudflared])
    @out.truncate(0)
    cli.run(%w[show])
    refute_includes @out.string, "supersecret"

    cli.run(%w[disable])
    assert_nil saved["hub"]
    assert_equal "Sherlock", saved["default_agent"]
  end

  def test_commands_that_need_a_hub_say_so
    assert_equal 1, cli.run(%w[status])
    assert_includes @out.string, "No hub configured"
  end

  def test_status_lists_machines_leader_and_queue
    node = Brainiac::Hub::Node.new({ "url" => "https://hub.test", "token" => "t", "machine" => "mini" }, client: @client)
    def @client.get(_path)
      { "leader" => "mini", "queued" => { "*" => 2, "gpu" => 1 },
        "nodes" => [{ "name" => "mini", "online" => true, "priority" => 10, "last_seen_at" => 1_800_000_000 },
                    { "name" => "gpu", "online" => false, "priority" => 50, "last_seen_at" => 0 }] }
    end

    assert_equal 0, cli(node: node).run(%w[status])
    text = @out.string
    assert_match(/mini\s+online\s+priority 10.*\(this machine, leader\)/, text)
    assert_match(/gpu\s+OFFLINE\s+priority 50\s+last seen never/, text)
    assert_includes text, "2 for the first machine to check in"
    assert_includes text, "1 for gpu"
  end

  def test_move_and_release_call_the_hub
    node = Brainiac::Hub::Node.new({ "url" => "https://hub.test", "token" => "t" }, client: @client)

    assert_equal 0, cli(node: node).run(%w[move fizzy:1834 Mini])
    assert_equal [:put, "/assignments", { machine: "mini", keys: ["fizzy:1834"], overwrite: true }], @client.calls.last
    assert_equal 0, cli(node: node).run(%w[release fizzy:1834])
    assert_equal [:delete, "/assignments?key=fizzy%3A1834"], @client.calls.last
    assert_equal 1, cli(node: node).run(%w[move fizzy:1834])
  end
end
