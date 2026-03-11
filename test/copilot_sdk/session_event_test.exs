defmodule CopilotSdk.SessionEventTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.SessionEvent

  test "from_map parses a valid event" do
    event =
      SessionEvent.from_map(%{
        "type" => "assistant.message",
        "data" => %{"content" => "Hello!", "messageId" => "m1"},
        "id" => "evt-uuid",
        "timestamp" => "2026-03-10T12:00:00Z",
        "parentId" => nil
      })

    assert event.type == :assistant_message
    assert event.data["content"] == "Hello!"
    assert event.id == "evt-uuid"
    assert event.timestamp == "2026-03-10T12:00:00Z"
    assert event.parent_id == nil
  end

  test "from_map handles unknown event type gracefully" do
    event =
      SessionEvent.from_map(%{
        "type" => "future.unknown_event",
        "data" => %{},
        "id" => "evt-2",
        "timestamp" => "2026-03-10T12:00:00Z"
      })

    assert event.type == :unknown
    assert event.data == %{}
  end

  test "from_map handles missing data" do
    event =
      SessionEvent.from_map(%{
        "type" => "session.idle",
        "id" => "evt-3"
      })

    assert event.type == :session_idle
    assert event.data == %{}
    assert event.timestamp == nil
  end

  test "from_map handles ephemeral flag" do
    event =
      SessionEvent.from_map(%{
        "type" => "session.info",
        "data" => %{},
        "id" => "evt-4",
        "timestamp" => "2026-03-10T12:00:00Z",
        "ephemeral" => true
      })

    assert event.ephemeral == true
  end

  test "from_map handles parentId" do
    event =
      SessionEvent.from_map(%{
        "type" => "tool.execution_complete",
        "data" => %{},
        "id" => "evt-5",
        "timestamp" => "2026-03-10T12:00:00Z",
        "parentId" => "evt-4"
      })

    assert event.parent_id == "evt-4"
  end
end
