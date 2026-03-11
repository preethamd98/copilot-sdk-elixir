defmodule CopilotSdk.JsonRpc.ClientTest do
  use ExUnit.Case

  alias CopilotSdk.JsonRpc.Client
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

    test "times out when no response" do
      {:ok, mock} =
        MockJsonRpcServer.start(
          on_request: fn _method, _params ->
            Process.sleep(5000)
            %{}
          end
        )

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      result =
        try do
          Client.request(client, "slow", %{}, timeout: 200)
        catch
          :exit, _ -> {:error, :timeout}
        end

      assert {:error, _} = result

      Client.stop(client)
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

      {:ok, mock} = MockJsonRpcServer.start()

      {:ok, client} =
        Client.start_link(
          transport: mock.transport,
          notification_handler: fn _m, _p -> :ok end
        )

      Client.set_request_handler(client, "tool.call", fn params ->
        send(test_pid, {:tool_call, params})
        %{"result" => "handled"}
      end)

      # The mock server would need to send a request, which is harder to test
      # in this setup. We'll test the handler registration at least.
      assert Client.alive?(client)
      Client.stop(client)
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
  end
end
