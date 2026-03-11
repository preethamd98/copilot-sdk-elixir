defmodule CopilotSdk.PermissionHandler do
  @moduledoc "Pre-built permission request handlers."

  @doc "Approve all permission requests unconditionally."
  @spec approve_all(map(), map()) :: CopilotSdk.PermissionRequestResult.t()
  def approve_all(_request, _invocation) do
    %CopilotSdk.PermissionRequestResult{kind: :approved}
  end
end
