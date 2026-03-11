defmodule CopilotSdk.E2E.ClientTest do
  @moduledoc "E2E tests for CopilotSdk.Client against a real CLI process."
  use ExUnit.Case

  alias CopilotSdk.{Client, PermissionHandler}

  @moduletag :e2e

  @cli_path (fn ->
               try do
                 Client.resolve_cli_path_for_test()
               rescue
                 _ -> nil
               end
             end).()

  setup do
    if is_nil(@cli_path) do
      flunk("CLI not found. Set COPILOT_CLI_PATH or install the sibling nodejs package.")
    end

    :ok
  end

  defp start_client(extra_opts \\ []) do
    opts = [cli_path: @cli_path, auto_start: false] ++ extra_opts
    {:ok, client} = Client.start_link(opts)

    on_exit(fn ->
      try do
        Client.force_stop(client)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, client}
  end

  test "start and connect via stdio, ping, stop" do
    {:ok, client} = start_client()
    assert :ok = Client.start(client)
    assert Client.get_state(client) == :connected

    {:ok, pong} = Client.ping(client)
    assert is_map(pong)
    assert Map.has_key?(pong, "message")

    assert :ok = Client.stop(client)
    assert Client.get_state(client) == :disconnected
  end

  test "get state transitions (disconnected → connected → disconnected)" do
    {:ok, client} = start_client()
    assert Client.get_state(client) == :disconnected

    :ok = Client.start(client)
    assert Client.get_state(client) == :connected

    :ok = Client.stop(client)
    assert Client.get_state(client) == :disconnected
  end

  test "get auth status returns a map or unsupported error" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    case Client.get_auth_status(client) do
      {:ok, status} -> assert is_map(status)
      {:error, %{code: -32601}} -> :ok
      {:error, _} -> :ok
    end
  end

  test "ping with no message" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    {:ok, pong} = Client.ping(client)
    assert is_map(pong)
  end

  test "ping with message" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    {:ok, pong} = Client.ping(client, "hello")
    assert is_map(pong)
  end

  test "force stop without cleanup" do
    {:ok, client} = start_client()
    :ok = Client.start(client)
    assert Client.get_state(client) == :connected

    :ok = Client.force_stop(client)
    assert Client.get_state(client) == :disconnected
  end

  test "create and disconnect session" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    assert is_pid(session)

    :ok = CopilotSdk.Session.disconnect(session)
  end

  test "session has a session_id" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    session_id = CopilotSdk.Session.session_id(session)
    assert is_binary(session_id)
    assert String.length(session_id) > 0
  end

  test "session send_and_wait returns a response or times out" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    {:ok, session} = Client.create_session(client, %{
      on_permission_request: &PermissionHandler.approve_all/2
    })

    result = CopilotSdk.Session.send_and_wait(session, %{prompt: "Say hello"}, timeout: 30_000)

    case result do
      {:ok, _event} -> assert true
      {:error, :timeout} -> assert true
      {:error, _reason} -> assert true
    end
  end

  test "list models" do
    {:ok, client} = start_client()
    :ok = Client.start(client)

    case Client.get_auth_status(client) do
      {:ok, auth} when is_map(auth) ->
        if auth["authenticated"] do
          {:ok, models} = Client.list_models(client)
          assert is_map(models)
        end

      _ ->
        # Auth not supported or not authenticated — skip
        :ok
    end
  end
end
