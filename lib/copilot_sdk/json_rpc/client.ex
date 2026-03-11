defmodule CopilotSdk.JsonRpc.Client do
  @moduledoc """
  JSON-RPC 2.0 client over an arbitrary transport (stdio Port or TCP socket).

  Handles:
  - Sending requests (with unique IDs) and matching responses
  - Sending notifications (no ID, no response expected)
  - Receiving notifications from the server
  - Receiving server-to-client requests and dispatching to registered handlers
  - Content-Length framing via `CopilotSdk.JsonRpc.Framing`
  """

  use GenServer
  require Logger

  alias CopilotSdk.JsonRpc.Framing

  defstruct [
    :transport,
    :transport_ref,
    :notification_handler,
    buffer: "",
    next_id: 1,
    pending: %{},
    request_handlers: %{}
  ]

  # --- Public API ---

  @doc """
  Start the JSON-RPC client GenServer.

  Options:
    - `:transport` - `{:port, port_ref}` or `{:tcp, socket}`
    - `:notification_handler` - `fn(method, params) -> :ok`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    transport = Keyword.fetch!(opts, :transport)
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)

    # Transfer socket ownership from caller to the GenServer
    case transport do
      {:tcp, socket} ->
        :gen_tcp.controlling_process(socket, pid)
        # Now tell the GenServer to activate the socket
        GenServer.call(pid, :activate_socket)

      {:port, _port} ->
        :ok
    end

    {:ok, pid}
  end

  @doc "Send a JSON-RPC request and wait for the response."
  @spec request(pid(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(pid, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(pid, {:request, method, params}, timeout)
  end

  @doc "Send a JSON-RPC notification (no response expected)."
  @spec notify(pid(), String.t(), map()) :: :ok
  def notify(pid, method, params \\ %{}) do
    GenServer.cast(pid, {:notify, method, params})
  end

  @doc "Register a handler for server-to-client requests."
  @spec set_request_handler(pid(), String.t(), (map() -> term())) :: :ok
  def set_request_handler(pid, method, handler) when is_function(handler, 1) do
    GenServer.call(pid, {:set_request_handler, method, handler})
  end

  @doc "Set the notification handler."
  @spec set_notification_handler(pid(), (String.t(), map() -> :ok)) :: :ok
  def set_notification_handler(pid, handler) when is_function(handler, 2) do
    GenServer.call(pid, {:set_notification_handler, handler})
  end

  @doc "Check if the JSON-RPC client is still alive."
  @spec alive?(pid()) :: boolean()
  def alive?(pid) do
    Process.alive?(pid)
  end

  @doc "Stop the JSON-RPC client."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    notification_handler = Keyword.get(opts, :notification_handler, fn _m, _p -> :ok end)

    transport_ref =
      case transport do
        {:port, port} ->
          Port.monitor(port)

        {:tcp, _socket} ->
          # Socket activation deferred until controlling_process is transferred
          nil
      end

    state = %__MODULE__{
      transport: transport,
      transport_ref: transport_ref,
      notification_handler: notification_handler
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:activate_socket, _from, %{transport: {:tcp, socket}} = state) do
    :inet.setopts(socket, active: true)
    {:reply, :ok, state}
  end

  def handle_call({:request, method, params}, from, state) do
    id = "req-#{state.next_id}"

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    case send_message(message, state) do
      :ok ->
        pending = Map.put(state.pending, id, from)
        {:noreply, %{state | pending: pending, next_id: state.next_id + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_request_handler, method, handler}, _from, state) do
    handlers = Map.put(state.request_handlers, method, handler)
    {:reply, :ok, %{state | request_handlers: handlers}}
  end

  def handle_call({:set_notification_handler, handler}, _from, state) do
    {:reply, :ok, %{state | notification_handler: handler}}
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    send_message(message, state)
    {:noreply, state}
  end

  # Handle data from Erlang Port (stdio)
  @impl true
  def handle_info({port, {:data, data}}, %{transport: {:port, port}} = state) do
    state = process_incoming_data(data, state)
    {:noreply, state}
  end

  # Handle data from TCP socket
  def handle_info({:tcp, socket, data}, %{transport: {:tcp, socket}} = state) do
    state = process_incoming_data(data, state)
    {:noreply, state}
  end

  # Handle Port exit
  def handle_info({:DOWN, ref, :port, _port, reason}, %{transport_ref: ref} = state) do
    Logger.warning("JSON-RPC transport port closed: #{inspect(reason)}")
    fail_all_pending(state, {:error, :transport_closed})
    {:stop, {:transport_closed, reason}, state}
  end

  # Handle TCP close
  def handle_info({:tcp_closed, socket}, %{transport: {:tcp, socket}} = state) do
    Logger.warning("JSON-RPC TCP connection closed")
    fail_all_pending(state, {:error, :transport_closed})
    {:stop, :transport_closed, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{transport: {:tcp, socket}} = state) do
    Logger.warning("JSON-RPC TCP error: #{inspect(reason)}")
    fail_all_pending(state, {:error, {:tcp_error, reason}})
    {:stop, {:tcp_error, reason}, state}
  end

  def handle_info({:send_response, response}, state) do
    send_message(response, state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    fail_all_pending(state, {:error, :shutting_down})
    :ok
  end

  # --- Internal ---

  defp send_message(message, state) do
    case Framing.encode(message) do
      {:ok, frame} ->
        case state.transport do
          {:port, port} ->
            Port.command(port, frame)
            :ok

          {:tcp, socket} ->
            :gen_tcp.send(socket, frame)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_incoming_data(data, state) do
    buffer = state.buffer <> data
    {messages, remaining} = Framing.parse(buffer)

    state = %{state | buffer: remaining}

    Enum.reduce(messages, state, fn msg, acc ->
      handle_incoming_message(msg, acc)
    end)
  end

  defp handle_incoming_message(message, state) do
    cond do
      # Response to a pending request
      Map.has_key?(message, "id") && (Map.has_key?(message, "result") || Map.has_key?(message, "error")) ->
        handle_response(message, state)

      # Server-to-client request (has id + method)
      Map.has_key?(message, "id") && Map.has_key?(message, "method") ->
        handle_server_request(message, state)

      # Notification (has method, no id)
      Map.has_key?(message, "method") ->
        handle_notification(message, state)

      true ->
        Logger.warning("Unknown JSON-RPC message: #{inspect(message)}")
        state
    end
  end

  defp handle_response(message, state) do
    id = message["id"]

    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.warning("Received response for unknown request ID: #{id}")
        state

      {from, pending} ->
        result =
          if Map.has_key?(message, "error") do
            error = message["error"]
            {:error, %{code: error["code"], message: error["message"], data: error["data"]}}
          else
            {:ok, message["result"]}
          end

        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  defp handle_server_request(message, state) do
    method = message["method"]
    params = message["params"] || %{}
    id = message["id"]

    case Map.get(state.request_handlers, method) do
      nil ->
        # Method not found - send error response
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found: #{method}"}
        }

        send_message(response, state)
        state

      handler ->
        # Execute handler asynchronously to avoid blocking the GenServer
        self_pid = self()

        Task.start(fn ->
          try do
            result = handler.(params)

            response = %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => result || %{}
            }

            send(self_pid, {:send_response, response})
          rescue
            e ->
              response = %{
                "jsonrpc" => "2.0",
                "id" => id,
                "error" => %{
                  "code" => -32000,
                  "message" => Exception.message(e)
                }
              }

              send(self_pid, {:send_response, response})
          end
        end)

        state
    end
  end

  defp handle_notification(message, state) do
    method = message["method"]
    params = message["params"] || %{}

    try do
      state.notification_handler.(method, params)
    rescue
      e -> Logger.warning("Error in notification handler for #{method}: #{inspect(e)}")
    end

    state
  end

  defp fail_all_pending(state, error) do
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, error)
    end)
  end
end
