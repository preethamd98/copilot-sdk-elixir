defmodule CopilotSdk.Session do
  @moduledoc """
  Per-conversation GenServer that manages event dispatch, message sending,
  and the send_and_wait coordination pattern.
  """

  use GenServer, restart: :temporary
  require Logger

  alias CopilotSdk.{SessionEvent, ToolInvocation, ToolResult, PermissionRequestResult}
  alias CopilotSdk.Session.{EventProducer, EventConsumer}
  alias CopilotSdk.Generated.SessionRpc

  @type session :: pid() | atom() | GenServer.name()

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          workspace_path: String.t() | nil,
          json_rpc_pid: pid() | nil,
          event_producer_pid: pid() | nil,
          consumer_supervisor: pid() | nil,
          task_supervisor: pid() | nil,
          tool_handlers: %{String.t() => function()},
          permission_handler: function() | nil,
          user_input_handler: function() | nil,
          hooks: CopilotSdk.SessionHooks.t() | nil,
          rpc: CopilotSdk.Generated.SessionRpc.t() | nil,
          on_event: function() | nil
        }

  defstruct [
    :session_id,
    :workspace_path,
    :json_rpc_pid,
    :event_producer_pid,
    :consumer_supervisor,
    :task_supervisor,
    :tool_handlers,
    :permission_handler,
    :user_input_handler,
    :hooks,
    :rpc,
    :on_event,
    managed_settings_enabled: false
  ]

  # --- Public API ---

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg)
  end

  @doc "Subscribe to session events. Returns an unsubscribe function."
  @spec on(session(), (SessionEvent.t() -> any())) :: (-> :ok)
  def on(session, handler_fn) when is_function(handler_fn, 1) do
    {:ok, consumer_pid} = GenServer.call(session, {:subscribe, handler_fn})

    fn ->
      try do
        if Process.alive?(consumer_pid), do: GenStage.stop(consumer_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      :ok
    end
  end

  @doc "Dispatch an event to this session (called by the Client)."
  @spec dispatch_event(session(), map()) :: :ok
  def dispatch_event(session, event_data) do
    GenServer.cast(session, {:dispatch_event, event_data})
  end

  @doc "Send a message to this session."
  @spec send_message(session(), map() | keyword(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(session, options, opts \\ []) do
    rpc = rpc(session)
    params = build_send_params(Map.new(options), rpc.session_id)

    case CopilotSdk.JsonRpc.Client.request(rpc.json_rpc_pid, "session.send", params, opts) do
      {:ok, result} -> {:ok, result["messageId"] || result["id"]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a message and wait for session.idle.

  Returns `{:ok, last_assistant_message}` or `{:error, reason}`.
  """
  @spec send_and_wait(session(), map() | keyword(), keyword()) ::
          {:ok, SessionEvent.t() | nil} | {:error, term()}
  def send_and_wait(session, options, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    deadline = deadline(timeout)
    caller = self()
    ref = make_ref()
    monitor = Process.monitor(session)

    unsubscribe =
      on(session, fn event ->
        case event do
          %{agent_id: agent_id} when agent_id not in [nil, ""] ->
            :ok

          %{type: :assistant_message} ->
            send(caller, {ref, :assistant_message, event})

          %{type: :session_idle, data: %{"mode" => "autopilot"}} ->
            :ok

          %{type: :session_idle} ->
            send(caller, {ref, :idle})

          %{type: :session_error} ->
            send(caller, {ref, :error, event})

          _ ->
            :ok
        end
      end)

    try do
      case send_message(session, options, timeout: remaining(deadline)) do
        {:ok, _message_id} -> wait_for_idle(ref, monitor, nil, deadline)
        {:error, reason} -> {:error, reason}
      end
    after
      unsubscribe.()
      Process.demonitor(monitor, [:flush])
      flush_wait_messages(ref)
    end
  end

  @doc "Disconnect this session."
  @spec disconnect(session()) :: :ok | {:error, term()}
  def disconnect(session) do
    GenServer.call(session, :disconnect, :infinity)
  end

  @doc "Abort the current operation."
  @spec abort(session()) :: :ok | {:error, term()}
  def abort(session) do
    session |> rpc() |> SessionRpc.abort() |> result_to_ok_error()
  end

  @doc "Change the model for this session."
  @spec set_model(session(), String.t(), map() | keyword()) :: :ok | {:error, term()}
  def set_model(session, model, opts \\ %{}) do
    opts = Map.new(opts)
    rpc = rpc(session)

    wire_opts =
      opts
      |> CopilotSdk.WireFormat.build_session_payload(rpc.session_id)
      |> Map.take(["reasoningEffort", "reasoningSummary", "contextTier", "modelCapabilities"])

    wire_opts =
      if Map.get(opts, :reasoning_effort, :absent) == nil or
           Map.get(opts, "reasoningEffort", :absent) == nil do
        Map.put(wire_opts, "reasoningEffort", nil)
      else
        wire_opts
      end

    rpc |> SessionRpc.switch_model(model, wire_opts) |> result_to_ok_error()
  end

  @doc "Log a message to the session timeline."
  @spec log(session(), String.t(), keyword()) :: :ok | {:error, term()}
  def log(session, message, opts \\ []) do
    session |> rpc() |> SessionRpc.log(message, Map.new(opts)) |> result_to_ok_error()
  end

  @doc "Get the persisted events for this session."
  @spec get_messages(session()) :: {:ok, map()} | {:error, term()}
  def get_messages(session), do: session |> rpc() |> SessionRpc.get_messages()

  @doc "Get workspace path."
  @spec workspace_path(session()) :: String.t() | nil
  def workspace_path(session) do
    GenServer.call(session, :workspace_path)
  end

  @doc "Set the workspace path (called by Client after session.create response)."
  @spec set_workspace_path(session(), String.t() | nil) :: :ok
  def set_workspace_path(session, path) do
    GenServer.cast(session, {:set_workspace_path, path})
  end

  @doc "Get the session ID."
  @spec session_id(session()) :: String.t() | nil
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc "Get a tool handler by name."
  @spec get_tool_handler(session(), String.t()) :: function() | nil
  def get_tool_handler(session, tool_name) do
    GenServer.call(session, {:get_tool_handler, tool_name})
  end

  @doc "Get the session RPC accessor."
  @spec rpc(session()) :: CopilotSdk.Generated.SessionRpc.t() | nil
  def rpc(session) do
    GenServer.call(session, :rpc)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(init_arg) do
    session_id = init_arg.session_id
    json_rpc_pid = init_arg.json_rpc_pid
    config = normalize_config(init_arg[:config] || %{})

    {:ok, producer} = EventProducer.start_link([])
    {:ok, consumer_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, task_sup} = Task.Supervisor.start_link()

    tool_handlers =
      case config[:tools] || config["tools"] do
        nil ->
          %{}

        tools ->
          Map.new(tools, fn tool -> {tool.name, tool.handler} end)
      end

    session_rpc = SessionRpc.new(json_rpc_pid, session_id)

    state = %__MODULE__{
      session_id: session_id,
      json_rpc_pid: json_rpc_pid,
      event_producer_pid: producer,
      consumer_supervisor: consumer_sup,
      task_supervisor: task_sup,
      tool_handlers: tool_handlers,
      permission_handler: config[:on_permission_request] || config["on_permission_request"],
      user_input_handler: config[:on_user_input_request] || config["on_user_input_request"],
      hooks: config[:hooks] || config["hooks"],
      rpc: session_rpc,
      on_event: config[:on_event] || config["on_event"],
      managed_settings_enabled: managed_settings_enabled?(config)
    }

    # If there's an early-bind on_event handler, subscribe it immediately
    if state.on_event do
      {:ok, _} =
        DynamicSupervisor.start_child(
          consumer_sup,
          {EventConsumer, {producer, state.on_event}}
        )
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, handler_fn}, _from, state) do
    {:ok, consumer_pid} =
      DynamicSupervisor.start_child(
        state.consumer_supervisor,
        {EventConsumer, {state.event_producer_pid, handler_fn}}
      )

    {:reply, {:ok, consumer_pid}, state}
  end

  def handle_call(:disconnect, _from, state) do
    case SessionRpc.detach(state.rpc) do
      {:ok, %{"success" => false} = response} ->
        {:reply, {:error, response["error"] || :disconnect_failed}, state}

      {:ok, _} ->
        {:stop, :normal, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:workspace_path, _from, state) do
    {:reply, state.workspace_path, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:get_tool_handler, tool_name}, _from, state) do
    {:reply, Map.get(state.tool_handlers, tool_name), state}
  end

  def handle_call(:rpc, _from, state) do
    {:reply, state.rpc, state}
  end

  @impl true
  def handle_cast({:dispatch_event, event_data}, state) do
    event = SessionEvent.from_map(event_data)

    # Handle broadcast request events (protocol v3) before user handlers
    handle_broadcast_event(event, state)

    # Push to GenStage producer — all consumers receive it
    EventProducer.push_event(state.event_producer_pid, event)

    {:noreply, state}
  end

  def handle_cast({:set_workspace_path, path}, state) do
    {:noreply, %{state | workspace_path: path}}
  end

  @impl true
  def terminate(_reason, state) do
    for pid <- [state.consumer_supervisor, state.task_supervisor] do
      if is_pid(pid) && Process.alive?(pid), do: Supervisor.stop(pid, :normal)
    end

    if state.event_producer_pid && Process.alive?(state.event_producer_pid) do
      GenStage.stop(state.event_producer_pid, :normal)
    end

    :ok
  end

  # --- Internal ---

  @doc false
  def handle_server_request(config, session_id, "hooks.invoke", params) do
    output =
      CopilotSdk.SessionHooks.dispatch(
        config[:hooks],
        params["hookType"],
        params["input"],
        %{session_id: session_id}
      )

    if is_nil(output), do: %{}, else: %{"output" => output}
  end

  def handle_server_request(config, session_id, "tool.call", params) do
    tool = Enum.find(config[:tools] || [], &(&1.name == params["toolName"]))
    handler = if tool, do: tool.handler
    %{"result" => execute_tool(handler, session_id, params)}
  end

  def handle_server_request(config, session_id, "permission.request", params) do
    request = params["permissionRequest"] || params["request"] || params

    %{
      "result" =>
        execute_permission(
          config[:on_permission_request],
          session_id,
          request,
          managed_settings_enabled?(config)
        )
    }
  end

  def handle_server_request(config, session_id, "userInput.request", params) do
    execute_user_input(config[:on_user_input_request], session_id, params)
  end

  defp execute_tool(handler, session_id, params) do
    invocation = %ToolInvocation{
      session_id: session_id,
      tool_call_id: params["toolCallId"],
      tool_name: params["toolName"],
      arguments: params["arguments"]
    }

    result =
      if handler do
        handler.(invocation)
      else
        %ToolResult{result_type: :failure, text_result_for_llm: "Unknown tool"}
      end

    ToolResult.to_wire(result)
  rescue
    _ -> failed_tool_result()
  catch
    _, _ -> failed_tool_result()
  end

  defp failed_tool_result do
    ToolResult.to_wire(%ToolResult{
      result_type: :failure,
      text_result_for_llm: "Tool handler failed"
    })
  end

  defp execute_permission(handler, session_id, request, managed_settings_enabled) do
    result =
      if handler,
        do:
          handler.(request, %{
            session_id: session_id,
            managed_settings_enabled: managed_settings_enabled
          }),
        else: %PermissionRequestResult{kind: :user_not_available}

    PermissionRequestResult.to_wire(result)
  rescue
    _ -> PermissionRequestResult.to_wire(%PermissionRequestResult{kind: :user_not_available})
  catch
    _, _ -> PermissionRequestResult.to_wire(%PermissionRequestResult{kind: :user_not_available})
  end

  defp execute_user_input(nil, _session_id, _params),
    do: raise(ArgumentError, "No user input handler registered")

  defp execute_user_input(handler, session_id, params) do
    request = %CopilotSdk.UserInputRequest{
      question: params["question"],
      choices: params["choices"] || [],
      allow_freeform: params["allowFreeform"] != false
    }

    response = handler.(request, %{session_id: session_id})
    %{"answer" => response.answer, "wasFreeform" => response.was_freeform || false}
  end

  defp handle_broadcast_event(%{type: :external_tool_requested} = event, state) do
    request_id = event.data["requestId"]
    tool_name = event.data["toolName"]

    case Map.get(state.tool_handlers, tool_name) do
      nil ->
        :ok

      handler ->
        rpc = state.rpc

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          wire_result = execute_tool(handler, rpc.session_id, event.data)
          SessionRpc.handle_tool_result(rpc, request_id, wire_result)
        end)
    end
  end

  defp handle_broadcast_event(
         %{type: :permission_requested, data: %{"resolvedByHook" => true}},
         _state
       ),
       do: :ok

  defp handle_broadcast_event(%{type: :permission_requested} = event, state) do
    case state.permission_handler do
      nil ->
        :ok

      handler ->
        request_id = event.data["requestId"]
        rpc = state.rpc

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          request = event.data["permissionRequest"] || event.data

          wire_result =
            execute_permission(handler, rpc.session_id, request, state.managed_settings_enabled)

          if wire_result["kind"] != "no-result" do
            SessionRpc.handle_permission_result(rpc, request_id, wire_result)
          end
        end)
    end
  end

  defp handle_broadcast_event(%{type: :user_input_requested} = event, state) do
    case state.user_input_handler do
      nil ->
        :ok

      handler ->
        request_id = event.data["requestId"]
        rpc = state.rpc

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          wire_response = execute_user_input(handler, rpc.session_id, event.data)
          SessionRpc.handle_user_input_result(rpc, request_id, wire_response)
        end)
    end
  end

  defp handle_broadcast_event(_event, _state), do: :ok

  defp build_send_params(options, session_id) when is_map(options) do
    %{"sessionId" => session_id}
    |> maybe_put("prompt", options[:prompt] || options["prompt"])
    |> maybe_put(
      "attachments",
      build_attachments(options[:attachments] || options["attachments"])
    )
    |> maybe_put("mode", options[:mode] || options["mode"])
    |> maybe_put("source", options[:source] || options["source"])
    |> maybe_put("displayPrompt", options[:display_prompt] || options["displayPrompt"])
    |> maybe_put("agentMode", options[:agent_mode] || options["agentMode"])
    |> maybe_put("requestHeaders", options[:request_headers] || options["requestHeaders"])
    |> maybe_put("responseFormat", response_format(options[:response_schema]))
  end

  defp response_format(nil), do: nil

  defp response_format(schema) when is_map(schema) do
    %{
      "type" => "json_schema",
      "jsonSchema" => %{"name" => "response", "strict" => true, "schema" => schema}
    }
  end

  defp build_attachments(nil), do: nil
  defp build_attachments(attachments) when is_list(attachments), do: attachments

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp result_to_ok_error({:ok, _}), do: :ok
  defp result_to_ok_error({:error, reason}), do: {:error, reason}

  defp normalize_config(%_{} = config), do: Map.from_struct(config)
  defp normalize_config(config), do: Map.new(config)

  defp managed_settings_enabled?(config) do
    config[:enable_managed_settings] == true or not is_nil(config[:managed_settings])
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp wait_for_idle(ref, monitor, last_message, deadline) do
    receive do
      {^ref, :assistant_message, event} ->
        wait_for_idle(ref, monitor, event, deadline)

      {^ref, :idle} ->
        {:ok, last_message}

      {^ref, :error, event} ->
        {:error, "Session error: #{inspect(event.data)}"}

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, {:session_closed, reason}}
    after
      remaining(deadline) ->
        {:error, :timeout}
    end
  end

  defp flush_wait_messages(ref) do
    receive do
      {^ref, _} -> flush_wait_messages(ref)
      {^ref, _, _} -> flush_wait_messages(ref)
    after
      0 -> :ok
    end
  end
end
