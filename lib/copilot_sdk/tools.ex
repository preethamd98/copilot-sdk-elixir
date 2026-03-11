defmodule CopilotSdk.Tools do
  @moduledoc "Tool definition utilities for the Copilot SDK."

  alias CopilotSdk.{Tool, ToolInvocation, ToolResult}

  @doc """
  Define a tool with a name, description, JSON Schema parameters, and handler function.

  ## Options

    * `:name` - Required. The tool name (string).
    * `:description` - Required. Human-readable description.
    * `:parameters` - Optional. JSON Schema for tool parameters.
    * `:handler` - Required. Function with arity 1 (args) or 2 (args, invocation).
    * `:overrides_built_in_tool` - Optional boolean (default: false).

  ## Examples

      tool = CopilotSdk.Tools.define_tool(
        name: "get_weather",
        description: "Get weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"]
        },
        handler: fn args, _invocation ->
          "Weather in \#{args["city"]}: 22°C"
        end
      )
  """
  @spec define_tool(keyword()) :: Tool.t()
  def define_tool(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    handler = Keyword.fetch!(opts, :handler)
    parameters = Keyword.get(opts, :parameters)
    overrides_built_in = Keyword.get(opts, :overrides_built_in_tool, false)

    %Tool{
      name: name,
      description: description,
      parameters: parameters,
      handler: wrap_handler(handler),
      overrides_built_in_tool: overrides_built_in
    }
  end

  @doc "Convert a Tool to the wire format map for session.create payload."
  def to_wire(%Tool{} = tool) do
    wire = %{
      "name" => tool.name,
      "description" => tool.description
    }

    if tool.parameters do
      Map.put(wire, "inputSchema" , tool.parameters)
    else
      wire
    end
  end

  defp wrap_handler(handler) when is_function(handler, 2) do
    fn %ToolInvocation{} = invocation ->
      try do
        result = handler.(invocation.arguments || %{}, invocation)
        normalize_result(result)
      rescue
        e ->
          %ToolResult{
            text_result_for_llm:
              "Invoking this tool produced an error. Detailed information is not available.",
            result_type: :failure,
            error: Exception.message(e)
          }
      end
    end
  end

  defp wrap_handler(handler) when is_function(handler, 1) do
    wrap_handler(fn args, _inv -> handler.(args) end)
  end

  defp normalize_result(nil),
    do: %ToolResult{text_result_for_llm: "", result_type: :success}

  defp normalize_result(%ToolResult{} = r), do: r

  defp normalize_result(s) when is_binary(s),
    do: %ToolResult{text_result_for_llm: s, result_type: :success}

  defp normalize_result(other),
    do: %ToolResult{text_result_for_llm: Jason.encode!(other), result_type: :success}
end
