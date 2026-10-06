defmodule CopilotSdk.PermissionHandler do
  @moduledoc "Pre-built permission request handlers."

  @doc "Approve requests once, or abstain when managed settings must decide."
  @spec approve_all(map(), map()) :: CopilotSdk.PermissionRequestResult.t()
  def approve_all(_request, invocation) do
    if invocation[:managed_settings_enabled] do
      %CopilotSdk.PermissionRequestResult{kind: :no_result}
    else
      %CopilotSdk.PermissionRequestResult{kind: :approved}
    end
  end
end
