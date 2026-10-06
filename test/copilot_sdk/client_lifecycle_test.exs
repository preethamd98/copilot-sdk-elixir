defmodule CopilotSdk.ClientLifecycleTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{Client, Session, SessionConfig, SessionHooks}
  alias CopilotSdk.Test.MockJsonRpcServer

  defp start_client(opts \\ []) do
    {:ok, mock} = MockJsonRpcServer.start_listener(opts)

    {:ok, client} =
      Client.start_link(
        auto_start: false,
        use_stdio: false,
        cli_url: "tcp://127.0.0.1:#{mock.port}"
      )

    on_exit(fn ->
      if Process.alive?(client), do: GenServer.stop(client)
    end)

    assert :ok = Client.start(client)
    {client, mock}
  end

  test "start is idempotent and session IDs are valid UUIDs" do
    {client, _mock} = start_client()
    rpc = Client.rpc(client)
    assert :ok = Client.start(client)
    assert Client.rpc(client) == rpc
    assert {:ok, session} = Client.create_session(client, %SessionConfig{})

    assert Session.session_id(session) =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "resume accepts keyword options and duplicate sessions do not leak processes" do
    {client, _mock} = start_client()
    assert {:ok, session} = Client.resume_session(client, "existing", model: "test")
    assert Session.session_id(session) == "existing"

    assert {:error, :session_already_connected} =
             Client.resume_session(client, "existing", %{})

    assert {:error, :session_already_connected} =
             Client.create_session(client, session_id: "existing")
  end

  test "hook callbacks work while session.create is awaiting its response" do
    {client, mock} =
      start_client(
        on_request: fn
          "session.create", _ -> :no_reply
          _, _ -> nil
        end
      )

    test_pid = self()

    hooks = %SessionHooks{
      on_session_start: fn input, context ->
        send(test_pid, {:hook, input, context})
        %{"additionalContext" => "hello"}
      end
    }

    task =
      Task.async(fn ->
        Client.create_session(client, session_id: "early", hooks: hooks)
      end)

    assert_receive {:mock_rpc_message, %{"method" => "session.create", "id" => request_id}}, 2000

    send(
      mock.server_pid,
      {:send_message,
       %{
         "jsonrpc" => "2.0",
         "id" => "hook-1",
         "method" => "hooks.invoke",
         "params" => %{
           "sessionId" => "early",
           "hookType" => "sessionStart",
           "input" => %{"source" => "new"}
         }
       }}
    )

    assert_receive {:hook, %{"source" => "new"}, %{session_id: "early"}}, 2000

    assert_receive {:mock_rpc_response,
                    %{
                      "id" => "hook-1",
                      "result" => %{"output" => %{"additionalContext" => "hello"}}
                    }},
                   2000

    send(
      mock.server_pid,
      {:send_message,
       %{
         "jsonrpc" => "2.0",
         "id" => request_id,
         "result" => %{"sessionId" => "early"}
       }}
    )

    assert {:ok, _session} = Task.await(task)
  end

  test "delete sends session.delete for sessions not loaded locally" do
    {client, _mock} = start_client()
    assert :ok = Client.delete_session(client, "saved-on-server")
    assert_receive {:mock_rpc_call, "session.delete", %{"sessionId" => "saved-on-server"}}
  end

  test "delete preserves a local session when the server rejects the request" do
    {client, _mock} =
      start_client(
        on_request: fn
          "session.delete", _ -> {:error, %{"code" => -32000, "message" => "rejected"}}
          _, _ -> nil
        end
      )

    {:ok, session} = Client.create_session(client, session_id: "keep")
    assert {:error, %{message: "rejected"}} = Client.delete_session(client, "keep")
    assert Process.alive?(session)
  end

  test "force stop terminates sessions and their child processes" do
    {client, _mock} = start_client()
    {:ok, session} = Client.create_session(client, %{})
    state = :sys.get_state(session)
    assert :ok = Client.force_stop(client)
    refute Process.alive?(session)
    refute Process.alive?(state.event_producer_pid)
    refute Process.alive?(state.consumer_supervisor)
    refute Process.alive?(state.task_supervisor)
    assert Client.get_state(client) == :disconnected
  end

  test "lifecycle unsubscribe targets the client rather than the caller" do
    {client, _mock} = start_client()
    test_pid = self()
    unsubscribe = Client.on(client, &send(test_pid, {:lifecycle, &1}))
    unsubscribe.()
    {:ok, _session} = Client.create_session(client, %{})
    refute_receive {:lifecycle, _}
    refute_receive {:"$gen_cast", {:remove_lifecycle_handler, _}}
  end

  test "list_models can use a configured provider without connecting" do
    {:ok, client} =
      Client.start_link(auto_start: false, on_list_models: fn -> [%{"id" => "custom"}] end)

    assert {:ok, %{"models" => [%{"id" => "custom"}]}} = Client.list_models(client)
    GenServer.stop(client)
  end
end
