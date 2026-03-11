defmodule CopilotSdk.ToolResultTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{ToolResult, ToolBinaryResult}

  test "to_wire converts basic result" do
    result = %ToolResult{
      text_result_for_llm: "Hello",
      result_type: :success
    }

    wire = ToolResult.to_wire(result)
    assert wire["textResultForLlm"] == "Hello"
    assert wire["resultType"] == "success"
    refute Map.has_key?(wire, "error")
    refute Map.has_key?(wire, "sessionLog")
  end

  test "to_wire includes optional fields when present" do
    result = %ToolResult{
      text_result_for_llm: "error occurred",
      result_type: :failure,
      error: "something broke",
      session_log: "log entry",
      tool_telemetry: %{"duration_ms" => 150}
    }

    wire = ToolResult.to_wire(result)
    assert wire["resultType"] == "failure"
    assert wire["error"] == "something broke"
    assert wire["sessionLog"] == "log entry"
    assert wire["toolTelemetry"]["duration_ms"] == 150
  end

  test "to_wire includes binary results" do
    result = %ToolResult{
      text_result_for_llm: "image",
      result_type: :success,
      binary_results_for_llm: [
        %ToolBinaryResult{
          data: "base64data",
          mime_type: "image/png",
          type: "image",
          description: "A chart"
        }
      ]
    }

    wire = ToolResult.to_wire(result)
    assert length(wire["binaryResultsForLlm"]) == 1
    binary = hd(wire["binaryResultsForLlm"])
    assert binary["data"] == "base64data"
    assert binary["mimeType"] == "image/png"
    assert binary["type"] == "image"
    assert binary["description"] == "A chart"
  end

  test "to_wire converts all result types" do
    for type <- [:success, :failure, :rejected, :denied] do
      result = %ToolResult{result_type: type}
      wire = ToolResult.to_wire(result)
      assert wire["resultType"] == Atom.to_string(type)
    end
  end
end
