defmodule CopilotSdk.Session.EventConsumer do
  @moduledoc """
  GenStage consumer that wraps a user-provided event handler function.

  Each `on/2` subscription creates one of these consumers.
  Stopping the consumer removes the subscription.
  """
  use GenStage, restart: :temporary
  require Logger

  @spec start_link({pid(), function()}) :: GenServer.on_start()
  def start_link({producer_pid, handler_fn}) do
    GenStage.start_link(__MODULE__, {producer_pid, handler_fn})
  end

  @impl true
  def init({producer_pid, handler_fn}) do
    {:consumer, %{handler: handler_fn},
     subscribe_to: [{producer_pid, max_demand: 1}]}
  end

  @impl true
  def handle_events(events, _from, state) do
    for event <- events do
      try do
        state.handler.(event)
      rescue
        e ->
          Logger.warning(
            "Error in session event handler: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )
      end
    end

    {:noreply, [], state}
  end
end
