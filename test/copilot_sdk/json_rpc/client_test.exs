defmodule CopilotSdk.JsonRpc.ClientTest do
  use ExUnit.Case

  alias CopilotSdk.JsonRpc.Client
  alias CopilotSdk.JsonRpc.Framing
  alias CopilotSdk.Test.MockJsonRpcServer

  describe "request/3" do
    test "sends request and receives response" do
      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      assert {:ok, result} = Client.request(client, "ping", %{})
      assert result["message"] == "pong"
      assert result["protocolVersion"] == 3
      Client.stop(client)
    end

    test "sends request with params" do
      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      assert {:ok, result} = Client.request(client, "ping", %{"message" => "hello"})
      assert result["message"] == "pong: hello"
      Client.stop(client)
    end

    test "handles custom responses" do
      {:ok, mock} =
        MockJsonRpcServer.start(
          on_request: fn
            "custom.method", _params -> %{"custom" => true}
            _, _ -> nil
          end
        )

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      assert {:ok, %{"custom" => true}} = Client.request(client, "custom.method", %{})
      Client.stop(client)
    end

    test "returns timeout without exiting the caller or retaining pending requests" do
      {client, socket} = start_tcp_client()

      for timeout <- [0, 1, 5, 10, 20] do
        assert {:error, :timeout} = Client.request(client, "slow", %{}, timeout: timeout)
        assert receive_frame(socket)["method"] == "slow"
        assert :sys.get_state(client).pending == %{}
      end

      assert Client.alive?(client)
    end

    @tag capture_log: true
    test "ignores late responses after a timeout" do
      {client, socket} = start_tcp_client()
      assert {:error, :timeout} = Client.request(client, "slow", %{}, timeout: 0)
      timed_out = receive_frame(socket)

      request = Task.async(fn -> Client.request(client, "next", %{}) end)
      next = receive_frame(socket)

      send_frame(socket, %{"jsonrpc" => "2.0", "id" => timed_out["id"], "result" => "late"})
      send_frame(socket, %{"jsonrpc" => "2.0", "id" => next["id"], "result" => "current"})

      assert Task.await(request) == {:ok, "current"}
      assert :sys.get_state(client).pending == %{}
    end

    test "supports an infinite timeout without scheduling a timer" do
      {client, socket} = start_tcp_client()
      request = Task.async(fn -> Client.request(client, "slow", %{}, timeout: :infinity) end)
      message = receive_frame(socket)

      assert {_from, nil} = Map.fetch!(:sys.get_state(client).pending, message["id"])
      assert Task.yield(request, 10) == nil

      send_frame(socket, %{"jsonrpc" => "2.0", "id" => message["id"], "result" => false})

      assert Task.await(request) == {:ok, false}
      assert :sys.get_state(client).pending == %{}
    end

    test "cancels timers when receiving successful or error responses" do
      {client, socket} = start_tcp_client()

      for {response, expected} <- [
            {%{"result" => nil}, {:ok, nil}},
            {%{"error" => %{"code" => -32000, "message" => "failed"}},
             {:error, %{code: -32000, message: "failed", data: nil}}}
          ] do
        request = Task.async(fn -> Client.request(client, "test", %{}, timeout: 60_000) end)
        message = receive_frame(socket)
        {_from, timer} = Map.fetch!(:sys.get_state(client).pending, message["id"])
        assert is_integer(Process.read_timer(timer))

        send_frame(socket, Map.merge(response, %{"jsonrpc" => "2.0", "id" => message["id"]}))

        assert Task.await(request) == expected
        assert Process.read_timer(timer) == false
        assert :sys.get_state(client).pending == %{}

        send(client, {:request_timeout, message["id"]})
        assert :sys.get_state(client).pending == %{}
      end
    end
  end

  describe "notify/3" do
    test "sends notification without expecting response" do
      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      assert :ok = Client.notify(client, "some.notification", %{"data" => "test"})
      # Give it a moment to send
      Process.sleep(50)
      Client.stop(client)
    end
  end

  describe "notification_handler" do
    test "receives notifications from server" do
      test_pid = self()

      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn method, params ->
            send(test_pid, {:notification, method, params})
          end
        )

      # Send a notification from the mock server to the client
      MockJsonRpcServer.send_notification(mock.server_pid, "test.event", %{"foo" => "bar"})

      assert_receive {:notification, "test.event", %{"foo" => "bar"}}, 2000
      Client.stop(client)
    end
  end

  describe "set_request_handler/3" do
    test "handles server-to-client requests" do
      test_pid = self()
      {client, socket} = start_tcp_client()

      Client.set_request_handler(client, "tool.call", fn params ->
        send(test_pid, {:tool_call, params})
        %{"result" => "handled"}
      end)

      send_frame(socket, %{
        "jsonrpc" => "2.0",
        "id" => "tool-1",
        "method" => "tool.call",
        "params" => %{"name" => "test"}
      })

      assert_receive {:tool_call, %{"name" => "test"}}, 1000

      assert receive_frame(socket) == %{
               "jsonrpc" => "2.0",
               "id" => "tool-1",
               "result" => %{"result" => "handled"}
             }

      assert Client.alive?(client)
    end

    test "preserves false and nil handler results" do
      {client, socket} = start_tcp_client()

      for result <- [false, nil] do
        Client.set_request_handler(client, "test", fn _params -> result end)
        send_frame(socket, %{"jsonrpc" => "2.0", "id" => "server-1", "method" => "test"})

        assert receive_frame(socket) == %{
                 "jsonrpc" => "2.0",
                 "id" => "server-1",
                 "result" => result
               }
      end
    end

    test "returns JSON-RPC errors for handler raises, throws, and exits" do
      {client, socket} = start_tcp_client()

      for {handler, message} <- [
            {fn _ -> raise "handler failed" end, "handler failed"},
            {fn _ -> throw(:handler_failed) end, "** (throw) :handler_failed"},
            {fn _ -> exit(:handler_failed) end, "** (exit) :handler_failed"}
          ] do
        Client.set_request_handler(client, "test", handler)
        send_frame(socket, %{"jsonrpc" => "2.0", "id" => "server-1", "method" => "test"})

        assert receive_frame(socket) == %{
                 "jsonrpc" => "2.0",
                 "id" => "server-1",
                 "error" => %{"code" => -32000, "message" => message}
               }

        assert Client.alive?(client)
      end
    end

    test "supervises asynchronous handlers and terminates them when stopped" do
      test_pid = self()
      {client, socket} = start_tcp_client()
      supervisor = :sys.get_state(client).task_supervisor

      Client.set_request_handler(client, "slow", fn _params ->
        Process.flag(:trap_exit, true)
        send(test_pid, {:handler_started, self()})

        receive do
          :finish -> %{}
        end
      end)

      send_frame(socket, %{"jsonrpc" => "2.0", "id" => "server-1", "method" => "slow"})
      assert_receive {:handler_started, handler}, 1000
      assert handler in Task.Supervisor.children(supervisor)
      monitor = Process.monitor(handler)

      assert :ok = Client.notify(client, "still.responsive")
      assert receive_frame(socket)["method"] == "still.responsive"

      assert :ok = Client.stop(client)
      assert_receive {:DOWN, ^monitor, :process, ^handler, :killed}, 1000
      refute Process.alive?(supervisor)
    end
  end

  describe "alive?/1 and stop/1" do
    test "reports alive status correctly" do
      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      assert Client.alive?(client)
      Client.stop(client)
      Process.sleep(50)
      refute Client.alive?(client)
    end

    test "closes TCP and fails pending requests once while cancelling timers" do
      {client, socket} = start_tcp_client()
      {finite_ref, timer} = queue_request(client, socket, 60_000)
      {infinite_ref, nil} = queue_request(client, socket, :infinity)

      assert :ok = Client.stop(client)

      assert_receive {^finite_ref, {:error, :shutting_down}}
      assert_receive {^infinite_ref, {:error, :shutting_down}}
      refute_receive {^finite_ref, _}
      refute_receive {^infinite_ref, _}
      assert Process.read_timer(timer) == false
      assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
    end

    @tag capture_log: true
    test "fails pending requests only once on TCP closure" do
      test_pid = self()
      {client, socket} = start_tcp_client()

      Client.set_request_handler(client, "slow", fn _params ->
        send(test_pid, {:handler_started, self()})

        receive do
          :finish -> %{}
        end
      end)

      send_frame(socket, %{"jsonrpc" => "2.0", "id" => "server-1", "method" => "slow"})
      assert_receive {:handler_started, handler}, 1000
      handler_monitor = Process.monitor(handler)
      {reply_ref, timer} = queue_request(client, socket, 60_000)
      monitor = Process.monitor(client)

      :gen_tcp.close(socket)

      assert_receive {^reply_ref, {:error, :transport_closed}}, 1000
      assert_receive {:DOWN, ^monitor, :process, ^client, :transport_closed}, 1000
      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, :killed}, 1000
      refute_receive {^reply_ref, _}
      assert Process.read_timer(timer) == false
    end

    @tag capture_log: true
    test "closes TCP and fails pending requests only once on a TCP error" do
      {client, socket} = start_tcp_client()
      {reply_ref, timer} = queue_request(client, socket, 60_000)
      {:tcp, client_socket} = :sys.get_state(client).transport
      monitor = Process.monitor(client)

      send(client, {:tcp_error, client_socket, :econnreset})

      assert_receive {^reply_ref, {:error, {:tcp_error, :econnreset}}}, 1000
      assert_receive {:DOWN, ^monitor, :process, ^client, {:tcp_error, :econnreset}}, 1000
      refute_receive {^reply_ref, _}
      assert Process.read_timer(timer) == false
      assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
    end

    test "closes an owned port when stopped" do
      port =
        Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])

      {:ok, client} = Client.start_link(transport: {:port, port})
      assert Port.connect(port, client)
      on_exit(fn -> Client.stop(client) end)
      monitor = Port.monitor(port)

      assert :ok = Client.stop(client)

      assert_receive {:DOWN, ^monitor, :port, ^port, :normal}, 1000
      assert Port.info(port) == nil
    end
  end

  defp start_tcp_client do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1000)
    {:ok, server_socket} = :gen_tcp.accept(listener, 1000)
    :gen_tcp.close(listener)
    {:ok, client} = Client.start_link(transport: {:tcp, socket})
    Process.unlink(client)

    on_exit(fn ->
      Client.stop(client)
      :gen_tcp.close(server_socket)
    end)

    {client, server_socket}
  end

  defp send_frame(socket, message) do
    {:ok, frame} = Framing.encode(message)
    assert :ok = :gen_tcp.send(socket, frame)
  end

  defp receive_frame(socket, buffer \\ "") do
    case Framing.extract_one(buffer) do
      {:ok, message, ""} ->
        message

      :incomplete ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 1000)
        receive_frame(socket, buffer <> data)
    end
  end

  defp queue_request(client, socket, timeout) do
    reply_ref = make_ref()
    send(client, {:"$gen_call", {self(), reply_ref}, {:request, "slow", %{}, timeout}})
    message = receive_frame(socket)
    {_from, timer} = Map.fetch!(:sys.get_state(client).pending, message["id"])
    {reply_ref, timer}
  end
end
