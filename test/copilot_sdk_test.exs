defmodule CopilotSdkTest do
  use ExUnit.Case

  test "SDK version is defined" do
    assert is_binary(CopilotSdk.version())
  end

  test "SDK protocol version matches expected value" do
    assert CopilotSdk.SdkProtocolVersion.get() == 3
  end

  test "SDK min protocol version is 2" do
    assert CopilotSdk.SdkProtocolVersion.min() == 2
  end
end
