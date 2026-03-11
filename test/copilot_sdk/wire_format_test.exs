defmodule CopilotSdk.WireFormatTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.WireFormat

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
    assert payload["mcpServers"] == %{"test" => %{command: "echo", args: []}}
  end

  test "session payload omits envValueMode when no mcp_servers" do
    payload =
      WireFormat.build_session_payload(
        %{
          on_permission_request: &CopilotSdk.PermissionHandler.approve_all/2
        },
        "session-1"
      )

    refute Map.has_key?(payload, "envValueMode")
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

  test "session payload includes acceptsPermissionRequests" do
    payload =
      WireFormat.build_session_payload(
        %{on_permission_request: fn _, _ -> nil end},
        "session-1"
      )

    assert payload["acceptsPermissionRequests"] == true
  end

  test "session payload includes acceptsUserInputRequests" do
    payload =
      WireFormat.build_session_payload(
        %{on_user_input_request: fn _, _ -> nil end},
        "session-1"
      )

    assert payload["acceptsUserInputRequests"] == true
  end

  test "session payload includes hooks list" do
    hooks = %CopilotSdk.SessionHooks{
      on_pre_tool_use: fn _, _ -> nil end,
      on_session_start: fn _, _ -> nil end
    }

    payload =
      WireFormat.build_session_payload(
        %{hooks: hooks},
        "session-1"
      )

    assert "preToolUse" in payload["hooks"]
    assert "sessionStart" in payload["hooks"]
    refute "postToolUse" in payload["hooks"]
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
end
