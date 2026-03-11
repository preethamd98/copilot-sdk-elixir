defmodule CopilotSdk.Session.EventProducerTest do
  use ExUnit.Case

  alias CopilotSdk.Session.{EventProducer, EventConsumer}

  test "BroadcastDispatcher sends event to all consumers" do
    {:ok, producer} = EventProducer.start_link([])
    test_pid = self()

    for i <- 1..2 do
      {:ok, _} =
        EventConsumer.start_link(
          {producer, fn event -> send(test_pid, {i, event.type}) end}
        )
    end

    # Give consumers time to subscribe
    Process.sleep(50)

    EventProducer.push_event(producer, %{type: :session_idle, data: %{}})
    assert_receive {1, :session_idle}, 2000
    assert_receive {2, :session_idle}, 2000
  end

  test "events are delivered in order" do
    {:ok, producer} = EventProducer.start_link([])
    test_pid = self()

    {:ok, _} =
      EventConsumer.start_link(
        {producer, fn event -> send(test_pid, event.type) end}
      )

    Process.sleep(50)

    for type <- [:a, :b, :c] do
      EventProducer.push_event(producer, %{type: type, data: %{}})
    end

    assert_receive :a, 2000
    assert_receive :b, 2000
    assert_receive :c, 2000
  end

  test "consumer crash does not affect other consumers" do
    {:ok, producer} = EventProducer.start_link([])
    test_pid = self()

    # Crashy consumer
    {:ok, _} =
      EventConsumer.start_link(
        {producer, fn _e -> raise "boom" end}
      )

    # Healthy consumer
    {:ok, _} =
      EventConsumer.start_link(
        {producer, fn e -> send(test_pid, {:ok, e.type}) end}
      )

    Process.sleep(50)

    EventProducer.push_event(producer, %{type: :test_event, data: %{}})
    assert_receive {:ok, :test_event}, 2000
  end

  test "stopping a consumer removes subscription" do
    {:ok, producer} = EventProducer.start_link([])
    test_pid = self()

    {:ok, consumer} =
      EventConsumer.start_link(
        {producer, fn e -> send(test_pid, {:got, e.type}) end}
      )

    Process.sleep(50)

    EventProducer.push_event(producer, %{type: :before_stop, data: %{}})
    assert_receive {:got, :before_stop}, 2000

    GenStage.stop(consumer, :normal)
    Process.sleep(50)

    EventProducer.push_event(producer, %{type: :after_stop, data: %{}})
    refute_receive {:got, :after_stop}, 200
  end
end
