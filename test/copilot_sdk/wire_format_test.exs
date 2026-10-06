defmodule CopilotSdk.WireFormatTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{PermissionRequestResult, WireFormat}

  test "permission results support current decision kinds and compatibility aliases" do
    kinds = [
      approve_once: "approve-once",
      approved: "approve-once",
      approve_for_session: "approve-for-session",
      approve_read_only_for_session: "approve-read-only-for-session",
      approve_for_location: "approve-for-location",
      approve_permanently: "approve-permanently",
      reject: "reject",
      deny: "reject",
      user_not_available: "user-not-available",
      no_result: "no-result",
      approved_for_session: "approved-for-session",
      approved_for_location: "approved-for-location",
      cancelled: "cancelled",
      denied_by_rules: "denied-by-rules",
      denied_by_content_exclusion_policy: "denied-by-content-exclusion-policy",
      denied_could_not_request_from_user:
        "denied-no-approval-rule-and-could-not-request-from-user",
      denied_interactively_by_user: "denied-interactively-by-user",
      denied_by_permission_request_hook: "denied-by-permission-request-hook"
    ]

    for {kind, wire_kind} <- kinds do
      assert PermissionRequestResult.to_wire_kind(kind) == wire_kind

      assert PermissionRequestResult.to_wire(%PermissionRequestResult{kind: kind}) == %{
               "kind" => wire_kind
             }
    end
  end

  test "permission results preserve false decision flags and scoped approval data" do
    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :approve_once,
             approved_interactively: false
           }) == %{"kind" => "approve-once", "approvedInteractively" => false}

    approval = %{"kind" => "commands", "commandIdentifiers" => ["echo"]}

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :approve_for_location,
             approval: approval,
             location_key: "/workspace"
           }) == %{
             "kind" => "approve-for-location",
             "approval" => approval,
             "locationKey" => "/workspace"
           }

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :approve_read_only_for_session,
             directories: ["/workspace"]
           }) == %{
             "kind" => "approve-read-only-for-session",
             "directories" => ["/workspace"]
           }

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :approve_permanently,
             domain: "example.invalid"
           }) == %{"kind" => "approve-permanently", "domain" => "example.invalid"}
  end

  test "permission denials retain feedback, hook interruption and cancellation reasons" do
    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :deny,
             feedback: ""
           }) == %{"kind" => "reject", "feedback" => ""}

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :denied_interactively_by_user,
             force_reject: false
           }) == %{"kind" => "denied-interactively-by-user", "forceReject" => false}

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :denied_by_permission_request_hook,
             interrupt: false,
             message: "Denied"
           }) == %{
             "kind" => "denied-by-permission-request-hook",
             "interrupt" => false,
             "message" => "Denied"
           }

    assert PermissionRequestResult.to_wire(%PermissionRequestResult{
             kind: :cancelled,
             reason: "Stopped"
           }) == %{"kind" => "cancelled", "reason" => "Stopped"}
  end

  test "default and unknown permission kinds remain fail-closed" do
    denied = "user-not-available"
    assert PermissionRequestResult.to_wire(%PermissionRequestResult{}) == %{"kind" => denied}
    assert PermissionRequestResult.to_wire_kind(:unknown) == denied
  end

  test "provider config converts snake_case to camelCase" do
    wire =
      WireFormat.provider_to_wire(%{
        type: "openai",
        base_url: "https://api.openai.com",
        api_key: "sk-test"
      })

    assert wire["baseUrl"] == "https://api.openai.com"
    assert wire["apiKey"] == "sk-test"
    assert wire["type"] == "openai"
    refute Map.has_key?(wire, "base_url")
  end

  test "provider_to_wire handles nil" do
    assert WireFormat.provider_to_wire(nil) == nil
  end

  test "custom agent config converts to camelCase" do
    wire =
      WireFormat.custom_agent_to_wire(%{
        name: "reviewer",
        prompt: "Review code",
        display_name: "Code Reviewer"
      })

    assert wire["displayName"] == "Code Reviewer"
    assert wire["name"] == "reviewer"
    assert wire["prompt"] == "Review code"
    refute Map.has_key?(wire, "display_name")
  end

  test "infinite session config converts to camelCase" do
    wire =
      WireFormat.infinite_sessions_to_wire(%{
        enabled: true,
        background_compaction_threshold: 0.8,
        buffer_exhaustion_threshold: 0.95
      })

    assert wire["enabled"] == true
    assert wire["backgroundCompactionThreshold"] == 0.8
    assert wire["bufferExhaustionThreshold"] == 0.95
    refute Map.has_key?(wire, "background_compaction_threshold")
  end

  test "infinite_sessions_to_wire handles nil" do
    assert WireFormat.infinite_sessions_to_wire(nil) == nil
  end

  test "session payload includes envValueMode when mcp_servers present" do
    payload =
      WireFormat.build_session_payload(
        %{
          on_permission_request: &CopilotSdk.PermissionHandler.approve_all/2,
          mcp_servers: %{"test" => %{command: "echo", args: []}}
        },
        "session-1"
      )

    assert payload["envValueMode"] == "direct"
    assert payload["mcpServers"] == %{"test" => %{"command" => "echo", "args" => []}}
  end

  test "session payload includes direct envValueMode without mcp_servers" do
    payload =
      WireFormat.build_session_payload(
        %{
          on_permission_request: &CopilotSdk.PermissionHandler.approve_all/2
        },
        "session-1"
      )

    assert payload["envValueMode"] == "direct"
    refute Map.has_key?(payload, "mcpServers")
  end

  test "session payload includes sessionId" do
    payload = WireFormat.build_session_payload(%{}, "my-session-id")
    assert payload["sessionId"] == "my-session-id"
  end

  test "session payload includes model and reasoning effort" do
    payload =
      WireFormat.build_session_payload(
        %{model: "gpt-4", reasoning_effort: "high"},
        "session-1"
      )

    assert payload["model"] == "gpt-4"
    assert payload["reasoningEffort"] == "high"
  end

  test "session payload includes requestPermission" do
    payload =
      WireFormat.build_session_payload(
        %{on_permission_request: fn _, _ -> nil end},
        "session-1"
      )

    assert payload["requestPermission"] == true
    refute Map.has_key?(payload, "acceptsPermissionRequests")
  end

  test "session payload includes requestUserInput" do
    payload =
      WireFormat.build_session_payload(
        %{on_user_input_request: fn _, _ -> nil end},
        "session-1"
      )

    assert payload["requestUserInput"] == true
    refute Map.has_key?(payload, "acceptsUserInputRequests")
  end

  test "session payload includes a boolean hooks flag" do
    hooks = %CopilotSdk.SessionHooks{
      on_pre_tool_use: fn _, _ -> nil end,
      on_session_start: fn _, _ -> nil end
    }

    payload =
      WireFormat.build_session_payload(
        %{hooks: hooks},
        "session-1"
      )

    assert payload["hooks"] == true
  end

  test "session payload includes custom agents" do
    payload =
      WireFormat.build_session_payload(
        %{
          custom_agents: [
            %{name: "agent1", prompt: "Do stuff", display_name: "Agent 1"}
          ]
        },
        "session-1"
      )

    assert length(payload["customAgents"]) == 1
    assert hd(payload["customAgents"])["displayName"] == "Agent 1"
  end

  test "session payload includes tool definitions" do
    tool =
      CopilotSdk.Tools.define_tool(
        name: "my_tool",
        description: "My tool",
        parameters: %{"type" => "object"},
        handler: fn _, _ -> "ok" end
      )

    payload =
      WireFormat.build_session_payload(
        %{tools: [tool]},
        "session-1"
      )

    assert length(payload["tools"]) == 1
    assert hd(payload["tools"])["name"] == "my_tool"
    assert hd(payload["tools"])["parameters"] == %{"type" => "object"}
    refute Map.has_key?(hd(payload["tools"]), "inputSchema")
  end

  test "session payload includes infinite sessions config" do
    payload =
      WireFormat.build_session_payload(
        %{infinite_sessions: %{enabled: true, background_compaction_threshold: 0.8}},
        "session-1"
      )

    assert payload["infiniteSessions"]["enabled"] == true
    assert payload["infiniteSessions"]["backgroundCompactionThreshold"] == 0.8
  end

  test "provider supports atom or camelCase keys without changing header names" do
    headers = %{"X_Custom_Header" => "value", "api_key" => "header-value"}

    expected = %{
      "type" => "azure",
      "baseUrl" => "https://example.invalid",
      "wireApi" => "responses",
      "azure" => %{"apiVersion" => "2024-10-21"},
      "headers" => headers
    }

    assert WireFormat.provider_to_wire(expected) == expected

    assert WireFormat.provider_to_wire(%{
             type: "azure",
             base_url: "https://example.invalid",
             wire_api: "responses",
             azure: %{api_version: "2024-10-21"},
             headers: headers
           }) == expected
  end

  test "custom agents retain model, false infer, empty tools and nested MCP config" do
    expected = %{
      "name" => "reviewer",
      "prompt" => "Review code",
      "displayName" => "Code Reviewer",
      "model" => "claude-haiku-4.5",
      "infer" => false,
      "tools" => [],
      "mcpServers" => %{
        "server_name" => %{
          "command" => "echo",
          "cwd" => "/workspace",
          "env" => %{"MY_ENV_VAR" => "value"},
          "tools" => []
        }
      }
    }

    assert WireFormat.custom_agent_to_wire(expected) == expected

    assert WireFormat.custom_agent_to_wire(%{
             name: "reviewer",
             prompt: "Review code",
             display_name: "Code Reviewer",
             model: "claude-haiku-4.5",
             infer: false,
             tools: [],
             mcp_servers: %{
               "server_name" => %{
                 command: "echo",
                 working_directory: "/workspace",
                 env: %{"MY_ENV_VAR" => "value"},
                 tools: []
               }
             }
           }) == expected
  end

  test "MCP config converts known fields without changing names, environment or headers" do
    env = %{"MY_API_KEY" => "test-value", "working_directory" => "/not-a-config-key"}
    headers = %{"X_Custom_Header" => "value", "base_url" => "header-value"}

    expected = %{
      "my_server" => %{
        "command" => "echo",
        "args" => [],
        "cwd" => "/workspace",
        "env" => env,
        "timeout" => 0
      },
      "remote_server" => %{
        "type" => "http",
        "url" => "https://example.invalid/mcp",
        "headers" => headers,
        "tools" => []
      }
    }

    servers = %{
      "my_server" => %{
        command: "echo",
        args: [],
        working_directory: "/workspace",
        env: env,
        timeout: 0
      },
      "remote_server" => %{
        type: "http",
        url: "https://example.invalid/mcp",
        headers: headers,
        tools: []
      }
    }

    assert WireFormat.build_session_payload(%{mcp_servers: servers}, "id")["mcpServers"] ==
             expected

    assert WireFormat.build_session_payload(%{"mcpServers" => expected}, "id")["mcpServers"] ==
             expected
  end

  test "infinite session camelCase maps preserve false and zero thresholds" do
    config = %{
      "enabled" => false,
      "backgroundCompactionThreshold" => 0,
      "bufferExhaustionThreshold" => 0
    }

    assert WireFormat.infinite_sessions_to_wire(config) == config
  end

  test "MCP working directories use cwd and accept both canonical and legacy input keys" do
    for server <- [
          %{cwd: "/workspace"},
          %{"cwd" => "/workspace"},
          %{working_directory: "/workspace"},
          %{"workingDirectory" => "/workspace"},
          %{"cwd" => "/workspace", "workingDirectory" => "/ignored"}
        ] do
      payload = WireFormat.build_session_payload(%{mcp_servers: %{"server" => server}}, "id")
      assert payload["mcpServers"]["server"] == %{"cwd" => "/workspace"}
    end
  end
end
