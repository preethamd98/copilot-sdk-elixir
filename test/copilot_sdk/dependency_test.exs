defmodule CopilotSdk.DependencyTest do
  use ExUnit.Case

  test "Jason is available" do
    assert {:ok, _} = Jason.encode(%{"hello" => "world"})
  end

  test "Jason decodes correctly" do
    assert {:ok, %{"key" => "value"}} = Jason.decode(~s({"key": "value"}))
  end

  test "GenStage is available" do
    assert Code.ensure_loaded?(GenStage)
  end
end
