defmodule CopilotSdk.Generated.RpcTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.Generated.{ServerRpc, SessionRpc}
  alias CopilotSdk.JsonRpc.Client
  alias CopilotSdk.Test.Helpers

  @server_contracts [
    {:ping, [], "ping", %{}},
    {:get_status, [], "status.get", %{}},
    {:get_auth_status, [], "auth.getStatus", %{}},
    {:get_quota, [], "account.getQuota", %{}},
    {:get_quota, [%{"selectionId" => "account-1"}], "account.getQuota",
     %{"selectionId" => "account-1"}},
    {:list_tools, [], "tools.list", %{}},
    {:list_tools, [%{"model" => "test-model"}], "tools.list", %{"model" => "test-model"}},
    {:list_models, [], "models.list", %{}},
    {:list_sessions, [], "session.list", %{}},
    {:list_sessions, [%{"cwd" => "/workspace", "branch" => "main"}], "session.list",
     %{"filter" => %{"cwd" => "/workspace", "branch" => "main"}}},
    {:get_last_session_id, [], "session.getLastId", %{}},
    {:get_foreground_session_id, [], "session.getForeground", %{}},
    {:set_foreground_session_id, ["foreground-session"], "session.setForeground",
     %{"sessionId" => "foreground-session"}}
  ]

  @session_contracts [
    {:log, ["hello"], "session.log", %{"message" => "hello"}},
    {:log, ["hello", %{level: "info", ephemeral: false}], "session.log",
     %{"message" => "hello", "level" => "info", "ephemeral" => false}},
    {:send_message, [%{"prompt" => "hello"}], "session.send", %{"prompt" => "hello"}},
    {:abort, [], "session.abort", %{}},
    {:detach, [], "session.detach", %{}},
    {:destroy, [], "session.destroy", %{}},
    {:get_messages, [], "session.getMessages", %{}},
    {:switch_model, ["test-model"], "session.model.switchTo", %{"modelId" => "test-model"}},
    {:get_current_model, [], "session.model.getCurrent", %{}},
    {:set_tools, [[%{"name" => "lookup", "description" => "Look up a value"}]],
     "session.tools.set",
     %{"tools" => [%{"name" => "lookup", "description" => "Look up a value"}]}},
    {:set_tools, [[]], "session.tools.set", %{"tools" => []}},
    {:get_mode, [], "session.mode.get", %{}},
    {:set_mode, ["plan"], "session.mode.set", %{"mode" => "plan"}},
    {:set_mode, ["interactive", %{"expectedMode" => "plan", "restorePlanModel" => false}],
     "session.mode.set",
     %{"mode" => "interactive", "expectedMode" => "plan", "restorePlanModel" => false}},
    {:read_plan, [], "session.plan.read", %{}},
    {:update_plan, ["# Plan\n\nTest the changes."], "session.plan.update",
     %{"content" => "# Plan\n\nTest the changes."}},
    {:delete_plan, [], "session.plan.delete", %{}},
    {:list_agents, [], "session.agent.list", %{}},
    {:list_agents, [%{"includeBuiltInAgents" => true, "includePrompt" => false}],
     "session.agent.list", %{"includeBuiltInAgents" => true, "includePrompt" => false}},
    {:get_current_agent, [], "session.agent.getCurrent", %{}},
    {:select_agent, ["reviewer"], "session.agent.select", %{"name" => "reviewer"}},
    {:deselect_agent, [], "session.agent.deselect", %{}},
    {:compact, [], "session.history.compact", %{}},
    {:compact,
     [%{"customInstructions" => "Keep decisions", "trigger" => "manual", "tokenLimit" => 8000}],
     "session.history.compact",
     %{"customInstructions" => "Keep decisions", "trigger" => "manual", "tokenLimit" => 8000}},
    {:list_skills, [], "session.skills.list", %{}},
    {:handle_tool_result, ["tool-request", %{"textResultForLlm" => "done"}],
     "session.tools.handlePendingToolCall",
     %{"requestId" => "tool-request", "result" => %{"textResultForLlm" => "done"}}},
    {:handle_permission_result, ["permission-request", %{"kind" => "approved"}],
     "session.permissions.handlePendingPermissionRequest",
     %{"requestId" => "permission-request", "result" => %{"kind" => "approved"}}},
    {:handle_user_input_result, ["input-request", %{"answer" => "yes", "wasFreeform" => false}],
     "session.userInput.handlePendingUserInputRequest",
     %{
       "requestId" => "input-request",
       "response" => %{"answer" => "yes", "wasFreeform" => false}
     }},
    {:handle_hooks_result, ["hook-request", %{"continue" => true}],
     "session.hooks.handlePendingHookInvocation",
     %{"requestId" => "hook-request", "result" => %{"continue" => true}}}
  ]

  setup do
    response = %{"unchanged" => [%{"value" => 42}]}
    {client, _mock} = Helpers.start_test_client(on_request: fn _, _ -> response end)
    on_exit(fn -> Client.stop(client) end)

    %{
      server_rpc: ServerRpc.new(client),
      session_rpc: SessionRpc.new(client, "bound-session"),
      response: response
    }
  end

  describe "server wire contracts" do
    for {{function, args, method, params}, index} <- Enum.with_index(@server_contracts) do
      test "#{function} uses the exact server contract (#{index})", context do
        assert {:ok, context.response} ==
                 apply(ServerRpc, unquote(function), [
                   context.server_rpc | unquote(Macro.escape(args))
                 ])

        expected = unquote(Macro.escape(params))
        assert_receive {:mock_rpc_call, unquote(method), ^expected}, 1000
      end
    end
  end

  describe "session wire contracts" do
    for {{function, args, method, params}, index} <- Enum.with_index(@session_contracts) do
      test "#{function} uses the exact session contract (#{index})", context do
        assert {:ok, context.response} ==
                 apply(SessionRpc, unquote(function), [
                   context.session_rpc | unquote(Macro.escape(args))
                 ])

        expected = Map.put(unquote(Macro.escape(params)), "sessionId", "bound-session")
        assert_receive {:mock_rpc_call, unquote(method), ^expected}, 1000
      end
    end
  end

  test "switch_model forwards model settings without allowing model or session ID overrides",
       context do
    options = %{
      "modelId" => "ignored-model",
      "sessionId" => "ignored-session",
      "reasoningEffort" => "high",
      "reasoningSummary" => "detailed",
      "contextTier" => "long_context",
      "modelCapabilities" => %{"supports" => %{"vision" => false}}
    }

    assert {:ok, context.response} ==
             SessionRpc.switch_model(context.session_rpc, "test-model", options)

    expected = %{options | "modelId" => "test-model", "sessionId" => "bound-session"}
    assert_receive {:mock_rpc_call, "session.model.switchTo", ^expected}, 1000
  end

  test "switch_model preserves an explicit nil reasoning effort", context do
    assert {:ok, context.response} ==
             SessionRpc.switch_model(context.session_rpc, "test-model", %{
               "reasoningEffort" => nil
             })

    expected = %{
      "sessionId" => "bound-session",
      "modelId" => "test-model",
      "reasoningEffort" => nil
    }

    assert_receive {:mock_rpc_call, "session.model.switchTo", ^expected}, 1000
  end

  test "map-taking session wrappers inject the bound session ID last", context do
    for {function, args, method, params} <- [
          {:send_message, [%{"prompt" => "hello", "sessionId" => "wrong"}], "session.send",
           %{"prompt" => "hello"}},
          {:set_mode, ["plan", %{"sessionId" => "wrong", "mode" => "interactive"}],
           "session.mode.set", %{"mode" => "plan"}},
          {:list_agents, [%{"sessionId" => "wrong"}], "session.agent.list", %{}},
          {:compact, [%{"sessionId" => "wrong"}], "session.history.compact", %{}}
        ] do
      assert {:ok, context.response} == apply(SessionRpc, function, [context.session_rpc | args])
      expected = Map.put(params, "sessionId", "bound-session")
      assert_receive {:mock_rpc_call, ^method, ^expected}, 1000
    end
  end

  test "every wrapper returns RPC errors unchanged without retrying or falling back" do
    wire_error = %{
      "code" => -32601,
      "message" => "Method not found",
      "data" => %{"detail" => "test"}
    }

    expected_error = %{code: -32601, message: "Method not found", data: %{"detail" => "test"}}
    {client, _mock} = Helpers.start_test_client(on_request: fn _, _ -> {:error, wire_error} end)
    on_exit(fn -> Client.stop(client) end)

    for {module, rpc, contracts} <- [
          {ServerRpc, ServerRpc.new(client), @server_contracts},
          {SessionRpc, SessionRpc.new(client, "bound-session"), @session_contracts}
        ],
        {function, args, method, params} <- contracts do
      assert {:error, expected_error} == apply(module, function, [rpc | args])

      expected =
        if module == SessionRpc, do: Map.put(params, "sessionId", "bound-session"), else: params

      assert_receive {:mock_rpc_call, ^method, ^expected}, 1000
    end

    refute_receive {:mock_rpc_call, _, _}
  end

  test "server wrappers forward request timeouts separately from wire parameters" do
    {client, _mock} = Helpers.start_test_client(on_request: fn _, _ -> :no_reply end)
    on_exit(fn -> Client.stop(client) end)
    rpc = ServerRpc.new(client)

    for {function, args, method, params} <- [
          {:ping, [%{}, [timeout: 10]], "ping", %{}},
          {:get_status, [[timeout: 10]], "status.get", %{}},
          {:get_auth_status, [[timeout: 10]], "auth.getStatus", %{}},
          {:get_quota, [%{}, [timeout: 10]], "account.getQuota", %{}},
          {:list_tools, [%{}, [timeout: 10]], "tools.list", %{}},
          {:list_models, [[timeout: 10]], "models.list", %{}},
          {:list_sessions, [nil, [timeout: 10]], "session.list", %{}},
          {:get_last_session_id, [[timeout: 10]], "session.getLastId", %{}},
          {:get_foreground_session_id, [[timeout: 10]], "session.getForeground", %{}},
          {:set_foreground_session_id, ["other", [timeout: 10]], "session.setForeground",
           %{"sessionId" => "other"}}
        ] do
      assert {:error, :timeout} = apply(ServerRpc, function, [rpc | args])
      assert_receive {:mock_rpc_call, ^method, ^params}, 1000
    end
  end
end
