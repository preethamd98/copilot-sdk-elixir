defmodule CopilotSdk.EventForwardCompatibilityTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.Generated.SessionEventType
  alias CopilotSdk.SessionEvent

  describe "known event types" do
    test "assistant.message is parsed to :assistant_message" do
      assert SessionEventType.from_string("assistant.message") == :assistant_message
    end

    test "session.idle is parsed to :session_idle" do
      assert SessionEventType.from_string("session.idle") == :session_idle
    end

    test "tool.execution_start is parsed to :tool_execution_start" do
      assert SessionEventType.from_string("tool.execution_start") == :tool_execution_start
    end

    test "permission.requested is parsed to :permission_requested" do
      assert SessionEventType.from_string("permission.requested") == :permission_requested
    end

    test "external_tool.requested is parsed to :external_tool_requested" do
      assert SessionEventType.from_string("external_tool.requested") == :external_tool_requested
    end

    test "session.error is parsed to :session_error" do
      assert SessionEventType.from_string("session.error") == :session_error
    end

    test "known types are parsed into a SessionEvent struct" do
      event =
        SessionEvent.from_map(%{
          "type" => "assistant.turn_start",
          "data" => %{"turnId" => "t1"},
          "id" => "e1"
        })

      assert event.type == :assistant_turn_start
      assert event.data["turnId"] == "t1"
    end
  end

  describe "unknown event types" do
    test "unknown wire string maps to :unknown" do
      assert SessionEventType.from_string("future.unknown_event") == :unknown
    end

    test "empty string maps to :unknown" do
      assert SessionEventType.from_string("") == :unknown
    end

    test "completely novel type maps to :unknown" do
      assert SessionEventType.from_string("brand.new.never.seen") == :unknown
    end

    test "unknown type does not crash SessionEvent.from_map" do
      event =
        SessionEvent.from_map(%{
          "type" => "does_not_exist.at_all",
          "data" => %{"foo" => "bar"},
          "id" => "e2"
        })

      assert event.type == :unknown
      assert event.data == %{"foo" => "bar"}
    end
  end

  describe "round-trip from_string/to_string" do
    test "all known types round-trip correctly" do
      for type_atom <- SessionEventType.all() do
        wire_string = SessionEventType.to_string(type_atom)
        assert wire_string != "unknown", "#{type_atom} should have a wire string"
        assert SessionEventType.from_string(wire_string) == type_atom,
               "Round-trip failed for #{type_atom} (wire: #{wire_string})"
      end
    end

    test "to_string of :unknown returns \"unknown\"" do
      assert SessionEventType.to_string(:unknown) == "unknown"
    end

    test "to_string of unrecognized atom returns \"unknown\"" do
      assert SessionEventType.to_string(:totally_fake_type) == "unknown"
    end
  end
end
