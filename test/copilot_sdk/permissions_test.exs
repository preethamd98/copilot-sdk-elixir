defmodule CopilotSdk.PermissionsTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{PermissionHandler, PermissionRequestResult}

  test "approve_all returns approved result" do
    result = PermissionHandler.approve_all(%{}, %{session_id: "s1"})
    assert result.kind == :approved
  end

  test "wire format conversion for all permission kinds" do
    kinds = [
      {:approved, "approved"},
      {:denied_by_rules, "denied-by-rules"},
      {:denied_by_content_exclusion_policy, "denied-by-content-exclusion-policy"},
      {:denied_could_not_request_from_user,
       "denied-no-approval-rule-and-could-not-request-from-user"},
      {:denied_interactively_by_user, "denied-interactively-by-user"}
    ]

    for {atom, string} <- kinds do
      assert PermissionRequestResult.to_wire_kind(atom) == string
    end
  end

  test "to_wire converts full result" do
    result = %PermissionRequestResult{
      kind: :approved,
      feedback: "Looks good",
      message: "Approved by policy"
    }

    wire = PermissionRequestResult.to_wire(result)
    assert wire["kind"] == "approved"
    assert wire["feedback"] == "Looks good"
    assert wire["message"] == "Approved by policy"
    refute Map.has_key?(wire, "rules")
    refute Map.has_key?(wire, "path")
  end

  test "to_wire includes optional fields when present" do
    result = %PermissionRequestResult{
      kind: :denied_by_rules,
      rules: ["rule1", "rule2"],
      path: "/some/path"
    }

    wire = PermissionRequestResult.to_wire(result)
    assert wire["kind"] == "denied-by-rules"
    assert wire["rules"] == ["rule1", "rule2"]
    assert wire["path"] == "/some/path"
  end
end
