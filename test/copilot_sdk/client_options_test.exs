defmodule CopilotSdk.ClientOptionsTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.ClientOptions

  test "creates default options" do
    opts = ClientOptions.new()
    assert opts.use_stdio == true
    assert opts.auto_start == true
    assert opts.log_level == "info"
    assert opts.cli_args == []
  end

  test "accepts valid options" do
    opts = ClientOptions.new(cli_path: "/usr/bin/copilot", log_level: "debug")
    assert opts.cli_path == "/usr/bin/copilot"
    assert opts.log_level == "debug"
  end

  test "raises on cli_url + cli_path conflict" do
    assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
      ClientOptions.new(cli_url: "http://localhost:3000", cli_path: "/usr/bin/copilot")
    end
  end

  test "raises on cli_url + use_stdio conflict" do
    assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
      ClientOptions.new(cli_url: "http://localhost:3000", use_stdio: true)
    end
  end

  test "raises on cli_url + github_token conflict" do
    assert_raise ArgumentError, ~r/cannot be used with cli_url/, fn ->
      ClientOptions.new(cli_url: "http://localhost:3000", github_token: "ghp_xxx")
    end
  end

  test "raises on cli_url + use_logged_in_user conflict" do
    assert_raise ArgumentError, ~r/cannot be used with cli_url/, fn ->
      ClientOptions.new(cli_url: "http://localhost:3000", use_logged_in_user: true)
    end
  end

  test "allows cli_url without stdio" do
    opts = ClientOptions.new(cli_url: "http://localhost:3000", use_stdio: false)
    assert opts.cli_url == "http://localhost:3000"
    assert opts.use_stdio == false
  end
end
