defmodule CopilotSdk.Generated.ServerRpc do
  @moduledoc "Server-scoped RPC methods. Routes calls through JSON-RPC client."

  @type t :: %__MODULE__{json_rpc_pid: pid()}

  defstruct [:json_rpc_pid]

  @spec new(pid()) :: t()
  def new(json_rpc_pid) do
    %__MODULE__{json_rpc_pid: json_rpc_pid}
  end

  @spec ping(t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def ping(rpc, params \\ %{}, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "ping", params, opts)
  end

  @spec get_auth_status(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_auth_status(rpc, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "getAuthStatus", %{}, opts)
  end

  @spec list_models(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def list_models(rpc, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "models.list", %{}, opts)
  end

  @spec list_sessions(t(), map() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def list_sessions(rpc, filter \\ nil, opts \\ []) do
    params = if filter, do: %{"filter" => filter}, else: %{}
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "sessions.list", params, opts)
  end

  @spec get_last_session_id(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_last_session_id(rpc, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "sessions.getLastSessionId", %{}, opts)
  end

  @spec get_foreground_session_id(t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_foreground_session_id(rpc, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "sessions.getForegroundSessionId", %{}, opts)
  end

  @spec set_foreground_session_id(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def set_foreground_session_id(rpc, session_id, opts \\ []) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "sessions.setForegroundSessionId",
      %{"sessionId" => session_id},
      opts
    )
  end
end

defmodule CopilotSdk.Generated.SessionRpc do
  @moduledoc "Session-scoped RPC methods. Auto-injects sessionId."

  @type t :: %__MODULE__{json_rpc_pid: pid(), session_id: String.t()}

  defstruct [:json_rpc_pid, :session_id]

  @spec new(pid(), String.t()) :: t()
  def new(json_rpc_pid, session_id) do
    %__MODULE__{json_rpc_pid: json_rpc_pid, session_id: session_id}
  end

  @spec log(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def log(rpc, message, opts_map \\ %{}) do
    params =
      %{"sessionId" => rpc.session_id, "message" => message}
      |> maybe_put("level", opts_map[:level])
      |> maybe_put("ephemeral", opts_map[:ephemeral])

    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "session.log", params)
  end

  @spec send_message(t(), map()) :: {:ok, term()} | {:error, term()}
  def send_message(rpc, params) do
    params = Map.put(params, "sessionId", rpc.session_id)
    CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "session.send", params)
  end

  @spec abort(t()) :: {:ok, term()} | {:error, term()}
  def abort(rpc) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.abort",
      %{"sessionId" => rpc.session_id}
    )
  end

  @spec destroy(t()) :: {:ok, term()} | {:error, term()}
  def destroy(rpc) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.destroy",
      %{"sessionId" => rpc.session_id}
    )
  end

  @spec get_messages(t()) :: {:ok, term()} | {:error, term()}
  def get_messages(rpc) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.getMessages",
      %{"sessionId" => rpc.session_id}
    )
  end

  @spec switch_model(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def switch_model(rpc, model) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.model.switchTo",
      %{"sessionId" => rpc.session_id, "model" => model}
    )
  end

  @spec handle_tool_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_tool_result(rpc, request_id, result) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.tools.handlePendingToolCall",
      %{
        "sessionId" => rpc.session_id,
        "requestId" => request_id,
        "result" => result
      }
    )
  end

  @spec handle_permission_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_permission_result(rpc, request_id, result) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.permissions.handlePendingPermissionRequest",
      %{
        "sessionId" => rpc.session_id,
        "requestId" => request_id,
        "result" => result
      }
    )
  end

  @spec handle_user_input_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_user_input_result(rpc, request_id, response) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.userInput.handlePendingUserInputRequest",
      %{
        "sessionId" => rpc.session_id,
        "requestId" => request_id,
        "response" => response
      }
    )
  end

  @spec handle_hooks_result(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_hooks_result(rpc, request_id, result) do
    CopilotSdk.JsonRpc.Client.request(
      rpc.json_rpc_pid,
      "session.hooks.handlePendingHookInvocation",
      %{
        "sessionId" => rpc.session_id,
        "requestId" => request_id,
        "result" => result
      }
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
