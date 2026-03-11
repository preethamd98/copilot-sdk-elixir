defmodule CopilotSdk.ToolsTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.{Tools, Tool, ToolInvocation, ToolResult}

  describe "define_tool/1" do
    test "creates a Tool struct with name, description, and handler" do
      tool =
        Tools.define_tool(
          name: "greet",
          description: "Say hello",
          handler: fn args, _inv -> "Hello, #{args["name"]}!" end
        )

      assert %Tool{name: "greet", description: "Say hello"} = tool
      assert is_function(tool.handler, 1)
    end

    test "includes JSON Schema parameters when provided" do
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}

      tool =
        Tools.define_tool(
          name: "calc",
          description: "calc",
          parameters: schema,
          handler: fn _, _ -> "ok" end
        )

      assert tool.parameters == schema
    end

    test "handler with arity 1 (args only) works" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn args -> args["val"] end
        )

      inv = %ToolInvocation{session_id: "s", tool_name: "t", arguments: %{"val" => "x"}}
      assert %ToolResult{text_result_for_llm: "x", result_type: :success} = tool.handler.(inv)
    end

    test "handler with arity 2 works" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn args, inv -> "#{args["x"]}:#{inv.session_id}" end
        )

      inv = %ToolInvocation{session_id: "s1", tool_name: "t", arguments: %{"x" => "hello"}}
      result = tool.handler.(inv)
      assert result.text_result_for_llm == "hello:s1"
    end

    test "overrides_built_in_tool defaults to false" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn _, _ -> nil end
        )

      refute tool.overrides_built_in_tool
    end

    test "overrides_built_in_tool can be set to true" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn _, _ -> nil end,
          overrides_built_in_tool: true
        )

      assert tool.overrides_built_in_tool
    end
  end

  describe "result normalization" do
    test "nil → empty success" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> nil end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.result_type == :success
      assert result.text_result_for_llm == ""
    end

    test "string → success with text" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> "done" end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.text_result_for_llm == "done"
      assert result.result_type == :success
    end

    test "ToolResult passes through" do
      tr = %ToolResult{text_result_for_llm: "custom", result_type: :failure, error: "bad"}
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> tr end)
      assert tool.handler.(%ToolInvocation{arguments: %{}}) == tr
    end

    test "map gets JSON-serialized" do
      tool = Tools.define_tool(name: "t", description: "d", handler: fn _, _ -> %{count: 42} end)
      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.text_result_for_llm =~ "42"
      assert result.result_type == :success
    end
  end

  describe "error handling" do
    test "handler exception is caught and sanitized" do
      tool =
        Tools.define_tool(
          name: "t",
          description: "d",
          handler: fn _, _ -> raise "secret internal error" end
        )

      result = tool.handler.(%ToolInvocation{arguments: %{}})
      assert result.result_type == :failure
      refute result.text_result_for_llm =~ "secret"
      assert result.error =~ "secret internal error"
    end
  end

  describe "to_wire/1" do
    test "converts tool to wire format" do
      tool =
        Tools.define_tool(
          name: "get_weather",
          description: "Get weather",
          parameters: %{"type" => "object"},
          handler: fn _, _ -> "ok" end
        )

      wire = Tools.to_wire(tool)
      assert wire["name"] == "get_weather"
      assert wire["description"] == "Get weather"
      assert wire["inputSchema"] == %{"type" => "object"}
    end

    test "omits inputSchema when no parameters" do
      tool =
        Tools.define_tool(
          name: "no_params",
          description: "No params",
          handler: fn _, _ -> "ok" end
        )

      wire = Tools.to_wire(tool)
      assert wire["name"] == "no_params"
      refute Map.has_key?(wire, "inputSchema")
    end
  end
end
