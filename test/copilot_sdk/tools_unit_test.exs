defmodule CopilotSdk.ToolsUnitTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{Tools, ToolInvocation, ToolResult}

  describe "tool declarations" do
    test "parameters use the upstream key and preserve arbitrary schema property names" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "working_directory" => %{"type" => "string"},
          "input_schema" => %{"type" => "object", "additionalProperties" => false}
        },
        "required" => ["working_directory"]
      }

      tool =
        Tools.define_tool(
          name: "my_tool",
          description: "Tool",
          parameters: schema,
          handler: fn _ -> "ok" end
        )

      wire = Tools.to_wire(tool)
      assert wire["parameters"] == schema
      refute Map.has_key?(wire, "inputSchema")
      refute Map.has_key?(wire, "handler")
    end

    test "optional metadata, defer and terminal fields reach the wire unchanged" do
      metadata = %{"host:custom_key" => %{"keep_snake_case" => false}}

      tool =
        Tools.define_tool(
          name: "finish",
          description: "Finish the turn",
          handler: fn _ -> "done" end,
          defer: "never",
          metadata: metadata,
          is_terminal: true
        )

      assert tool.defer == "never"
      assert tool.metadata == metadata
      assert tool.is_terminal == true

      assert Tools.to_wire(tool) == %{
               "name" => "finish",
               "description" => "Finish the turn",
               "defer" => "never",
               "metadata" => metadata,
               "isTerminal" => true
             }
    end

    test "optional fields preserve false and empty maps, and are omitted when unset" do
      tool =
        Tools.define_tool(
          name: "tool",
          description: "Tool",
          handler: fn _ -> "ok" end,
          parameters: %{},
          metadata: %{},
          defer: "auto",
          is_terminal: false
        )

      assert Tools.to_wire(tool)["parameters"] == %{}
      assert Tools.to_wire(tool)["metadata"] == %{}
      assert Tools.to_wire(tool)["defer"] == "auto"
      assert Tools.to_wire(tool)["isTerminal"] == false

      default = Tools.define_tool(name: "tool", description: "Tool", handler: fn _ -> "ok" end)
      assert Tools.to_wire(default) == %{"name" => "tool", "description" => "Tool"}
    end
  end

  describe "overrides_built_in_tool in wire format" do
    test "to_wire includes overridesBuiltInTool when true" do
      tool =
        Tools.define_tool(
          name: "custom_grep",
          description: "Custom grep",
          handler: fn _, _ -> "ok" end,
          overrides_built_in_tool: true
        )

      wire = Tools.to_wire(tool)
      assert wire["overridesBuiltInTool"] == true
    end

    test "to_wire omits overridesBuiltInTool when false" do
      tool =
        Tools.define_tool(
          name: "my_tool",
          description: "My tool",
          handler: fn _, _ -> "ok" end
        )

      wire = Tools.to_wire(tool)
      refute Map.has_key?(wire, "overridesBuiltInTool")
    end
  end

  describe "handler with no params" do
    test "handler invoked with empty arguments works" do
      tool =
        Tools.define_tool(
          name: "no_params_tool",
          description: "Tool with no parameters",
          handler: fn _args, _inv -> "no params needed" end
        )

      result = tool.handler.(%ToolInvocation{arguments: nil})
      assert result.text_result_for_llm == "no params needed"
      assert result.result_type == :success
    end

    test "handler with arity 1 invoked with empty map" do
      tool =
        Tools.define_tool(
          name: "simple",
          description: "Simple tool",
          handler: fn _args -> "done" end
        )

      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.text_result_for_llm == "done"
    end
  end

  describe "handler return type normalization" do
    test "nil normalizes to empty success" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> nil end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert %ToolResult{text_result_for_llm: "", result_type: :success} = result
    end

    test "string normalizes to success with text" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> "hello" end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.text_result_for_llm == "hello"
      assert result.result_type == :success
    end

    test "map normalizes to JSON-serialized success" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn _, _ -> %{"key" => "value", "num" => 42} end
        )

      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.result_type == :success
      decoded = Jason.decode!(result.text_result_for_llm)
      assert decoded["key"] == "value"
      assert decoded["num"] == 42
    end

    test "ToolResult passes through unchanged" do
      expected = %ToolResult{
        text_result_for_llm: "custom result",
        result_type: :failure,
        error: "something went wrong"
      }

      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> expected end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result == expected
    end

    test "integer normalizes to JSON-serialized success" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> 42 end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.result_type == :success
      assert result.text_result_for_llm == "42"
    end

    test "list normalizes to JSON-serialized success" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> [1, 2, 3] end)

      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.result_type == :success
      assert Jason.decode!(result.text_result_for_llm) == [1, 2, 3]
    end
  end
end
