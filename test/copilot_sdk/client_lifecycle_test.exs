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

    assert {:ok, session} =
             Client.resume_session(client, "existing",
               model: "test",
               suppress_resume_event: true,
               continue_pending_work: false
             )

    assert_receive {:mock_rpc_call, "session.resume",
                    %{
                      "sessionId" => "existing",
                      "disableResume" => true,
                      "continuePendingWork" => false
                    }}

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

  test "connect authentication errors do not fall back to ping" do
    {:ok, mock} =
      MockJsonRpcServer.start_listener(
        on_request: fn
          "connect", _ -> {:error, %{"code" => -32001, "message" => "unauthorized"}}
          _, _ -> nil
        end
      )

    {:ok, client} =
      Client.start_link(
        auto_start: false,
        use_stdio: false,
        cli_url: "tcp://127.0.0.1:#{mock.port}",
        connection_token: "test-connection-token"
      )

    assert {:error, {:handshake_failed, %{message: "unauthorized"}}} = Client.start(client)
    assert_receive {:mock_rpc_call, "connect", %{"token" => "test-connection-token"}}
    refute_receive {:mock_rpc_call, "ping", _}
    GenServer.stop(client)
  end

  test "connect falls back to ping only for legacy servers without a configured token" do
    {client, _mock} =
      start_client(
        on_request: fn
          "connect", _ -> {:error, %{"code" => -32601, "message" => "Method not found"}}
          _, _ -> nil
        end
      )

    assert Client.get_state(client) == :connected
    assert_receive {:mock_rpc_call, "connect", %{}}
    assert_receive {:mock_rpc_call, "ping", %{}}
  end

  test "delete handles server-level failure without discarding the session" do
    {client, _mock} =
      start_client(
        on_request: fn
          "session.delete", _ -> %{"success" => false, "error" => "busy"}
          _, _ -> nil
        end
      )

    {:ok, session} = Client.create_session(client, session_id: "busy")
    assert {:error, "busy"} = Client.delete_session(client, "busy")
    assert Process.alive?(session)
  end

  test "unexpected session IDs clean up preregistered callbacks and processes" do
    {client, _mock} =
      start_client(
        on_request: fn
          "session.create", _ -> %{"sessionId" => "unexpected"}
          _, _ -> nil
        end
      )

    assert {:error, :invalid_session_id} = Client.create_session(client, session_id: "requested")
    state = :sys.get_state(client)
    assert state.sessions == %{}
    assert :ets.tab2list(state.session_registry) == []
    assert DynamicSupervisor.which_children(state.session_supervisor) == []
  end

  test "string-keyed callback config is normalized before registration" do
    {client, mock} = start_client()

    config = %{
      "sessionId" => "string-config",
      "onUserInputRequest" => fn request, _ ->
        %CopilotSdk.UserInputResponse{answer: request.question}
      end,
      "hooks" => %{"onPreToolUse" => fn _, _ -> %{"permissionDecision" => "deny"} end}
    }

    assert {:ok, session} = Client.create_session(client, config)
    assert Session.session_id(session) == "string-config"

    assert_receive {:mock_rpc_call, "session.create",
                    %{"sessionId" => "string-config", "requestUserInput" => true, "hooks" => true}}

    for {id, method, params, expected} <- [
          {"input", "userInput.request", %{"question" => "hello"},
           %{"answer" => "hello", "wasFreeform" => false}},
          {"hook", "hooks.invoke", %{"hookType" => "preToolUse", "input" => %{}},
           %{"output" => %{"permissionDecision" => "deny"}}}
        ] do
      send(
        mock.server_pid,
        {:send_message,
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "method" => method,
           "params" => Map.put(params, "sessionId", "string-config")
         }}
      )

      assert_receive {:mock_rpc_response, %{"id" => ^id, "result" => ^expected}}, 1000
    end
  end
end
