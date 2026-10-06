defmodule CopilotSdk.Types do
  @moduledoc "Shared type definitions for the Copilot SDK."
end

defmodule CopilotSdk.Tool do
  @moduledoc "A tool definition for the Copilot SDK."

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          handler: (CopilotSdk.ToolInvocation.t() -> CopilotSdk.ToolResult.t()),
          parameters: map() | nil,
          overrides_built_in_tool: boolean(),
          defer: String.t() | nil,
          metadata: map() | nil,
          is_terminal: boolean() | nil
        }

  @enforce_keys [:name, :description, :handler]
  defstruct [
    :name,
    :description,
    :handler,
    :parameters,
    :defer,
    :metadata,
    :is_terminal,
    overrides_built_in_tool: false
  ]
end

defmodule CopilotSdk.ToolInvocation do
  @moduledoc "Context passed to a tool handler during invocation."

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          arguments: map() | nil
        }

  @enforce_keys []
  defstruct [:session_id, :tool_call_id, :tool_name, :arguments]
end

defmodule CopilotSdk.ToolResult do
  @moduledoc "Result returned from a tool handler."

  @type result_type :: :success | :failure | :rejected | :denied

  @type t :: %__MODULE__{
          text_result_for_llm: String.t(),
          result_type: result_type(),
          error: String.t() | nil,
          binary_results_for_llm: [CopilotSdk.ToolBinaryResult.t()] | nil,
          session_log: String.t() | nil,
          tool_telemetry: map() | nil
        }

  defstruct text_result_for_llm: "",
            result_type: :success,
            error: nil,
            binary_results_for_llm: nil,
            session_log: nil,
            tool_telemetry: nil

  @doc "Convert a ToolResult to a wire-format map (camelCase keys)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = r) do
    result = %{
      "textResultForLlm" => r.text_result_for_llm,
      "resultType" => Atom.to_string(r.result_type)
    }

    result
    |> maybe_put("error", r.error)
    |> maybe_put("sessionLog", r.session_log)
    |> maybe_put("toolTelemetry", r.tool_telemetry)
    |> maybe_put_binary_results(r.binary_results_for_llm)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_binary_results(map, nil), do: map

  defp maybe_put_binary_results(map, results) do
    wire_results =
      Enum.map(results, fn r ->
        %{
          "data" => r.data,
          "mimeType" => r.mime_type,
          "type" => r.type,
          "description" => r.description
        }
      end)

    Map.put(map, "binaryResultsForLlm", wire_results)
  end
end

defmodule CopilotSdk.ToolBinaryResult do
  @moduledoc "Binary content returned by a tool (e.g., images)."

  @type t :: %__MODULE__{
          data: String.t(),
          mime_type: String.t(),
          type: String.t(),
          description: String.t() | nil
        }

  defstruct data: "", mime_type: "", type: "", description: nil
end

defmodule CopilotSdk.PermissionRequestResult do
  @moduledoc """
  Result of a permission request evaluation.

  `:approved` is a compatibility alias for `:approve_once`; `:deny` is an alias
  for `:reject`. Nested `approval` maps use the upstream wire-format keys.
  """

  @type kind ::
          :approve_once
          | :approve_for_session
          | :approve_read_only_for_session
          | :approve_for_location
          | :approve_permanently
          | :reject
          | :deny
          | :user_not_available
          | :no_result
          | :approved
          | :approved_for_session
          | :approved_for_location
          | :cancelled
          | :denied_by_rules
          | :denied_by_content_exclusion_policy
          | :denied_could_not_request_from_user
          | :denied_interactively_by_user
          | :denied_by_permission_request_hook

  @type t :: %__MODULE__{
          kind: kind(),
          approved_interactively: boolean() | nil,
          approval: map() | nil,
          directories: [String.t()] | nil,
          domain: String.t() | nil,
          location_key: String.t() | nil,
          reason: String.t() | nil,
          rules: [any()] | nil,
          feedback: String.t() | nil,
          message: String.t() | nil,
          path: String.t() | nil,
          force_reject: boolean() | nil,
          interrupt: boolean() | nil
        }

  defstruct kind: :user_not_available,
            approved_interactively: nil,
            approval: nil,
            directories: nil,
            domain: nil,
            location_key: nil,
            reason: nil,
            rules: nil,
            feedback: nil,
            message: nil,
            path: nil,
            force_reject: nil,
            interrupt: nil

  @kind_to_wire %{
    approve_once: "approve-once",
    approve_for_session: "approve-for-session",
    approve_read_only_for_session: "approve-read-only-for-session",
    approve_for_location: "approve-for-location",
    approve_permanently: "approve-permanently",
    reject: "reject",
    deny: "reject",
    user_not_available: "user-not-available",
    no_result: "no-result",
    approved: "approve-once",
    approved_for_session: "approved-for-session",
    approved_for_location: "approved-for-location",
    cancelled: "cancelled",
    denied_by_rules: "denied-by-rules",
    denied_by_content_exclusion_policy: "denied-by-content-exclusion-policy",
    denied_could_not_request_from_user: "denied-no-approval-rule-and-could-not-request-from-user",
    denied_interactively_by_user: "denied-interactively-by-user",
    denied_by_permission_request_hook: "denied-by-permission-request-hook"
  }

  @doc "Convert kind atom to wire format string."
  @spec to_wire_kind(kind()) :: String.t()
  def to_wire_kind(kind) when is_atom(kind) do
    Map.get(@kind_to_wire, kind, "user-not-available")
  end

  @doc "Convert a PermissionRequestResult to a wire-format map."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = r) do
    result = %{"kind" => to_wire_kind(r.kind)}

    result
    |> maybe_put("approvedInteractively", r.approved_interactively)
    |> maybe_put("approval", r.approval)
    |> maybe_put("directories", r.directories)
    |> maybe_put("domain", r.domain)
    |> maybe_put("locationKey", r.location_key)
    |> maybe_put("reason", r.reason)
    |> maybe_put("rules", r.rules)
    |> maybe_put("feedback", r.feedback)
    |> maybe_put("message", r.message)
    |> maybe_put("path", r.path)
    |> maybe_put("forceReject", r.force_reject)
    |> maybe_put("interrupt", r.interrupt)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule CopilotSdk.UserInputRequest do
  @moduledoc "A user input request from the CLI."
  defstruct [:question, choices: [], allow_freeform: true]
end

defmodule CopilotSdk.UserInputResponse do
  @moduledoc "A user input response to return to the CLI."
  defstruct [:answer, was_freeform: false]
end

defmodule CopilotSdk.SessionHooks do
  @moduledoc """
  Lifecycle hooks for a session.

  - `on_pre_tool_use` - Called before a tool is executed
  - `on_pre_mcp_tool_call` - Called before an MCP tool is called
  - `on_post_tool_use` - Called after a tool succeeds
  - `on_post_tool_use_failure` - Called after a tool fails
  - `on_user_prompt_submitted` - Called when a user prompt is submitted
  - `on_user_prompt_transformed` - Called after a submitted prompt is transformed
  - `on_session_start` - Called when a session starts
  - `on_session_end` - Called when a session ends
  - `on_error_occurred` - Called when an error occurs
  - `on_agent_stop` - Called when the top-level agent reaches a natural stop
  - `on_subagent_start` - Called before a subagent's first turn
  - `on_subagent_stop` - Called after a subagent completes a turn
  """

  @type t :: %__MODULE__{
          on_pre_tool_use: function() | nil,
          on_pre_mcp_tool_call: function() | nil,
          on_post_tool_use: function() | nil,
          on_post_tool_use_failure: function() | nil,
          on_user_prompt_submitted: function() | nil,
          on_user_prompt_transformed: function() | nil,
          on_session_start: function() | nil,
          on_session_end: function() | nil,
          on_error_occurred: function() | nil,
          on_agent_stop: function() | nil,
          on_subagent_start: function() | nil,
          on_subagent_stop: function() | nil
        }

  defstruct on_pre_tool_use: nil,
            on_pre_mcp_tool_call: nil,
            on_post_tool_use: nil,
            on_post_tool_use_failure: nil,
            on_user_prompt_submitted: nil,
            on_user_prompt_transformed: nil,
            on_session_start: nil,
            on_session_end: nil,
            on_error_occurred: nil,
            on_agent_stop: nil,
            on_subagent_start: nil,
            on_subagent_stop: nil

  @hook_field_map %{
    "preToolUse" => :on_pre_tool_use,
    "preMcpToolCall" => :on_pre_mcp_tool_call,
    "postToolUse" => :on_post_tool_use,
    "postToolUseFailure" => :on_post_tool_use_failure,
    "userPromptSubmitted" => :on_user_prompt_submitted,
    "userPromptTransformed" => :on_user_prompt_transformed,
    "sessionStart" => :on_session_start,
    "sessionEnd" => :on_session_end,
    "errorOccurred" => :on_error_occurred,
    "agentStop" => :on_agent_stop,
    "subagentStart" => :on_subagent_start,
    "subagentStop" => :on_subagent_stop
  }

  @doc "Dispatch a hook by its wire name. Returns the handler result or nil."
  @spec dispatch(t() | map() | keyword() | nil, String.t(), term(), term()) :: term()
  def dispatch(hooks, hook_type, input, context) when is_list(hooks) do
    dispatch(Map.new(hooks), hook_type, input, context)
  end

  def dispatch(hooks, hook_type, input, context) when is_map(hooks) do
    case Map.get(@hook_field_map, hook_type) do
      nil ->
        nil

      field ->
        wire_field =
          "on" <> String.upcase(String.first(hook_type)) <> String.slice(hook_type, 1..-1//1)

        case Map.get(hooks, field, Map.get(hooks, wire_field)) do
          nil -> nil
          handler when is_function(handler, 2) -> handler.(input, context)
          _ -> nil
        end
    end
  end

  def dispatch(nil, _hook_type, _input, _context), do: nil
end

defmodule CopilotSdk.SessionConfig do
  @moduledoc """
  Configuration for creating or resuming a session.

  Optional fields default to `nil` and are omitted from the wire payload.
  Explicit `false` values and empty collections are preserved. Nested configuration
  maps accept Elixir atom keys or upstream wire-format string keys. Callbacks remain
  local to the SDK.

  `suppress_resume_event`, `continue_pending_work`, and `allow_transcript_recovery`
  apply only when resuming. Session filesystem providers are not yet supported.
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          client_name: String.t() | nil,
          model: String.t() | nil,
          model_capabilities: map() | nil,
          reasoning_effort: String.t() | nil,
          reasoning_summary: String.t() | nil,
          context_tier: String.t() | nil,
          tools: [CopilotSdk.Tool.t()] | nil,
          system_message: map() | nil,
          available_tools: [String.t()] | nil,
          excluded_tools: [String.t()] | nil,
          excluded_builtin_agents: [String.t()] | nil,
          on_permission_request: function(),
          on_user_input_request: function() | nil,
          hooks: CopilotSdk.SessionHooks.t() | nil,
          working_directory: String.t() | nil,
          additional_directories: [String.t()] | nil,
          provider: map() | nil,
          streaming: boolean() | nil,
          mcp_servers: map() | nil,
          disabled_mcp_servers: [String.t()] | nil,
          custom_agents: [map()] | nil,
          custom_agents_local_only: boolean() | nil,
          default_agent: map() | nil,
          agent: String.t() | nil,
          config_dir: String.t() | nil,
          enable_config_discovery: boolean() | nil,
          enable_session_telemetry: boolean() | nil,
          enable_citations: boolean() | nil,
          enable_file_change_tracking: boolean() | nil,
          enable_managed_settings: boolean() | nil,
          managed_settings: map() | nil,
          session_limits: map() | nil,
          skill_directories: [String.t()] | nil,
          plugin_directories: [String.t()] | nil,
          instruction_directories: [String.t()] | nil,
          disabled_skills: [String.t()] | nil,
          infinite_sessions: map() | nil,
          suppress_resume_event: boolean() | nil,
          continue_pending_work: boolean() | nil,
          allow_transcript_recovery: boolean() | nil,
          on_event: function() | nil
        }

  defstruct [
    :session_id,
    :client_name,
    :model,
    :model_capabilities,
    :reasoning_effort,
    :reasoning_summary,
    :context_tier,
    :tools,
    :system_message,
    :available_tools,
    :excluded_tools,
    :excluded_builtin_agents,
    :on_permission_request,
    :on_user_input_request,
    :hooks,
    :working_directory,
    :additional_directories,
    :provider,
    :streaming,
    :mcp_servers,
    :disabled_mcp_servers,
    :custom_agents,
    :custom_agents_local_only,
    :default_agent,
    :agent,
    :config_dir,
    :enable_config_discovery,
    :enable_session_telemetry,
    :enable_citations,
    :enable_file_change_tracking,
    :enable_managed_settings,
    :managed_settings,
    :session_limits,
    :skill_directories,
    :plugin_directories,
    :instruction_directories,
    :disabled_skills,
    :infinite_sessions,
    :suppress_resume_event,
    :continue_pending_work,
    :allow_transcript_recovery,
    :on_event
  ]
end

defmodule CopilotSdk.ClientOptions do
  @moduledoc "Options for creating a CopilotSdk.Client."

  @type t :: %__MODULE__{
          cli_path: String.t() | nil,
          cli_args: [String.t()],
          cwd: String.t() | nil,
          port: non_neg_integer(),
          use_stdio: boolean(),
          cli_url: String.t() | nil,
          connection_token: String.t() | nil,
          log_level: String.t(),
          auto_start: boolean(),
          auto_restart: boolean(),
          env: %{String.t() => String.t()} | nil,
          github_token: String.t() | nil,
          use_logged_in_user: boolean() | nil,
          on_list_models: function() | nil
        }

  defstruct cli_path: nil,
            cli_args: [],
            cwd: nil,
            port: 0,
            use_stdio: true,
            cli_url: nil,
            connection_token: nil,
            log_level: "info",
            auto_start: true,
            auto_restart: true,
            env: nil,
            github_token: nil,
            use_logged_in_user: nil,
            on_list_models: nil

  @doc "Build a ClientOptions struct from a keyword list, validating constraints."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    options = struct!(__MODULE__, opts)
    validate!(options)
    options
  end

  defp validate!(%__MODULE__{} = opts) do
    if opts.cli_url && opts.cli_path do
      raise ArgumentError, "cli_url and cli_path are mutually exclusive"
    end

    if opts.cli_url && opts.github_token do
      raise ArgumentError, "github_token cannot be used with cli_url"
    end

    if opts.cli_url && opts.use_logged_in_user != nil do
      raise ArgumentError, "use_logged_in_user cannot be used with cli_url"
    end

    if opts.cli_url && opts.use_stdio do
      raise ArgumentError, "cli_url and use_stdio are mutually exclusive"
    end

    :ok
  end
end
