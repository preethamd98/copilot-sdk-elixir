defmodule CopilotSdk.Client do
  @moduledoc """
  Top-level GenServer that manages the Copilot CLI server process,
  connection establishment, protocol negotiation, and session routing.
  """

  use GenServer
  import Bitwise
  require Logger

  alias CopilotSdk.{ClientOptions, JsonRpc, Session, WireFormat}
  alias CopilotSdk.Generated.ServerRpc

  @type client :: pid() | atom() | GenServer.name()

  @type t :: %__MODULE__{
          options: ClientOptions.t() | nil,
          port: port() | nil,
          socket: :gen_tcp.socket() | nil,
          json_rpc: pid() | nil,
          server_rpc: CopilotSdk.Generated.ServerRpc.t() | nil,
          session_supervisor: pid() | nil,
          task_supervisor: pid() | nil,
          negotiated_protocol_version: non_neg_integer() | nil,
          state: :disconnected | :connecting | :connected | :error,
          sessions: %{String.t() => pid()},
          lifecycle_handlers: [{reference(), function()}],
          is_external_server: boolean()
        }

  defstruct [
    :options,
    :port,
    :socket,
    :json_rpc,
    :server_rpc,
    :session_supervisor,
    :task_supervisor,
    :negotiated_protocol_version,
    state: :disconnected,
    sessions: %{},
    lifecycle_handlers: [],
    is_external_server: false
  ]

  # --- Public API ---

  @doc """
  Start a new Copilot Client.

  Accepts a keyword list of options (see `CopilotSdk.ClientOptions`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Start the client (connect to CLI server). Called automatically if auto_start is true."
  @spec start(client()) :: :ok | {:error, term()}
  def start(client) do
    GenServer.call(client, :start, 30_000)
  end

  @doc "Stop the client gracefully."
  @spec stop(client()) :: :ok
  def stop(client) do
    GenServer.call(client, :stop, 15_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Force stop the client."
  @spec force_stop(client()) :: :ok
  def force_stop(client) do
    GenServer.call(client, :force_stop, 10_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Create a new session."
  @spec create_session(client(), map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def create_session(client, config) do
    GenServer.call(client, {:create_session, config}, 30_000)
  end

  @doc "Resume an existing session."
  @spec resume_session(client(), String.t(), map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def resume_session(client, session_id, config) do
    GenServer.call(client, {:resume_session, session_id, config}, 30_000)
  end

  @doc "Delete a session."
  @spec delete_session(client(), String.t()) :: :ok | {:error, term()}
  def delete_session(client, session_id) do
    GenServer.call(client, {:delete_session, session_id})
  end

  @doc "Ping the server."
  @spec ping(client(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def ping(client, message \\ nil) do
    GenServer.call(client, {:ping, message})
  end

  @doc "Get the current client state."
  @spec get_state(client()) :: :disconnected | :connecting | :connected | :error
  def get_state(client) do
    GenServer.call(client, :get_state)
  end

  @doc "Get authentication status."
  @spec get_auth_status(client()) :: {:ok, map()} | {:error, term()}
  def get_auth_status(client) do
    GenServer.call(client, :get_auth_status)
  end

  @doc "List available models."
  @spec list_models(client()) :: {:ok, map()} | {:error, term()}
  def list_models(client) do
    GenServer.call(client, :list_models)
  end

  @doc "List sessions."
  @spec list_sessions(client(), map() | nil) :: {:ok, map()} | {:error, term()}
  def list_sessions(client, filter \\ nil) do
    GenServer.call(client, {:list_sessions, filter})
  end

  @doc "Get the last session ID."
  @spec get_last_session_id(client()) :: {:ok, map()} | {:error, term()}
  def get_last_session_id(client) do
    GenServer.call(client, :get_last_session_id)
  end

  @doc "Get the foreground session ID."
  @spec get_foreground_session_id(client()) :: {:ok, map()} | {:error, term()}
  def get_foreground_session_id(client) do
    GenServer.call(client, :get_foreground_session_id)
  end

  @doc "Set the foreground session ID."
  @spec set_foreground_session_id(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_foreground_session_id(client, session_id) do
    GenServer.call(client, {:set_foreground_session_id, session_id})
  end

  @doc "Get the ServerRpc accessor."
  @spec rpc(client()) :: CopilotSdk.Generated.ServerRpc.t() | nil
  def rpc(client) do
    GenServer.call(client, :rpc)
  end

  @doc "Get the TCP port (nil if stdio)."
  @spec actual_port(client()) :: non_neg_integer() | nil
  def actual_port(client) do
    GenServer.call(client, :actual_port)
  end

  @doc """
  Subscribe to session lifecycle events.

  Returns an unsubscribe function.
  """
  @spec on(client(), (map() -> any())) :: (-> :ok)
  def on(client, handler) when is_function(handler, 1) do
    GenServer.call(client, {:on_lifecycle, handler})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    options = ClientOptions.new(opts)
    {:ok, session_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %__MODULE__{
      options: options,
      session_supervisor: session_sup,
      task_supervisor: task_sup
    }

    if options.auto_start do
      send(self(), :auto_start)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:auto_start, state) do
    case do_start(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to auto-start Copilot client: #{inspect(reason)}")
        {:noreply, %{state | state: :error}}
    end
  end

  # Handle Port exit (forwarded from JSON-RPC client if port is still ours)
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    Logger.warning("CLI process exited with status #{status}")
    {:noreply, %{state | state: :disconnected, port: nil}}
  end

  # Handle response messages from task to send back via transport
  def handle_info({:send_response, response}, state) do
    if state.json_rpc do
      send(state.json_rpc, {:send_response, response})
    end

    {:noreply, state}
  end

  def handle_info({:notification, "session.event", params}, state) do
    session_id = params["sessionId"]
    event_data = params["event"] || params

    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.debug("Received event for unknown session: #{session_id}")

      session_pid ->
        Session.dispatch_event(session_pid, event_data)
    end

    {:noreply, state}
  end

  def handle_info({:notification, "session.lifecycle", params}, state) do
    event_type =
      case params["type"] do
        "created" -> :session_created
        "deleted" -> :session_deleted
        "updated" -> :session_updated
        _ -> :unknown
      end

    dispatch_lifecycle(state, event_type, params)
    {:noreply, state}
  end

  def handle_info({:notification, _method, _params}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    case do_start(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:force_stop, _from, state) do
    new_state = do_force_stop(state)
    {:reply, :ok, new_state}
  end

  def handle_call({:create_session, config}, _from, state) do
    case do_create_session(config, state) do
      {:ok, session_pid, new_state} -> {:reply, {:ok, session_pid}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume_session, session_id, config}, _from, state) do
    case do_resume_session(session_id, config, state) do
      {:ok, session_pid, new_state} -> {:reply, {:ok, session_pid}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    case do_delete_session(session_id, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ping, message}, _from, state) do
    if state.json_rpc do
      params = if message, do: %{"message" => message}, else: %{}
      result = JsonRpc.Client.request(state.json_rpc, "ping", params)
      {:reply, result, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_auth_status, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.get_auth_status(state.server_rpc), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:list_models, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.list_models(state.server_rpc), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:list_sessions, filter}, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.list_sessions(state.server_rpc, filter), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:get_last_session_id, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.get_last_session_id(state.server_rpc), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:get_foreground_session_id, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.get_foreground_session_id(state.server_rpc), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:set_foreground_session_id, session_id}, _from, state) do
    if state.server_rpc do
      {:reply, ServerRpc.set_foreground_session_id(state.server_rpc, session_id), state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call(:rpc, _from, state) do
    {:reply, state.server_rpc, state}
  end

  def handle_call(:actual_port, _from, state) do
    {:reply, state.options.port, state}
  end

  def handle_call({:on_lifecycle, handler}, _from, state) do
    ref = make_ref()
    handlers = [{ref, handler} | state.lifecycle_handlers]

    unsub = fn ->
      GenServer.cast(self(), {:remove_lifecycle_handler, ref})
    end

    {:reply, unsub, %{state | lifecycle_handlers: handlers}}
  end

  @impl true
  def handle_cast({:remove_lifecycle_handler, ref}, state) do
    handlers = Enum.reject(state.lifecycle_handlers, fn {r, _} -> r == ref end)
    {:noreply, %{state | lifecycle_handlers: handlers}}
  end

  @impl true
  def terminate(_reason, state) do
    do_force_stop(state)
    :ok
  end

  # --- Internal ---

  defp do_start(state) do
    cond do
      state.options.cli_url ->
        connect_to_external_server(state)

      state.options.use_stdio ->
        start_cli_stdio(state)

      true ->
        start_cli_tcp(state)
    end
  end

  defp start_cli_stdio(state) do
    cli_path = resolve_cli_path(state.options)
    args = build_cli_args(state.options) ++ ["--stdio"]
    {executable, spawn_args} = build_spawn_command(cli_path, args)

    env_list = build_env(state.options)

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, spawn_args}, {:env, env_list}]
      |> maybe_add_cd(state.options.cwd)

    try do
      port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)

      {:ok, json_rpc} =
        JsonRpc.Client.start_link(
          transport: {:port, port},
          notification_handler: notification_handler(self())
        )

      # Transfer Port ownership to the JSON-RPC client so it receives
      # data directly (avoiding GenServer re-entrancy during verify_protocol_version)
      Port.connect(port, json_rpc)

      server_rpc = ServerRpc.new(json_rpc)

      new_state = %{
        state
        | port: port,
          json_rpc: json_rpc,
          server_rpc: server_rpc,
          state: :connecting
      }

      case verify_protocol_version(new_state) do
        {:ok, version} ->
          {:ok, %{new_state | state: :connected, negotiated_protocol_version: version}}

        {:error, reason} ->
          do_force_stop(new_state)
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp start_cli_tcp(state) do
    cli_path = resolve_cli_path(state.options)
    port_num = state.options.port
    args = build_cli_args(state.options) ++ ["--port", Integer.to_string(port_num)]
    {executable, spawn_args} = build_spawn_command(cli_path, args)
    env_list = build_env(state.options)

    port_opts =
      [:binary, :exit_status, {:args, spawn_args}, {:env, env_list}, {:line, 1024}]
      |> maybe_add_cd(state.options.cwd)

    port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)

    case wait_for_port_announcement(port, 15_000) do
      {:ok, tcp_port} ->
        connect_tcp(state, "127.0.0.1", tcp_port, port)

      {:error, reason} ->
        Port.close(port)
        {:error, reason}
    end
  end

  defp connect_to_external_server(state) do
    {host, port} = parse_cli_url(state.options.cli_url)
    connect_tcp(%{state | is_external_server: true}, host, port, nil)
  end

  defp connect_tcp(state, host, port, cli_port) do
    case :gen_tcp.connect(to_charlist(host), port, [:binary, active: true], 10_000) do
      {:ok, socket} ->
        {:ok, json_rpc} =
          JsonRpc.Client.start_link(
            transport: {:tcp, socket},
            notification_handler: notification_handler(self())
          )

        server_rpc = ServerRpc.new(json_rpc)

        new_state = %{
          state
          | port: cli_port,
            socket: socket,
            json_rpc: json_rpc,
            server_rpc: server_rpc,
            state: :connecting
        }

        case verify_protocol_version(new_state) do
          {:ok, version} ->
            {:ok, %{new_state | state: :connected, negotiated_protocol_version: version}}

          {:error, reason} ->
            do_force_stop(new_state)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:tcp_connect_failed, reason}}
    end
  end

  defp verify_protocol_version(state) do
    case JsonRpc.Client.request(state.json_rpc, "ping", %{}, timeout: 10_000) do
      {:ok, response} ->
        server_version = response["protocolVersion"]
        min_version = CopilotSdk.SdkProtocolVersion.min()
        max_version = CopilotSdk.SdkProtocolVersion.get()

        cond do
          is_nil(server_version) ->
            {:error, "Server does not report a protocol version"}

          server_version < min_version or server_version > max_version ->
            {:error,
             "Protocol version mismatch: SDK supports #{min_version}-#{max_version}, server reports #{server_version}"}

          true ->
            {:ok, server_version}
        end

      {:error, reason} ->
        {:error, {:ping_failed, reason}}
    end
  end

  defp do_create_session(config, state) do
    if state.state != :connected do
      {:error, :not_connected}
    else
      session_id = config[:session_id] || generate_uuid()
      payload = WireFormat.build_session_payload(config, session_id)

      {:ok, session_pid} =
        DynamicSupervisor.start_child(
          state.session_supervisor,
          {Session,
           %{session_id: session_id, json_rpc_pid: state.json_rpc, config: config}}
        )

      sessions = Map.put(state.sessions, session_id, session_pid)
      state = %{state | sessions: sessions}

      case JsonRpc.Client.request(state.json_rpc, "session.create", payload) do
        {:ok, response} ->
          Session.set_workspace_path(session_pid, response["workspacePath"])
          dispatch_lifecycle(state, :session_created, %{session_id: session_id})
          {:ok, session_pid, state}

        {:error, reason} ->
          DynamicSupervisor.terminate_child(state.session_supervisor, session_pid)
          _sessions = Map.delete(state.sessions, session_id)
          {:error, reason}
      end
    end
  end

  defp do_resume_session(session_id, config, state) do
    if state.state != :connected do
      {:error, :not_connected}
    else
      config = Map.put(config, :session_id, session_id)
      payload = WireFormat.build_session_payload(config, session_id)

      {:ok, session_pid} =
        DynamicSupervisor.start_child(
          state.session_supervisor,
          {Session,
           %{session_id: session_id, json_rpc_pid: state.json_rpc, config: config}}
        )

      sessions = Map.put(state.sessions, session_id, session_pid)
      state = %{state | sessions: sessions}

      case JsonRpc.Client.request(state.json_rpc, "session.resume", payload) do
        {:ok, response} ->
          Session.set_workspace_path(session_pid, response["workspacePath"])
          {:ok, session_pid, state}

        {:error, reason} ->
          DynamicSupervisor.terminate_child(state.session_supervisor, session_pid)
          _sessions = Map.delete(state.sessions, session_id)
          {:error, reason}
      end
    end
  end

  defp do_delete_session(session_id, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:error, :session_not_found}

      session_pid ->
        Session.disconnect(session_pid)
        DynamicSupervisor.terminate_child(state.session_supervisor, session_pid)
        sessions = Map.delete(state.sessions, session_id)
        dispatch_lifecycle(state, :session_deleted, %{session_id: session_id})
        {:ok, %{state | sessions: sessions}}
    end
  end

  defp do_stop(state) do
    # Disconnect all sessions
    Enum.each(state.sessions, fn {_id, pid} ->
      try do
        Session.disconnect(pid)
      catch
        _, _ -> :ok
      end
    end)

    do_force_stop(state)
  end

  defp do_force_stop(state) do
    # Stop JSON-RPC client
    if state.json_rpc && Process.alive?(state.json_rpc) do
      JsonRpc.Client.stop(state.json_rpc)
    end

    # Close TCP socket
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    # Close Port
    if state.port && is_port(state.port) do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    %{
      state
      | state: :disconnected,
        port: nil,
        socket: nil,
        json_rpc: nil,
        server_rpc: nil,
        sessions: %{},
        negotiated_protocol_version: nil
    }
  end

  defp notification_handler(client_pid) do
    fn method, params ->
      send(client_pid, {:notification, method, params})
    end
  end

  defp dispatch_lifecycle(state, event_type, data) do
    Enum.each(state.lifecycle_handlers, fn {_ref, handler} ->
      try do
        handler.(%{type: event_type, data: data})
      rescue
        e -> Logger.warning("Lifecycle handler error: #{inspect(e)}")
      end
    end)
  end

  defp resolve_cli_path(options) do
    cond do
      options.cli_path != nil ->
        options.cli_path

      (env_path = System.get_env("COPILOT_CLI_PATH")) != nil ->
        env_path

      true ->
        raise RuntimeError,
              "Copilot CLI not found. Set cli_path option or COPILOT_CLI_PATH env var."
    end
  end

  defp build_spawn_command(cli_path, args) do
    if String.ends_with?(cli_path, ".js") do
      # Prefer homebrew node, then system node
      node_path =
        cond do
          File.exists?("/opt/homebrew/bin/node") -> "/opt/homebrew/bin/node"
          (found = System.find_executable("node")) != nil -> found
          true -> "node"
        end

      {node_path, [cli_path | args]}
    else
      {cli_path, args}
    end
  end

  defp build_cli_args(options) do
    base_args =
      (options.cli_args || []) ++
        ["--headless", "--no-auto-update", "--log-level", options.log_level]

    auth_args =
      cond do
        options.github_token != nil ->
          ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"]

        options.use_logged_in_user == false ->
          ["--no-auto-login"]

        true ->
          []
      end

    base_args ++ auth_args
  end

  defp build_env(options) do
    base_env = options.env || %{}

    env =
      if options.github_token do
        Map.put(base_env, "COPILOT_SDK_AUTH_TOKEN", options.github_token)
      else
        base_env
      end

    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp maybe_add_cd(opts, nil), do: opts
  defp maybe_add_cd(opts, cwd), do: [{:cd, to_charlist(cwd)} | opts]

  defp parse_cli_url(url) do
    uri = URI.parse(url)
    host = uri.host || "127.0.0.1"
    port = uri.port || 3000
    {host, port}
  end

  defp wait_for_port_announcement(port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_port_loop(port, deadline, "")
  end

  defp wait_for_port_loop(port, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          full = buffer <> line

          case Regex.run(~r/listening on port (\d+)/i, full) do
            [_, port_str] -> {:ok, String.to_integer(port_str)}
            nil -> wait_for_port_loop(port, deadline, "")
          end

        {^port, {:data, {:noeol, chunk}}} ->
          wait_for_port_loop(port, deadline, buffer <> chunk)

        {^port, {:exit_status, status}} ->
          {:error, {:cli_exited, status}}
      after
        min(remaining, 1000) ->
          wait_for_port_loop(port, deadline, buffer)
      end
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    c = c &&& 0x0FFF ||| 0x4000
    d = d &&& 0x3FFF ||| 0x8000

    [a, b, c, d, e]
    |> Enum.map_join("-", fn
      part when part < 0x10000 ->
        part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

      part when part < 0x1000000000000 ->
        part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")

      part ->
        part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
    end)
  end
end
