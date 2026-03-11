defmodule CopilotSdk.ClientTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{Client, ClientOptions}

  describe "option validation" do
    test "cli_url and cli_path are mutually exclusive" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        ClientOptions.new(cli_url: "http://localhost:3000", cli_path: "/usr/bin/copilot")
      end
    end

    test "cli_url and use_stdio are mutually exclusive" do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        ClientOptions.new(cli_url: "http://localhost:3000", use_stdio: true)
      end
    end

    test "github_token cannot be used with cli_url" do
      assert_raise ArgumentError, ~r/cannot be used with cli_url/, fn ->
        ClientOptions.new(cli_url: "http://localhost:3000", github_token: "ghp_xxx")
      end
    end

    test "use_logged_in_user cannot be used with cli_url" do
      assert_raise ArgumentError, ~r/cannot be used with cli_url/, fn ->
        ClientOptions.new(cli_url: "http://localhost:3000", use_logged_in_user: true)
      end
    end

    test "accepts valid options without error" do
      opts = ClientOptions.new(cli_path: "/usr/bin/copilot", log_level: "debug")
      assert opts.cli_path == "/usr/bin/copilot"
      assert opts.log_level == "debug"
    end

    test "cli_url requires use_stdio: false" do
      opts = ClientOptions.new(cli_url: "http://localhost:3000", use_stdio: false)
      assert opts.cli_url == "http://localhost:3000"
      assert opts.use_stdio == false
    end
  end

  describe "parse_cli_url/1" do
    test "parses http://localhost:7000 correctly" do
      {host, port} = Client.parse_cli_url("http://localhost:7000")
      assert host == "localhost"
      assert port == 7000
    end

    test "parses https://example.com:443 correctly" do
      {host, port} = Client.parse_cli_url("https://example.com:443")
      assert host == "example.com"
      assert port == 443
    end

    test "uses default port when none specified" do
      {host, port} = Client.parse_cli_url("http://myhost")
      assert host == "myhost"
      assert port == 80
    end
  end

  describe "auth options" do
    test "accepts github_token" do
      opts = ClientOptions.new(github_token: "ghp_test123")
      assert opts.github_token == "ghp_test123"
    end
  end
end
