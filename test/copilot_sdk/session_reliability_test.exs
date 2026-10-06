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
                    %{"result" => %{"kind" => "approve-once"}}},
                   1000
  end

  test "permission handler failures are denied and acknowledged" do
    {:ok, session, _} = start_test_session(on_permission_request: fn _, _ -> raise "broken" end)
    Session.dispatch_event(session, permission_requested_event())

    assert_receive {:mock_rpc_call, "session.permissions.handlePendingPermissionRequest",
                    %{
                      "result" => %{
                        "kind" => "user-not-available"
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

    assert %{"result" => %{"kind" => "approve-once"}} =
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

    assert %{"result" => %{"kind" => "user-not-available"}} =
             Session.handle_server_request(%{}, "s", "permission.request", %{})
  end

  test "send_and_wait ignores subagent messages and autopilot idle events" do
    {:ok, session, _} = start_test_session()
    task = Task.async(fn -> Session.send_and_wait(session, %{prompt: "hello"}, timeout: 2000) end)
    assert_receive {:mock_rpc_call, "session.send", _}, 1000

    Session.dispatch_event(session, Map.put(assistant_message_event("child"), "agentId", "child"))
    Session.dispatch_event(session, Map.put(idle_event(), "agentId", "child"))
    Session.dispatch_event(session, put_in(idle_event(), ["data", "mode"], "autopilot"))
    Session.dispatch_event(session, assistant_message_event("root"))
    Session.dispatch_event(session, idle_event())
    assert {:ok, %{data: %{"content" => "root"}, agent_id: nil}} = Task.await(task)
  end

  test "message metadata and response schemas are sent with upstream names" do
    {:ok, session, _} = start_test_session()
    schema = %{"type" => "object", "properties" => %{"raw_key" => %{"type" => "string"}}}

    assert {:ok, _} =
             Session.send_message(session,
               prompt: "hello",
               source: "app",
               display_prompt: "display",
               agent_mode: "plan",
               response_schema: schema,
               request_headers: %{"x-custom-header" => "value"}
             )

    assert_receive {:mock_rpc_call, "session.send",
                    %{
                      "source" => "app",
                      "displayPrompt" => "display",
                      "agentMode" => "plan",
                      "requestHeaders" => %{"x-custom-header" => "value"},
                      "responseFormat" => %{
                        "type" => "json_schema",
                        "jsonSchema" => %{
                          "name" => "response",
                          "strict" => true,
                          "schema" => ^schema
                        }
                      }
                    }}
  end

  test "managed approve_all abstains rather than bypassing policy" do
    assert %{kind: :no_result} =
             CopilotSdk.PermissionHandler.approve_all(%{}, %{managed_settings_enabled: true})
  end

  test "model switching normalizes Elixir options and supports clearing reasoning effort" do
    {:ok, session, _} = start_test_session()

    assert :ok =
             Session.set_model(session, "test-model",
               reasoning_effort: "high",
               context_tier: "long_context"
             )

    assert_receive {:mock_rpc_call, "session.model.switchTo",
                    %{
                      "modelId" => "test-model",
                      "reasoningEffort" => "high",
                      "contextTier" => "long_context"
                    }}

    assert :ok = Session.set_model(session, "test-model", reasoning_effort: nil)

    assert_receive {:mock_rpc_call, "session.model.switchTo",
                    %{"modelId" => "test-model", "reasoningEffort" => nil}}
  end
end
