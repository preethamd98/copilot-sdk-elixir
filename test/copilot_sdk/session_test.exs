defmodule CopilotSdk.SessionTest do
  use ExUnit.Case

  import CopilotSdk.Test.Helpers

  describe "on/2 and event dispatch" do
    test "registered handler receives dispatched events" do
      {:ok, session, _mock} = start_test_session()
      test_pid = self()
      _unsub = CopilotSdk.Session.on(session, fn event -> send(test_pid, {:got, event}) end)
      CopilotSdk.Session.dispatch_event(session, idle_event())
      assert_receive {:got, %{type: :session_idle}}, 2000
    end

    test "unsubscribe stops delivery" do
      {:ok, session, _mock} = start_test_session()
      test_pid = self()
      unsub = CopilotSdk.Session.on(session, fn event -> send(test_pid, {:got, event}) end)
      # Verify subscription works first
      Process.sleep(100)
      CopilotSdk.Session.dispatch_event(session, idle_event())
      assert_receive {:got, _}, 2000

      # Now unsubscribe
      unsub.()
      # Wait for the consumer process to terminate and producer to notice
      Process.sleep(500)

      # Drain any remaining messages
      receive do
        {:got, _} -> :ok
      after
        0 -> :ok
      end

      # Now dispatch another event — should NOT be received
      CopilotSdk.Session.dispatch_event(session, idle_event())
      refute_receive {:got, _}, 500
    end

    test "multiple handlers all receive events" do
      {:ok, session, _mock} = start_test_session()
      test_pid = self()
      CopilotSdk.Session.on(session, fn e -> send(test_pid, {:h1, e.type}) end)
      CopilotSdk.Session.on(session, fn e -> send(test_pid, {:h2, e.type}) end)
      Process.sleep(50)
      CopilotSdk.Session.dispatch_event(session, idle_event())
      assert_receive {:h1, :session_idle}, 2000
      assert_receive {:h2, :session_idle}, 2000
    end

    test "handler crash does not affect other handlers" do
      {:ok, session, _mock} = start_test_session()
      test_pid = self()
      CopilotSdk.Session.on(session, fn _e -> raise "boom" end)
      CopilotSdk.Session.on(session, fn e -> send(test_pid, {:ok, e.type}) end)
      Process.sleep(50)
      CopilotSdk.Session.dispatch_event(session, idle_event())
      assert_receive {:ok, :session_idle}, 2000
    end
  end

  describe "send_and_wait/3" do
    test "returns last assistant message on idle" do
      {:ok, session, _mock} = start_test_session()

      # Simulate: after send, dispatch assistant message then idle
      spawn(fn ->
        Process.sleep(100)
        CopilotSdk.Session.dispatch_event(session, assistant_message_event("Hello!"))
        Process.sleep(50)
        CopilotSdk.Session.dispatch_event(session, idle_event())
      end)

      assert {:ok, %{type: :assistant_message}} =
               CopilotSdk.Session.send_and_wait(session, %{prompt: "hello"}, timeout: 5000)
    end

    test "returns {:error, :timeout} when no idle arrives" do
      {:ok, session, _mock} = start_test_session()

      assert {:error, :timeout} =
               CopilotSdk.Session.send_and_wait(session, %{prompt: "hello"}, timeout: 200)
    end

    test "returns error on session.error event" do
      {:ok, session, _mock} = start_test_session()

      spawn(fn ->
        Process.sleep(100)
        CopilotSdk.Session.dispatch_event(session, session_error_event("Something broke"))
      end)

      assert {:error, msg} =
               CopilotSdk.Session.send_and_wait(session, %{prompt: "hello"}, timeout: 5000)

      assert msg =~ "Session error"
    end
  end

  describe "session_id/1" do
    test "returns the session ID" do
      {:ok, session, mock_info} = start_test_session()
      assert CopilotSdk.Session.session_id(session) == mock_info.session_id
    end
  end

  describe "workspace_path/1" do
    test "returns nil initially" do
      {:ok, session, _mock} = start_test_session()
      assert CopilotSdk.Session.workspace_path(session) == nil
    end

    test "returns set workspace path" do
      {:ok, session, _mock} = start_test_session()
      CopilotSdk.Session.set_workspace_path(session, "/tmp/workspace")
      Process.sleep(50)
      assert CopilotSdk.Session.workspace_path(session) == "/tmp/workspace"
    end
  end

  describe "disconnect/1" do
    test "sends session.destroy RPC" do
      {:ok, session, _mock} = start_test_session()
      result = CopilotSdk.Session.disconnect(session)
      assert result == :ok
    end
  end

  describe "tool dispatch (protocol v3)" do
    test "handles external_tool.requested event" do
      test_pid = self()

      tool =
        CopilotSdk.Tools.define_tool(
          name: "test_tool",
          description: "A test tool",
          handler: fn args, _inv ->
            send(test_pid, {:tool_called, args})
            "tool result"
          end
        )

      {:ok, session, _mock} = start_test_session(tools: [tool])
      Process.sleep(50)

      CopilotSdk.Session.dispatch_event(
        session,
        tool_requested_event("test_tool", %{"key" => "value"})
      )

      assert_receive {:tool_called, %{"key" => "value"}}, 2000
    end
  end

  describe "permission dispatch (protocol v3)" do
    test "handles permission.requested event" do
      test_pid = self()

      handler = fn _request, _invocation ->
        send(test_pid, :permission_handled)
        %CopilotSdk.PermissionRequestResult{kind: :approved}
      end

      {:ok, session, _mock} = start_test_session(on_permission_request: handler)
      Process.sleep(50)

      CopilotSdk.Session.dispatch_event(session, permission_requested_event())

      assert_receive :permission_handled, 2000
    end
  end

  describe "user input dispatch (protocol v3)" do
    test "handles user_input.requested event" do
      test_pid = self()

      handler = fn request, _invocation ->
        send(test_pid, {:user_input, request.question})
        %CopilotSdk.UserInputResponse{answer: "yes", was_freeform: false}
      end

      {:ok, session, _mock} = start_test_session(on_user_input_request: handler)
      Process.sleep(50)

      CopilotSdk.Session.dispatch_event(session, user_input_requested_event("Continue?"))

      assert_receive {:user_input, "Continue?"}, 2000
    end
  end

  describe "on_event (early-bind)" do
    test "early-bind handler receives events" do
      test_pid = self()

      {:ok, session, _mock} =
        start_test_session(on_event: fn event -> send(test_pid, {:early, event.type}) end)

      Process.sleep(50)
      CopilotSdk.Session.dispatch_event(session, idle_event())
      assert_receive {:early, :session_idle}, 2000
    end
  end
end
