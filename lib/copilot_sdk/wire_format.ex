defmodule CopilotSdk.WireFormat do
  @moduledoc "Conversion utilities for snake_case Elixir data to camelCase wire format."

  @doc "Convert provider config to camelCase wire format."
  @spec provider_to_wire(map() | nil) :: map() | nil
  def provider_to_wire(nil), do: nil

  def provider_to_wire(config) when is_map(config) do
    %{}
    |> maybe_put("type", config[:type])
    |> maybe_put("baseUrl", config[:base_url])
    |> maybe_put("apiKey", config[:api_key])
    |> maybe_put("wireApi", config[:wire_api])
    |> maybe_put("bearerToken", config[:bearer_token])
    |> maybe_put("azure", config[:azure])
  end

  @doc "Convert custom agent config to camelCase wire format."
  @spec custom_agent_to_wire(map()) :: map()
  def custom_agent_to_wire(agent) when is_map(agent) do
    %{"name" => agent[:name], "prompt" => agent[:prompt]}
    |> maybe_put("displayName", agent[:display_name])
    |> maybe_put("description", agent[:description])
    |> maybe_put("tools", agent[:tools])
    |> maybe_put("mcpServers", agent[:mcp_servers])
    |> maybe_put("infer", agent[:infer])
  end

  @doc "Convert infinite session config to camelCase wire format."
  @spec infinite_sessions_to_wire(map() | nil) :: map() | nil
  def infinite_sessions_to_wire(nil), do: nil

  def infinite_sessions_to_wire(config) when is_map(config) do
    %{}
    |> maybe_put("enabled", config[:enabled])
    |> maybe_put("backgroundCompactionThreshold", config[:background_compaction_threshold])
    |> maybe_put("bufferExhaustionThreshold", config[:buffer_exhaustion_threshold])
  end

  @doc "Convert system message config to wire format."
  @spec system_message_to_wire(map() | nil) :: map() | nil
  def system_message_to_wire(nil), do: nil

  def system_message_to_wire(config) when is_map(config) do
    config
  end

  @doc "Build session create/resume payload from config."
  @spec build_session_payload(map() | keyword(), String.t()) :: map()
  def build_session_payload(config, session_id) do
    payload =
      %{"sessionId" => session_id}
      |> maybe_put("clientName", config[:client_name])
      |> maybe_put("model", config[:model])
      |> maybe_put("reasoningEffort", config[:reasoning_effort])
      |> maybe_put("systemMessage", system_message_to_wire(config[:system_message]))
      |> maybe_put("availableTools", config[:available_tools])
      |> maybe_put("excludedTools", config[:excluded_tools])
      |> maybe_put("workingDirectory", config[:working_directory])
      |> maybe_put("provider", provider_to_wire(config[:provider]))
      |> maybe_put("streaming", config[:streaming])
      |> maybe_put("agent", config[:agent])
      |> maybe_put("configDir", config[:config_dir])
      |> maybe_put("skillDirectories", config[:skill_directories])
      |> maybe_put("disabledSkills", config[:disabled_skills])
      |> maybe_put("infiniteSessions", infinite_sessions_to_wire(config[:infinite_sessions]))

    # Add tools
    payload =
      case config[:tools] do
        nil ->
          payload

        tools when is_list(tools) ->
          tool_defs = Enum.map(tools, &CopilotSdk.Tools.to_wire/1)
          Map.put(payload, "tools", tool_defs)
      end

    # Add MCP servers
    payload =
      case config[:mcp_servers] do
        nil ->
          payload

        servers when is_map(servers) ->
          payload
          |> Map.put("mcpServers", servers)
          |> Map.put("envValueMode", "direct")
      end

    # Add custom agents
    payload =
      case config[:custom_agents] do
        nil ->
          payload

        agents when is_list(agents) ->
          Map.put(payload, "customAgents", Enum.map(agents, &custom_agent_to_wire/1))
      end

    # Add permission request handler indicator
    payload =
      if config[:on_permission_request] do
        Map.put(payload, "acceptsPermissionRequests", true)
      else
        payload
      end

    # Add user input handler indicator
    payload =
      if config[:on_user_input_request] do
        Map.put(payload, "acceptsUserInputRequests", true)
      else
        payload
      end

    # Add hooks indicator
    payload =
      if config[:hooks] do
        hooks = config[:hooks]

        hook_list =
          [
            hooks.on_pre_tool_use && "preToolUse",
            hooks.on_post_tool_use && "postToolUse",
            hooks.on_user_prompt_submitted && "userPromptSubmitted",
            hooks.on_session_start && "sessionStart",
            hooks.on_session_end && "sessionEnd",
            hooks.on_error_occurred && "errorOccurred"
          ]
          |> Enum.filter(& &1)

        if hook_list != [] do
          Map.put(payload, "hooks", hook_list)
        else
          payload
        end
      else
        payload
      end

    payload
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
