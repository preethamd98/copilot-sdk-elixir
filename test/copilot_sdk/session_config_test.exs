defmodule CopilotSdk.SessionConfigTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{ClientOptions, SessionConfig, SessionHooks, WireFormat}

  @hook_fields [
    {"preToolUse", :on_pre_tool_use},
    {"preMcpToolCall", :on_pre_mcp_tool_call},
    {"postToolUse", :on_post_tool_use},
    {"postToolUseFailure", :on_post_tool_use_failure},
    {"userPromptSubmitted", :on_user_prompt_submitted},
    {"userPromptTransformed", :on_user_prompt_transformed},
    {"sessionStart", :on_session_start},
    {"sessionEnd", :on_session_end},
    {"errorOccurred", :on_error_occurred},
    {"agentStop", :on_agent_stop},
    {"subagentStart", :on_subagent_start},
    {"subagentStop", :on_subagent_stop}
  ]

  test "struct, keyword and map configs serialize all added fields identically" do
    options = [
      model_capabilities: %{
        supports: %{vision: false, reasoning_effort: true},
        limits: %{
          max_prompt_tokens: 0,
          max_output_tokens: 4096,
          max_context_window_tokens: 128_000,
          vision: %{
            supported_media_types: [],
            max_prompt_images: 0,
            max_prompt_image_size: 0
          }
        }
      },
      enable_config_discovery: false,
      reasoning_summary: "none",
      context_tier: "long_context",
      additional_directories: ["/workspace/extra"],
      excluded_builtin_agents: [],
      custom_agents_local_only: false,
      default_agent: %{excluded_tools: []},
      enable_session_telemetry: false,
      enable_citations: false,
      enable_file_change_tracking: false,
      session_limits: %{max_ai_credits: 0},
      disabled_mcp_servers: [],
      plugin_directories: [],
      instruction_directories: ["/workspace/instructions"]
    ]

    expected = %{
      "sessionId" => "session-1",
      "envValueMode" => "direct",
      "requestPermission" => false,
      "requestUserInput" => false,
      "hooks" => false,
      "modelCapabilities" => %{
        "supports" => %{"vision" => false, "reasoningEffort" => true},
        "limits" => %{
          "max_prompt_tokens" => 0,
          "max_output_tokens" => 4096,
          "max_context_window_tokens" => 128_000,
          "vision" => %{
            "supported_media_types" => [],
            "max_prompt_images" => 0,
            "max_prompt_image_size" => 0
          }
        }
      },
      "enableConfigDiscovery" => false,
      "reasoningSummary" => "none",
      "contextTier" => "long_context",
      "additionalDirectories" => ["/workspace/extra"],
      "excludedBuiltinAgents" => [],
      "customAgentsLocalOnly" => false,
      "defaultAgent" => %{"excludedTools" => []},
      "enableSessionTelemetry" => false,
      "enableCitations" => false,
      "enableFileChangeTracking" => false,
      "sessionLimits" => %{"maxAiCredits" => 0},
      "disabledMcpServers" => [],
      "pluginDirectories" => [],
      "instructionDirectories" => ["/workspace/instructions"]
    }

    for config <- [options, Map.new(options), struct!(SessionConfig, options), expected] do
      assert WireFormat.build_session_payload(config, "session-1") == expected
    end
  end

  test "unset optional fields are omitted from a SessionConfig struct" do
    assert WireFormat.build_session_payload(%SessionConfig{}, "session-1") == %{
             "sessionId" => "session-1",
             "envValueMode" => "direct",
             "requestPermission" => false,
             "requestUserInput" => false,
             "hooks" => false
           }
  end

  test "resume-only options serialize for resume but never for create" do
    for value <- [true, false] do
      options = [
        model: "gpt-5",
        suppress_resume_event: value,
        continue_pending_work: value,
        allow_transcript_recovery: value
      ]

      camel_config = %{
        "model" => "gpt-5",
        "suppressResumeEvent" => value,
        "continuePendingWork" => value,
        "allowTranscriptRecovery" => value
      }

      for config <- [options, Map.new(options), struct!(SessionConfig, options), camel_config] do
        create_payload = WireFormat.build_session_payload(config, "session-1")

        assert create_payload["model"] == "gpt-5"
        refute Map.has_key?(create_payload, "disableResume")
        refute Map.has_key?(create_payload, "suppressResumeEvent")
        refute Map.has_key?(create_payload, "continuePendingWork")
        refute Map.has_key?(create_payload, "allowTranscriptRecovery")

        assert WireFormat.build_resume_payload(config, "session-1") ==
                 Map.merge(create_payload, %{
                   "disableResume" => value,
                   "continuePendingWork" => value,
                   "allowTranscriptRecovery" => value
                 })
      end
    end
  end

  test "resume-only defaults are omitted" do
    config = %SessionConfig{}

    assert WireFormat.build_resume_payload(config, "id") ==
             WireFormat.build_session_payload(config, "id")
  end

  test "ClientOptions supports an optional connection token" do
    assert ClientOptions.new().connection_token == nil

    options =
      ClientOptions.new(
        cli_url: "localhost:3000",
        use_stdio: false,
        connection_token: "shared-test-token"
      )

    assert options.connection_token == "shared-test-token"
  end

  test "managed settings support atom and upstream keys for create and resume" do
    rules = ["Read(**)", "Shell(git push *)"]

    options = [
      enable_managed_settings: false,
      managed_settings: %{
        permissions: %{
          disable_bypass_permissions_mode: "disable",
          allow: [],
          ask: rules,
          deny: ["Write(important_file)"]
        }
      }
    ]

    wire_config = %{
      "enableManagedSettings" => false,
      "managedSettings" => %{
        "permissions" => %{
          "disableBypassPermissionsMode" => "disable",
          "allow" => [],
          "ask" => rules,
          "deny" => ["Write(important_file)"]
        }
      }
    }

    for config <- [options, Map.new(options), struct!(SessionConfig, options), wire_config],
        build <- [&WireFormat.build_session_payload/2, &WireFormat.build_resume_payload/2] do
      payload = build.(config, "id")
      assert payload["enableManagedSettings"] == false
      assert payload["managedSettings"] == wire_config["managedSettings"]
    end
  end

  test "empty managed settings remain explicit and unset settings are omitted" do
    for settings <- [%{}, %{permissions: %{}}] do
      payload =
        WireFormat.build_session_payload(
          %SessionConfig{enable_managed_settings: true, managed_settings: settings},
          "id"
        )

      assert payload["enableManagedSettings"] == true
      assert Map.has_key?(payload, "managedSettings")
    end

    payload = WireFormat.build_session_payload(%SessionConfig{}, "id")
    refute Map.has_key?(payload, "enableManagedSettings")
    refute Map.has_key?(payload, "managedSettings")
  end

  test "unknown policy keys and values reach the runtime for fail-closed validation" do
    settings = %{
      "unknown_restriction" => true,
      "permissions" => %{
        "disableBypassPermissionsMode" => "future-policy-value",
        "unknown_rule" => ["Deny(secret_file)"]
      }
    }

    payload = WireFormat.build_session_payload(%{managed_settings: settings}, "id")
    assert payload["managedSettings"] == settings
  end

  test "empty collections and false values remain explicit" do
    config = %SessionConfig{
      streaming: false,
      tools: [],
      available_tools: [],
      excluded_tools: [],
      mcp_servers: %{},
      custom_agents: [],
      default_agent: %{},
      model_capabilities: %{},
      session_limits: %{},
      infinite_sessions: %{enabled: false},
      skill_directories: [],
      disabled_skills: []
    }

    payload = WireFormat.build_session_payload(config, "id")
    assert payload["streaming"] == false
    assert payload["tools"] == []
    assert payload["availableTools"] == []
    assert payload["excludedTools"] == []
    assert payload["mcpServers"] == %{}
    assert payload["customAgents"] == []
    assert payload["defaultAgent"] == %{}
    assert payload["modelCapabilities"] == %{}
    assert payload["sessionLimits"] == %{}
    assert payload["infiniteSessions"] == %{"enabled" => false}
    assert payload["skillDirectories"] == []
    assert payload["disabledSkills"] == []
  end

  test "callbacks remain local while registration flags are JSON booleans" do
    handler = fn _, _ -> nil end

    config = %SessionConfig{
      on_permission_request: handler,
      on_user_input_request: handler,
      on_event: fn _ -> nil end,
      hooks: %SessionHooks{on_pre_mcp_tool_call: handler}
    }

    payload = WireFormat.build_session_payload(config, "id")

    assert payload == %{
             "sessionId" => "id",
             "envValueMode" => "direct",
             "requestPermission" => true,
             "requestUserInput" => true,
             "hooks" => true
           }

    assert WireFormat.build_session_payload(
             %{
               "onPermissionRequest" => handler,
               "onUserInputRequest" => handler,
               "onEvent" => fn _ -> nil end,
               "hooks" => %{"onPreMcpToolCall" => handler}
             },
             "id"
           ) == payload
  end

  test "empty hooks do not register a hook callback" do
    for hooks <- [nil, false, %SessionHooks{}, %{}, [], %{on_agent_stop: nil}] do
      assert WireFormat.build_session_payload(%{hooks: hooks}, "id")["hooks"] == false
    end
  end

  for {wire_name, field} <- @hook_fields do
    test "#{wire_name} dispatches to #{field} with the input and context" do
      handler = fn input, context -> {input, context} end
      input = %{"test" => "input"}
      context = %{session_id: "id"}

      for hooks <- [
            struct!(SessionHooks, [{unquote(field), handler}]),
            %{unquote(field) => handler},
            [{unquote(field), handler}]
          ] do
        assert SessionHooks.dispatch(hooks, unquote(wire_name), input, context) ==
                 {input, context}

        assert WireFormat.build_session_payload(%{hooks: hooks}, "id")["hooks"] == true
      end
    end
  end

  test "camelCase hook maps dispatch without serializing callbacks" do
    hooks = %{"onSubagentStop" => fn input, context -> {input, context} end}
    assert SessionHooks.dispatch(hooks, "subagentStop", :input, :context) == {:input, :context}
    assert WireFormat.build_session_payload(%{hooks: hooks}, "id")["hooks"] == true
  end

  test "unknown, unset and invalid hooks are ignored" do
    assert SessionHooks.dispatch(nil, "agentStop", %{}, %{}) == nil
    assert SessionHooks.dispatch(%SessionHooks{}, "unknown", %{}, %{}) == nil
    assert SessionHooks.dispatch(%SessionHooks{}, "agentStop", %{}, %{}) == nil
    assert SessionHooks.dispatch(%{on_agent_stop: :invalid}, "agentStop", %{}, %{}) == nil
  end
end
