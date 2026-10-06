defmodule CopilotSdk.SessionReliabilityTest do
  use ExUnit.Case, async: true

  import CopilotSdk.Test.Helpers

  alias CopilotSdk.{PermissionRequestResult, Session, SessionHooks, Tools, UserInputResponse}

  test "send_and_wait returns RPC errors instead of raising" do
    {:ok, session, _} =
      start_test_session(
        on_request: fn
          "session.send", _ -> {:error, %{"code" => -32000, "message" => "cannot send"}}
          _, _ -> nil
        end
      )

    assert {:error, %{message: "cannot send"}} =
             Session.send_and_wait(session, prompt: "hello")

    state = :sys.get_state(session)
    assert DynamicSupervisor.which_children(state.consumer_supervisor) == []
  end

  test "session remains responsive while a message send is pending" do
    {:ok, session, info} =
      start_test_session(
        on_request: fn
          "session.send", _ -> :no_reply
          _, _ -> nil
        end
      )

    task = Task.async(fn -> Session.send_message(session, [prompt: "hello"], timeout: 100) end)
    assert_receive {:mock_rpc_call, "session.send", %{"prompt" => "hello"}}, 1000
    assert Session.session_id(session) == info.session_id
    assert {:error, :timeout} = Task.await(task)
  end

  test "send_and_wait timeout includes the send RPC" do
    {:ok, session, _} =
      start_test_session(
        on_request: fn
          "session.send", _ -> :no_reply
          _, _ -> nil
        end
      )

    assert {:error, :timeout} = Session.send_and_wait(session, %{prompt: "hello"}, timeout: 50)
  end

  test "disconnect stops session-owned resources without restarting the session" do
    {:ok, session, _} = start_test_session()
    state = :sys.get_state(session)
    assert :ok = Session.disconnect(session)
    refute Process.alive?(session)
    refute Process.alive?(state.event_producer_pid)
    refute Process.alive?(state.consumer_supervisor)
    refute Process.alive?(state.task_supervisor)
  end

  test "permission events pass the nested permission request to the handler" do
    test_pid = self()

    handler = fn request, context ->
      send(test_pid, {:permission, request, context})
      %PermissionRequestResult{kind: :approved}
    end

    {:ok, session, info} = start_test_session(on_permission_request: handler)
    request = %{"kind" => "shell", "fullCommandText" => "pwd"}
    event = permission_requested_event()
    event = put_in(event, ["data", "permissionRequest"], request)
    Session.dispatch_event(session, event)
    assert_receive {:permission, ^request, %{session_id: session_id}}, 1000
    assert session_id == info.session_id

    assert_receive {:mock_rpc_call, "session.permissions.handlePendingPermissionRequest",
                    %{"result" => %{"kind" => "approved"}}},
                   1000
  end

  test "permission handler failures are denied and acknowledged" do
    {:ok, session, _} = start_test_session(on_permission_request: fn _, _ -> raise "broken" end)
    Session.dispatch_event(session, permission_requested_event())

    assert_receive {:mock_rpc_call, "session.permissions.handlePendingPermissionRequest",
                    %{
                      "result" => %{
                        "kind" => "denied-no-approval-rule-and-could-not-request-from-user"
                      }
                    }},
                   1000
  end

  test "permissions already resolved by hooks are not evaluated again" do
    test_pid = self()

    {:ok, session, _} =
      start_test_session(
        on_permission_request: fn _, _ ->
          send(test_pid, :unexpected_permission)
          %PermissionRequestResult{kind: :approved}
        end
      )

    event = put_in(permission_requested_event(), ["data", "resolvedByHook"], true)
    Session.dispatch_event(session, event)
    refute_receive :unexpected_permission
  end

  test "legacy request callbacks produce the protocol response envelopes" do
    tool =
      Tools.define_tool(name: "echo", description: "Echo", handler: fn args -> args["text"] end)

    config = %{
      tools: [tool],
      on_permission_request: fn _, _ -> %PermissionRequestResult{kind: :approved} end,
      on_user_input_request: fn _, _ -> %UserInputResponse{answer: "yes"} end,
      hooks: %SessionHooks{on_pre_tool_use: fn _, _ -> %{"permissionDecision" => "allow"} end}
    }

    assert %{"result" => %{"textResultForLlm" => "hello", "resultType" => "success"}} =
             Session.handle_server_request(config, "s", "tool.call", %{
               "toolName" => "echo",
               "arguments" => %{"text" => "hello"}
             })

    assert %{"result" => %{"kind" => "approved"}} =
             Session.handle_server_request(config, "s", "permission.request", %{})

    assert %{"answer" => "yes", "wasFreeform" => false} =
             Session.handle_server_request(config, "s", "userInput.request", %{
               "question" => "Continue?"
             })

    assert %{"output" => %{"permissionDecision" => "allow"}} =
             Session.handle_server_request(config, "s", "hooks.invoke", %{
               "hookType" => "preToolUse",
               "input" => %{}
             })

    assert %{} =
             Session.handle_server_request(config, "s", "hooks.invoke", %{
               "hookType" => "futureHook"
             })
  end

  test "unknown tools and missing permission handlers fail closed" do
    assert %{"result" => %{"resultType" => "failure"}} =
             Session.handle_server_request(%{}, "s", "tool.call", %{"toolName" => "missing"})

    assert %{"result" => %{"kind" => "denied-no-approval-rule-and-could-not-request-from-user"}} =
             Session.handle_server_request(%{}, "s", "permission.request", %{})
  end
end
