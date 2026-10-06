defmodule CopilotSdk.WireFormat do
  @moduledoc "Conversion utilities for snake_case Elixir data to camelCase wire format."

  @session_fields [
    client_name: "clientName",
    model: "model",
    reasoning_effort: "reasoningEffort",
    reasoning_summary: "reasoningSummary",
    context_tier: "contextTier",
    available_tools: "availableTools",
    excluded_tools: "excludedTools",
    excluded_builtin_agents: "excludedBuiltinAgents",
    working_directory: "workingDirectory",
    additional_directories: "additionalDirectories",
    streaming: "streaming",
    agent: "agent",
    custom_agents_local_only: "customAgentsLocalOnly",
    config_dir: "configDir",
    enable_config_discovery: "enableConfigDiscovery",
    enable_session_telemetry: "enableSessionTelemetry",
    enable_citations: "enableCitations",
    enable_file_change_tracking: "enableFileChangeTracking",
    enable_managed_settings: "enableManagedSettings",
    skill_directories: "skillDirectories",
    plugin_directories: "pluginDirectories",
    instruction_directories: "instructionDirectories",
    disabled_skills: "disabledSkills",
    disabled_mcp_servers: "disabledMcpServers"
  ]

  @doc "Convert provider config to camelCase wire format."
  @spec provider_to_wire(map() | nil) :: map() | nil
  def provider_to_wire(nil), do: nil

  def provider_to_wire(config) when is_map(config) do
    config
    |> convert_fields(
      type: "type",
      base_url: "baseUrl",
      api_key: "apiKey",
      wire_api: "wireApi",
      bearer_token: "bearerToken",
      headers: "headers"
    )
    |> maybe_put("azure", convert_fields(get(config, :azure, "azure"), api_version: "apiVersion"))
  end

  @doc "Convert custom agent config to camelCase wire format."
  @spec custom_agent_to_wire(map()) :: map()
  def custom_agent_to_wire(agent) when is_map(agent) do
    agent
    |> convert_fields(
      name: "name",
      prompt: "prompt",
      display_name: "displayName",
      description: "description",
      tools: "tools",
      infer: "infer",
      model: "model"
    )
    |> maybe_put("mcpServers", mcp_servers_to_wire(get(agent, :mcp_servers, "mcpServers")))
  end

  @doc "Convert infinite session config to camelCase wire format."
  @spec infinite_sessions_to_wire(map() | nil) :: map() | nil
  def infinite_sessions_to_wire(nil), do: nil

  def infinite_sessions_to_wire(config) when is_map(config) do
    convert_fields(config,
      enabled: "enabled",
      background_compaction_threshold: "backgroundCompactionThreshold",
      buffer_exhaustion_threshold: "bufferExhaustionThreshold"
    )
  end

  @doc "Convert system message config to wire format."
  @spec system_message_to_wire(map() | nil) :: map() | nil
  def system_message_to_wire(nil), do: nil

  def system_message_to_wire(config) when is_map(config) do
    config
  end

  @doc "Build a session create payload, excluding resume-only configuration."
  @spec build_session_payload(map() | keyword(), String.t()) :: map()
  def build_session_payload(config, session_id) do
    config
    |> convert_fields(@session_fields)
    |> Map.merge(%{
      "sessionId" => session_id,
      "envValueMode" => "direct",
      "requestPermission" =>
        is_function(get(config, :on_permission_request, "onPermissionRequest")),
      "requestUserInput" =>
        is_function(get(config, :on_user_input_request, "onUserInputRequest")),
      "hooks" => hooks_enabled?(get(config, :hooks, "hooks"))
    })
    |> maybe_put(
      "systemMessage",
      system_message_to_wire(get(config, :system_message, "systemMessage"))
    )
    |> maybe_put("provider", provider_to_wire(get(config, :provider, "provider")))
    |> maybe_put(
      "managedSettings",
      managed_settings_to_wire(get(config, :managed_settings, "managedSettings"))
    )
    |> maybe_put(
      "modelCapabilities",
      model_capabilities_to_wire(get(config, :model_capabilities, "modelCapabilities"))
    )
    |> maybe_put(
      "defaultAgent",
      convert_fields(get(config, :default_agent, "defaultAgent"), excluded_tools: "excludedTools")
    )
    |> maybe_put(
      "sessionLimits",
      convert_fields(get(config, :session_limits, "sessionLimits"), max_ai_credits: "maxAiCredits")
    )
    |> maybe_put(
      "infiniteSessions",
      infinite_sessions_to_wire(get(config, :infinite_sessions, "infiniteSessions"))
    )
    |> maybe_put("mcpServers", mcp_servers_to_wire(get(config, :mcp_servers, "mcpServers")))
    |> maybe_put("tools", map_list(get(config, :tools, "tools"), &CopilotSdk.Tools.to_wire/1))
    |> maybe_put(
      "customAgents",
      map_list(get(config, :custom_agents, "customAgents"), &custom_agent_to_wire/1)
    )
  end

  @doc "Build a session resume payload, including resume-only configuration."
  @spec build_resume_payload(map() | keyword(), String.t()) :: map()
  def build_resume_payload(config, session_id) do
    config
    |> build_session_payload(session_id)
    |> maybe_put("disableResume", get(config, :suppress_resume_event, "suppressResumeEvent"))
    |> maybe_put(
      "continuePendingWork",
      get(config, :continue_pending_work, "continuePendingWork")
    )
    |> maybe_put(
      "allowTranscriptRecovery",
      get(config, :allow_transcript_recovery, "allowTranscriptRecovery")
    )
  end

  defp managed_settings_to_wire(nil), do: nil

  defp managed_settings_to_wire(config) do
    config = rename_known_keys(config, permissions: "permissions")

    case Map.fetch(config, "permissions") do
      {:ok, permissions} when is_map(permissions) ->
        Map.put(
          config,
          "permissions",
          rename_known_keys(permissions,
            disable_bypass_permissions_mode: "disableBypassPermissionsMode",
            allow: "allow",
            ask: "ask",
            deny: "deny"
          )
        )

      _ ->
        config
    end
  end

  # Leave unknown policy keys intact so the runtime can reject invalid policy.
  defp rename_known_keys(config, fields) do
    Enum.reduce(fields, config, fn {key, wire_key}, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} -> acc |> Map.delete(key) |> Map.put(wire_key, value)
        :error -> acc
      end
    end)
  end

  defp model_capabilities_to_wire(nil), do: nil

  defp model_capabilities_to_wire(config) do
    limits = get(config, :limits, "limits")

    wire_limits =
      if limits do
        limits
        |> convert_fields(
          max_prompt_tokens: "max_prompt_tokens",
          max_output_tokens: "max_output_tokens",
          max_context_window_tokens: "max_context_window_tokens"
        )
        |> maybe_put(
          "vision",
          convert_fields(get(limits, :vision, "vision"),
            supported_media_types: "supported_media_types",
            max_prompt_images: "max_prompt_images",
            max_prompt_image_size: "max_prompt_image_size"
          )
        )
      end

    %{}
    |> maybe_put(
      "supports",
      convert_fields(get(config, :supports, "supports"),
        vision: "vision",
        reasoning_effort: "reasoningEffort"
      )
    )
    |> maybe_put("limits", wire_limits)
  end

  defp mcp_servers_to_wire(nil), do: nil

  defp mcp_servers_to_wire(servers) do
    Map.new(servers, fn {name, config} ->
      cwd =
        case get(config, :cwd, "cwd") do
          nil -> get(config, :working_directory, "workingDirectory")
          value -> value
        end

      {name,
       convert_fields(config,
         type: "type",
         tools: "tools",
         timeout: "timeout",
         command: "command",
         args: "args",
         env: "env",
         url: "url",
         headers: "headers"
       )
       |> maybe_put("cwd", cwd)}
    end)
  end

  defp hooks_enabled?(nil), do: false
  defp hooks_enabled?(hooks) when is_map(hooks), do: hooks_enabled?(Map.to_list(hooks))

  defp hooks_enabled?(hooks) when is_list(hooks),
    do: Enum.any?(hooks, fn {_, handler} -> is_function(handler, 2) end)

  defp hooks_enabled?(_hooks), do: false

  defp map_list(nil, _fun), do: nil
  defp map_list(values, fun), do: Enum.map(values, fun)

  defp convert_fields(nil, _fields), do: nil

  defp convert_fields(config, fields) do
    Map.new(fields, fn {key, wire_key} -> {wire_key, get(config, key, wire_key)} end)
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  defp get(config, key, _wire_key) when is_list(config), do: Keyword.get(config, key)

  defp get(config, key, wire_key) when is_map(config) do
    Map.get(config, key, Map.get(config, wire_key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
