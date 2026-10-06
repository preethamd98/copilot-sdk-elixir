defmodule CopilotSdk.Generated.ServerRpc do
  @moduledoc "Server-scoped RPC methods. Routes calls through JSON-RPC client."

  @type t :: %__MODULE__{json_rpc_pid: pid()}

  defstruct [:json_rpc_pid]

  @doc "Creates a server-scoped RPC wrapper for an existing JSON-RPC client."
  @spec new(pid()) :: t()
  def new(json_rpc_pid) do
    %__MODULE__{json_rpc_pid: json_rpc_pid}
  end

  @doc "Pings the server with optional wire parameters and request options."
  @spec ping(t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def ping(rpc, params \\ %{}, opts \\ []) do
    request(rpc, "ping", params, opts)
  end

  @doc "Returns the server status."
  @spec get_status(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_status(rpc, opts \\ []) do
    request(rpc, "status.get", %{}, opts)
  end

  @doc "Returns the current authentication status."
  @spec get_auth_status(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_auth_status(rpc, opts \\ []) do
    request(rpc, "auth.getStatus", %{}, opts)
  end

  @doc """
  Returns account quota snapshots.

  Optional wire parameters are `"selectionId"` and `"gitHubToken"`.
  """
  @spec get_quota(t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_quota(rpc, params \\ %{}, opts \\ []) do
    request(rpc, "account.getQuota", params, opts)
  end

  @doc "Lists built-in tools, optionally using the wire parameter `\"model\"`."
  @spec list_tools(t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def list_tools(rpc, params \\ %{}, opts \\ []) do
    request(rpc, "tools.list", params, opts)
  end

  @doc "Lists the models available to the server."
  @spec list_models(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def list_models(rpc, opts \\ []) do
    request(rpc, "models.list", %{}, opts)
  end

  @doc "Lists sessions with an optional wire-format filter."
  @spec list_sessions(t(), map() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def list_sessions(rpc, filter \\ nil, opts \\ []) do
    params = if filter, do: %{"filter" => filter}, else: %{}
    request(rpc, "session.list", params, opts)
  end

  @doc "Returns the most recently used session ID."
  @spec get_last_session_id(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_last_session_id(rpc, opts \\ []) do
    request(rpc, "session.getLastId", %{}, opts)
  end

  @doc "Returns the foreground session ID in TUI+server mode."
  @spec get_foreground_session_id(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_foreground_session_id(rpc, opts \\ []) do
    request(rpc, "session.getForeground", %{}, opts)
  end

  @doc "Sets the foreground session in TUI+server mode."
  @spec set_foreground_session_id(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def set_foreground_session_id(rpc, session_id, opts \\ []) do
    request(rpc, "session.setForeground", %{"sessionId" => session_id}, opts)
  end

  defp request(rpc, method, params, opts) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, method, params, opts)
  end
end

defmodule CopilotSdk.Generated.SessionRpc do
  @moduledoc "Session-scoped RPC methods. Auto-injects sessionId."

  @type t :: %__MODULE__{json_rpc_pid: pid(), session_id: String.t()}

  defstruct [:json_rpc_pid, :session_id]

  @doc "Creates an RPC wrapper bound to one session."
  @spec new(pid(), String.t()) :: t()
  def new(json_rpc_pid, session_id) do
    %__MODULE__{json_rpc_pid: json_rpc_pid, session_id: session_id}
  end

  @doc "Logs a message with optional `:level` and `:ephemeral` settings."
  @spec log(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def log(rpc, message, opts_map \\ %{}) do
    params =
      %{"message" => message}
      |> maybe_put("level", opts_map[:level])
      |> maybe_put("ephemeral", opts_map[:ephemeral])

    request(rpc, "session.log", params)
  end

  @doc "Sends a message using wire-format parameters."
  @spec send_message(t(), map()) :: {:ok, term()} | {:error, term()}
  def send_message(rpc, params) do
    request(rpc, "session.send", params)
  end

  @doc "Aborts the currently processing message."
  @spec abort(t()) :: {:ok, term()} | {:error, term()}
  def abort(rpc) do
    request(rpc, "session.abort")
  end

  @doc "Detaches this connection while preserving persisted session data."
  @spec detach(t()) :: {:ok, term()} | {:error, term()}
  def detach(rpc) do
    request(rpc, "session.detach")
  end

  @doc "Calls the legacy session destroy RPC. Use `detach/1` to disconnect."
  @spec destroy(t()) :: {:ok, term()} | {:error, term()}
  def destroy(rpc) do
    request(rpc, "session.destroy")
  end

  @doc "Returns the session's messages."
  @spec get_messages(t()) :: {:ok, term()} | {:error, term()}
  def get_messages(rpc) do
    request(rpc, "session.getMessages")
  end

  @doc """
  Switches the session model with optional wire-format model settings.

  Settings include `"reasoningEffort"`, `"reasoningSummary"`, `"contextTier"`,
  and `"modelCapabilities"`. A `nil` reasoning effort clears the override.
  The explicit model ID and this wrapper's session ID take precedence.
  """
  @spec switch_model(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def switch_model(rpc, model_id, opts_map \\ %{}) do
    request(rpc, "session.model.switchTo", Map.put(opts_map, "modelId", model_id))
  end

  @doc "Returns the current session model and its configuration."
  @spec get_current_model(t()) :: {:ok, term()} | {:error, term()}
  def get_current_model(rpc) do
    request(rpc, "session.model.getCurrent")
  end

  @doc """
  Replaces this connection's external tools. An empty list removes them.

  This low-level RPC accepts wire-format definitions only; it does not register
  local tool handlers.
  """
  @spec set_tools(t(), [map()]) :: {:ok, term()} | {:error, term()}
  def set_tools(rpc, tools) do
    request(rpc, "session.tools.set", %{"tools" => tools})
  end

  @doc "Returns the current agent interaction mode."
  @spec get_mode(t()) :: {:ok, term()} | {:error, term()}
  def get_mode(rpc) do
    request(rpc, "session.mode.get")
  end

  @doc "Sets the agent interaction mode with optional wire-format mode settings."
  @spec set_mode(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def set_mode(rpc, mode, opts_map \\ %{}) do
    request(rpc, "session.mode.set", Map.put(opts_map, "mode", mode))
  end

  @doc "Reads the session plan file."
  @spec read_plan(t()) :: {:ok, term()} | {:error, term()}
  def read_plan(rpc) do
    request(rpc, "session.plan.read")
  end

  @doc "Replaces the contents of the session plan file."
  @spec update_plan(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def update_plan(rpc, content) do
    request(rpc, "session.plan.update", %{"content" => content})
  end

  @doc "Deletes the session plan file."
  @spec delete_plan(t()) :: {:ok, term()} | {:error, term()}
  def delete_plan(rpc) do
    request(rpc, "session.plan.delete")
  end

  @doc """
  Lists session agents.

  Optional wire parameters are `"includeBuiltInAgents"` and `"includePrompt"`.
  """
  @spec list_agents(t(), map()) :: {:ok, term()} | {:error, term()}
  def list_agents(rpc, opts_map \\ %{}) do
    request(rpc, "session.agent.list", opts_map)
  end

  @doc "Returns the currently selected custom agent."
  @spec get_current_agent(t()) :: {:ok, term()} | {:error, term()}
  def get_current_agent(rpc) do
    request(rpc, "session.agent.getCurrent")
  end

  @doc "Selects a custom agent by name for subsequent turns."
  @spec select_agent(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def select_agent(rpc, name) do
    request(rpc, "session.agent.select", %{"name" => name})
  end

  @doc "Returns the session to its default agent."
  @spec deselect_agent(t()) :: {:ok, term()} | {:error, term()}
  def deselect_agent(rpc) do
    request(rpc, "session.agent.deselect")
  end

  @doc """
  Compacts session history.

  Optional wire parameters are `"customInstructions"`, `"trigger"`, and `"tokenLimit"`.
  """
  @spec compact(t(), map()) :: {:ok, term()} | {:error, term()}
  def compact(rpc, opts_map \\ %{}) do
    request(rpc, "session.history.compact", opts_map)
  end

  @doc "Lists the skills available to the session."
  @spec list_skills(t()) :: {:ok, term()} | {:error, term()}
  def list_skills(rpc) do
    request(rpc, "session.skills.list")
  end

  @doc "Completes a pending external tool call."
  @spec handle_tool_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_tool_result(rpc, request_id, result) do
    request(rpc, "session.tools.handlePendingToolCall", %{
      "requestId" => request_id,
      "result" => result
    })
  end

  @doc "Completes a pending permission request."
  @spec handle_permission_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_permission_result(rpc, request_id, result) do
    request(rpc, "session.permissions.handlePendingPermissionRequest", %{
      "requestId" => request_id,
      "result" => result
    })
  end

  @doc "Completes a pending user-input request."
  @spec handle_user_input_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_user_input_result(rpc, request_id, response) do
    request(rpc, "session.userInput.handlePendingUserInputRequest", %{
      "requestId" => request_id,
      "response" => response
    })
  end

  @doc "Completes a pending hook invocation."
  @spec handle_hooks_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_hooks_result(rpc, request_id, result) do
    request(rpc, "session.hooks.handlePendingHookInvocation", %{
      "requestId" => request_id,
      "result" => result
    })
  end

  defp request(rpc, method, params \\ %{}) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      method,
      Map.put(params, "sessionId", rpc.session_id)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
