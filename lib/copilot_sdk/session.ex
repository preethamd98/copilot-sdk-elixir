defmodule CopilotSdk.Session do
  @moduledoc """
  Per-conversation GenServer that manages event dispatch, message sending,
  and the send_and_wait coordination pattern.
  """

  use GenServer
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
    :on_event
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
    monitor_ref = Process.monitor(consumer_pid)

    fn ->
      if Process.alive?(consumer_pid) do
        GenStage.stop(consumer_pid, :normal)

        # Wait for the process to actually terminate
        receive do
          {:DOWN, ^monitor_ref, :process, ^consumer_pid, _} -> :ok
        after
          1000 -> :ok
        end
      else
        Process.demonitor(monitor_ref, [:flush])
      end
    end
  end

  @doc "Dispatch an event to this session (called by the Client)."
  @spec dispatch_event(session(), map()) :: :ok
  def dispatch_event(session, event_data) do
    GenServer.cast(session, {:dispatch_event, event_data})
  end

  @doc "Send a message to this session."
  @spec send_message(session(), map() | keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_message(session, options) do
    GenServer.call(session, {:send, options})
  end

  @doc """
  Send a message and wait for session.idle.

  Returns `{:ok, last_assistant_message}` or `{:error, reason}`.
  """
  @spec send_and_wait(session(), map() | keyword(), keyword()) ::
          {:ok, SessionEvent.t() | nil} | {:error, term()}
  def send_and_wait(session, options, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    caller = self()
    ref = make_ref()

    unsubscribe =
      on(session, fn event ->
        case event.type do
          :assistant_message ->
            send(caller, {ref, :assistant_message, event})

          :session_idle ->
            send(caller, {ref, :idle})

          :session_error ->
            send(caller, {ref, :error, event})

          _ ->
            :ok
        end
      end)

    try do
      {:ok, _message_id} = send_message(session, options)
      wait_for_idle(ref, nil, timeout)
    after
      unsubscribe.()
    end
  end

  @doc "Disconnect this session."
  @spec disconnect(session()) :: :ok | {:error, term()}
  def disconnect(session) do
    GenServer.call(session, :disconnect)
  end

  @doc "Abort the current operation."
  @spec abort(session()) :: :ok | {:error, term()}
  def abort(session) do
    GenServer.call(session, :abort)
  end

  @doc "Change the model for this session."
  @spec set_model(session(), String.t()) :: :ok | {:error, term()}
  def set_model(session, model) do
    GenServer.call(session, {:set_model, model})
  end

  @doc "Log a message to the session timeline."
  @spec log(session(), String.t(), keyword()) :: :ok | {:error, term()}
  def log(session, message, opts \\ []) do
    GenServer.call(session, {:log, message, opts})
  end

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
    config = init_arg[:config] || %{}

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
      on_event: config[:on_event] || config["on_event"]
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

  def handle_call({:send, options}, _from, state) do
    params = build_send_params(options, state.session_id)

    case CopilotSdk.JsonRpc.Client.request(state.json_rpc_pid, "session.send", params) do
      {:ok, result} ->
        message_id = result["messageId"] || result["id"]
        {:reply, {:ok, message_id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    result = SessionRpc.destroy(state.rpc)
    {:reply, result_to_ok_error(result), state}
  end

  def handle_call(:abort, _from, state) do
    result = SessionRpc.abort(state.rpc)
    {:reply, result_to_ok_error(result), state}
  end

  def handle_call({:set_model, model}, _from, state) do
    result = SessionRpc.switch_model(state.rpc, model)
    {:reply, result_to_ok_error(result), state}
  end

  def handle_call({:log, message, opts}, _from, state) do
    opts_map = %{level: Keyword.get(opts, :level), ephemeral: Keyword.get(opts, :ephemeral)}
    result = SessionRpc.log(state.rpc, message, opts_map)
    {:reply, result_to_ok_error(result), state}
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
    if state.event_producer_pid && Process.alive?(state.event_producer_pid) do
      GenStage.stop(state.event_producer_pid, :normal)
    end

    :ok
  end

  # --- Internal ---

  defp handle_broadcast_event(%{type: :external_tool_requested} = event, state) do
    request_id = event.data["requestId"]
    tool_name = event.data["toolName"]

    case Map.get(state.tool_handlers, tool_name) do
      nil ->
        :ok

      handler ->
        rpc = state.rpc

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          invocation = %ToolInvocation{
            session_id: rpc.session_id,
            tool_call_id: event.data["toolCallId"],
            tool_name: tool_name,
            arguments: event.data["arguments"]
          }

          result = handler.(invocation)
          wire_result = ToolResult.to_wire(result)
          SessionRpc.handle_tool_result(rpc, request_id, wire_result)
        end)
    end
  end

  defp handle_broadcast_event(%{type: :permission_requested} = event, state) do
    case state.permission_handler do
      nil ->
        :ok

      handler ->
        request_id = event.data["requestId"]
        rpc = state.rpc

        Task.Supervisor.start_child(state.task_supervisor, fn ->
          request = event.data
          invocation = %{session_id: rpc.session_id}
          result = handler.(request, invocation)
          wire_result = PermissionRequestResult.to_wire(result)
          SessionRpc.handle_permission_result(rpc, request_id, wire_result)
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
          request = %CopilotSdk.UserInputRequest{
            question: event.data["question"],
            choices: event.data["choices"] || [],
            allow_freeform: event.data["allowFreeform"] != false
          }

          invocation = %{session_id: rpc.session_id}
          response = handler.(request, invocation)

          wire_response = %{
            "answer" => response.answer,
            "wasFreeform" => response.was_freeform || false
          }

          SessionRpc.handle_user_input_result(rpc, request_id, wire_response)
        end)
    end
  end

  defp handle_broadcast_event(_event, _state), do: :ok

  defp build_send_params(options, session_id) when is_map(options) do
    %{"sessionId" => session_id}
    |> maybe_put("prompt", options[:prompt] || options["prompt"])
    |> maybe_put("attachments", build_attachments(options[:attachments] || options["attachments"]))
    |> maybe_put("mode", options[:mode] || options["mode"])
  end

  defp build_attachments(nil), do: nil
  defp build_attachments(attachments) when is_list(attachments), do: attachments

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp result_to_ok_error({:ok, _}), do: :ok
  defp result_to_ok_error({:error, reason}), do: {:error, reason}

  defp wait_for_idle(ref, last_message, timeout) do
    receive do
      {^ref, :assistant_message, event} ->
        wait_for_idle(ref, event, timeout)

      {^ref, :idle} ->
        {:ok, last_message}

      {^ref, :error, event} ->
        {:error, "Session error: #{inspect(event.data)}"}
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
