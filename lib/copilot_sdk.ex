defmodule CopilotSdk do
  @moduledoc """
  GitHub Copilot SDK for Elixir.

  Provides a client for communicating with the Copilot CLI server
  via JSON-RPC 2.0 over stdio or TCP.
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the SDK version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Create a new session on a connected client.

  ## Options

    * `:on_permission_request` - Required. Permission handler function.
    * `:tools` - List of tool definitions.
    * `:hooks` - Session lifecycle hooks.
    * See `CopilotSdk.SessionConfig` for all options.

  Returns `{:ok, session_pid}` or `{:error, reason}`.
  """
  defdelegate create_session(client, config), to: CopilotSdk.Client

  @doc "Bang variant of `create_session/2`. Raises on error."
  def create_session!(client, config) do
    case create_session(client, config) do
      {:ok, session} -> session
      {:error, reason} -> raise "Failed to create session: #{inspect(reason)}"
    end
  end
end
