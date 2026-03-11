defmodule CopilotSdk.SessionEvent do
  @moduledoc "A parsed session event from the Copilot CLI."

  @type t :: %__MODULE__{
          type: atom(),
          data: map(),
          id: String.t() | nil,
          timestamp: String.t() | nil,
          ephemeral: boolean() | nil,
          parent_id: String.t() | nil
        }

  defstruct [:type, :id, :timestamp, :ephemeral, :parent_id, data: %{}]

  @doc "Parse a raw event map (from JSON-RPC notification params) into a SessionEvent."
  @spec from_map(map()) :: t()
  def from_map(event_map) when is_map(event_map) do
    %__MODULE__{
      type: CopilotSdk.Generated.SessionEventType.from_string(event_map["type"] || ""),
      data: event_map["data"] || %{},
      id: event_map["id"],
      timestamp: event_map["timestamp"],
      ephemeral: event_map["ephemeral"],
      parent_id: event_map["parentId"]
    }
  end
end
