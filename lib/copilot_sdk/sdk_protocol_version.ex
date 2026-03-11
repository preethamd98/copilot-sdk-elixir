defmodule CopilotSdk.SdkProtocolVersion do
  @moduledoc "SDK protocol version constants."

  @min_protocol_version 2
  @sdk_protocol_version 3

  @doc "Returns the current SDK protocol version (max supported)."
  @spec get() :: non_neg_integer()
  def get, do: @sdk_protocol_version

  @doc "Returns the minimum protocol version supported."
  @spec min() :: non_neg_integer()
  def min, do: @min_protocol_version
end
