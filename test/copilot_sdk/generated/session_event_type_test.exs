defmodule CopilotSdk.Generated.SessionEventTypeTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.Generated.SessionEventType

  test "from_string converts known types" do
    assert SessionEventType.from_string("session.idle") == :session_idle
    assert SessionEventType.from_string("assistant.message") == :assistant_message
    assert SessionEventType.from_string("tool.execution_start") == :tool_execution_start
    assert SessionEventType.from_string("external_tool.requested") == :external_tool_requested
    assert SessionEventType.from_string("permission.requested") == :permission_requested
    assert SessionEventType.from_string("user.message") == :user_message
    assert SessionEventType.from_string("abort") == :abort
  end

  test "from_string returns :unknown for unrecognized types (forward compatibility)" do
    assert SessionEventType.from_string("future.new_event") == :unknown
    assert SessionEventType.from_string("") == :unknown
    assert SessionEventType.from_string("completely.unknown.type") == :unknown
  end

  test "to_string round-trips with from_string" do
    for type <- SessionEventType.all() do
      wire = SessionEventType.to_string(type)
      assert SessionEventType.from_string(wire) == type
    end
  end

  test "all known types are covered (at least 55)" do
    all = SessionEventType.all()
    assert length(all) >= 55, "Expected at least 55 event types, got #{length(all)}"
  end

  test "to_string returns 'unknown' for unrecognized atoms" do
    assert SessionEventType.to_string(:nonexistent_type) == "unknown"
  end
end
