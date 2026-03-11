defmodule CopilotSdk.Session.EventProducer do
  @moduledoc """
  GenStage producer for session events.

  Uses BroadcastDispatcher so all consumers receive every event.
  """
  use GenStage

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenStage.start_link(__MODULE__, opts)
  end

  @doc "Push an event to the producer. All consumers will receive it."
  @spec push_event(pid(), CopilotSdk.SessionEvent.t()) :: :ok
  def push_event(pid, event) do
    GenStage.cast(pid, {:push, event})
  end

  @impl true
  def init(_opts) do
    {:producer, %{queue: :queue.new()}, dispatcher: GenStage.BroadcastDispatcher}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    updated_queue = :queue.in(event, state.queue)
    {events, remaining} = drain_queue(updated_queue)
    {:noreply, events, %{state | queue: remaining}}
  end

  @impl true
  def handle_demand(_demand, state) do
    {events, remaining} = drain_queue(state.queue)
    {:noreply, events, %{state | queue: remaining}}
  end

  defp drain_queue(queue) do
    drain_queue(queue, [])
  end

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, event}, rest} -> drain_queue(rest, [event | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end
end
