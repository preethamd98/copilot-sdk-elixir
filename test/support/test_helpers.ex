defmodule CopilotSdk.Test.MockJsonRpcServer do
  @moduledoc """
  A mock JSON-RPC server that responds over an in-process Port-like interface.

  Used to test the Client and Session without a real CLI process.
  Communicates via a pair of linked processes using send/receive.
  """

  alias CopilotSdk.JsonRpc.Framing

  defstruct [:pid, :port, :responses, :calls]

  @doc """
  Start a mock JSON-RPC server that creates a pair of connected pipes.

  Returns `{:ok, %{server: server_pid, transport: {:port, port}}}`.
  The mock server records all incoming requests and responds with pre-configured
  responses.

  Options:
    - `:protocol_version` - Version to return in ping response (default: 3)
    - `:on_request` - Optional function `fn(method, params) -> response` for custom handling
  """
  def start(opts \\ []) do
    protocol_version = Keyword.get(opts, :protocol_version, 3)
    on_request = Keyword.get(opts, :on_request)
    test_pid = self()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server_pid =
      spawn_link(fn ->
        {:ok, accept_socket} = :gen_tcp.accept(listen, 5000)
        :gen_tcp.close(listen)
        # Tell the test process our server-side socket
        send(test_pid, {:server_socket, self(), accept_socket})
        mock_server_loop(accept_socket, protocol_version, on_request, test_pid, "")
      end)

    {:ok, client_socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)

    # Wait for the server to tell us its socket
    server_socket =
      receive do
        {:server_socket, ^server_pid, socket} -> socket
      after
        5000 -> raise "Mock server didn't report its socket"
      end

    {:ok,
     %{
       server_pid: server_pid,
       transport: {:tcp, client_socket},
       socket: client_socket,
       server_socket: server_socket,
       listen_socket: listen
     }}
  end

  defp mock_server_loop(socket, protocol_version, on_request, test_pid, buffer) do
    # Use active mode so we can also receive messages from test process
    :inet.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        buffer = buffer <> data
        {messages, remaining} = Framing.parse(buffer)

        Enum.each(messages, fn msg ->
          send(test_pid, {:mock_rpc_call, msg["method"], msg["params"]})
          response = build_response(msg, protocol_version, on_request)

          if response do
            {:ok, frame} = Framing.encode(response)
            :gen_tcp.send(socket, frame)
          end
        end)

        mock_server_loop(socket, protocol_version, on_request, test_pid, remaining)

      {:tcp_closed, ^socket} ->
        :ok

      {:send_notification, method, params} ->
        message = %{
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => params
        }

        {:ok, frame} = Framing.encode(message)
        :gen_tcp.send(socket, frame)
        mock_server_loop(socket, protocol_version, on_request, test_pid, buffer)
    after
      30_000 ->
        :ok
    end
  end

  defp build_response(msg, protocol_version, on_request) do
    id = msg["id"]

    # Notifications don't get responses
    if is_nil(id) do
      nil
    else
      method = msg["method"]
      params = msg["params"] || %{}

      result =
        if on_request do
          case on_request.(method, params) do
            nil -> default_response(method, params, protocol_version)
            result -> result
          end
        else
          default_response(method, params, protocol_version)
        end

      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result
      }
    end
  end

  defp default_response("ping", params, protocol_version) do
    message = params["message"]

    %{
      "message" => if(message, do: "pong: #{message}", else: "pong"),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "protocolVersion" => protocol_version
    }
  end

  defp default_response("session.create", params, _pv) do
    %{
      "sessionId" => params["sessionId"],
      "workspacePath" => nil
    }
  end

  defp default_response("session.resume", params, _pv) do
    %{
      "sessionId" => params["sessionId"],
      "workspacePath" => nil
    }
  end

  defp default_response("session.destroy", _params, _pv), do: %{}

  defp default_response("session.abort", _params, _pv), do: %{}

  defp default_response("session.send", params, _pv) do
    %{
      "messageId" => "msg-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}",
      "sessionId" => params["sessionId"]
    }
  end

  defp default_response("session.log", _params, _pv), do: %{}

  defp default_response("session.model.switchTo", _params, _pv), do: %{}

  defp default_response("session.getMessages", _params, _pv), do: %{"messages" => []}

  defp default_response("getAuthStatus", _params, _pv) do
    %{"authenticated" => true, "user" => "test-user"}
  end

  defp default_response("models.list", _params, _pv) do
    %{"models" => [%{"name" => "gpt-4", "id" => "gpt-4"}]}
  end

  defp default_response("sessions.list", _params, _pv), do: %{"sessions" => []}

  defp default_response("sessions.getLastSessionId", _params, _pv), do: %{"sessionId" => nil}

  defp default_response("sessions.getForegroundSessionId", _params, _pv),
    do: %{"sessionId" => nil}

  defp default_response("sessions.setForegroundSessionId", _params, _pv), do: %{}

  defp default_response("session.tools.handlePendingToolCall", _params, _pv), do: %{}

  defp default_response("session.permissions.handlePendingPermissionRequest", _params, _pv),
    do: %{}

  defp default_response("session.userInput.handlePendingUserInputRequest", _params, _pv),
    do: %{}

  defp default_response("session.hooks.handlePendingHookInvocation", _params, _pv), do: %{}

  defp default_response(_method, _params, _pv), do: %{}

  @doc """
  Send a notification from the mock server to the client.

  Use `mock.server_pid` to send through the server process.
  """
  def send_notification(server_pid, method, params) when is_pid(server_pid) do
    send(server_pid, {:send_notification, method, params})
    :ok
  end
end

defmodule CopilotSdk.Test.Helpers do
  @moduledoc "Test helper functions."

  alias CopilotSdk.Test.MockJsonRpcServer

  @doc """
  Start a test client backed by a mock JSON-RPC server.

  Returns `{:ok, client_pid, mock_info}`.
  """
  def start_test_client(opts \\ []) do
    {:ok, mock} = MockJsonRpcServer.start(opts)

    {:ok, json_rpc} =
      CopilotSdk.JsonRpc.Client.start_link(
        transport: mock.transport,
        notification_handler: fn _method, _params -> :ok end
      )

    {json_rpc, mock}
  end

  @doc "Start a test session with a mock JSON-RPC client."
  def start_test_session(opts \\ []) do
    {:ok, mock} = MockJsonRpcServer.start(opts)

    {:ok, json_rpc} =
      CopilotSdk.JsonRpc.Client.start_link(
        transport: mock.transport,
        notification_handler: fn _method, _params -> :ok end
      )

    session_id = Keyword.get(opts, :session_id, "test-session-#{System.unique_integer([:positive])}")

    config =
      Keyword.get(opts, :config, %{})
      |> Map.merge(%{
        on_permission_request:
          Keyword.get(opts, :on_permission_request, &CopilotSdk.PermissionHandler.approve_all/2),
        on_user_input_request: Keyword.get(opts, :on_user_input_request),
        hooks: Keyword.get(opts, :hooks),
        tools: Keyword.get(opts, :tools),
        on_event: Keyword.get(opts, :on_event)
      })

    {:ok, session} =
      CopilotSdk.Session.start_link(%{
        session_id: session_id,
        json_rpc_pid: json_rpc,
        config: config
      })

    {:ok, session, %{json_rpc: json_rpc, mock: mock, session_id: session_id}}
  end

  @doc "Build a simple idle event map."
  def idle_event do
    %{
      "type" => "session.idle",
      "data" => %{},
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Build an assistant message event map."
  def assistant_message_event(content \\ "Hello!") do
    %{
      "type" => "assistant.message",
      "data" => %{"content" => content, "messageId" => "msg-1"},
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Build a session error event map."
  def session_error_event(message \\ "Something went wrong") do
    %{
      "type" => "session.error",
      "data" => %{"message" => message},
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Build an external tool requested event map."
  def tool_requested_event(tool_name, arguments \\ %{}) do
    %{
      "type" => "external_tool.requested",
      "data" => %{
        "requestId" => "req-#{System.unique_integer([:positive])}",
        "toolName" => tool_name,
        "toolCallId" => "tc-#{System.unique_integer([:positive])}",
        "arguments" => arguments
      },
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Build a permission requested event map."
  def permission_requested_event do
    %{
      "type" => "permission.requested",
      "data" => %{
        "requestId" => "req-#{System.unique_integer([:positive])}",
        "toolName" => "some_tool",
        "action" => "execute"
      },
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Build a user input requested event map."
  def user_input_requested_event(question \\ "Continue?") do
    %{
      "type" => "user_input.requested",
      "data" => %{
        "requestId" => "req-#{System.unique_integer([:positive])}",
        "question" => question,
        "choices" => ["yes", "no"],
        "allowFreeform" => true
      },
      "id" => "evt-#{System.unique_integer([:positive])}",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
