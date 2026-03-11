defmodule CopilotSdk.HooksTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.SessionHooks

  @hook_types ~w(preToolUse postToolUse userPromptSubmitted sessionStart sessionEnd errorOccurred)

  test "each hook type dispatches to correct handler" do
    for hook_type <- @hook_types do
      test_pid = self()
      ref = make_ref()

      hooks =
        build_hooks_with(hook_type, fn input, _context ->
          send(test_pid, {ref, :hook_called, hook_type, input})
          nil
        end)

      context = %{session_id: "test-session"}
      SessionHooks.dispatch(hooks, hook_type, %{"timestamp" => 123}, context)
      assert_receive {^ref, :hook_called, ^hook_type, %{"timestamp" => 123}}, 1000
    end
  end

  test "returns nil when no hook handler is registered" do
    hooks = %SessionHooks{}
    assert nil == SessionHooks.dispatch(hooks, "preToolUse", %{}, %{})
  end

  test "returns nil when hooks struct is nil" do
    assert nil == SessionHooks.dispatch(nil, "preToolUse", %{}, %{})
  end

  test "returns handler result" do
    hooks = %SessionHooks{
      on_pre_tool_use: fn _input, _context -> %{modified: true} end
    }

    result = SessionHooks.dispatch(hooks, "preToolUse", %{}, %{})
    assert result == %{modified: true}
  end

  defp build_hooks_with(hook_type, handler) do
    field_map = %{
      "preToolUse" => :on_pre_tool_use,
      "postToolUse" => :on_post_tool_use,
      "userPromptSubmitted" => :on_user_prompt_submitted,
      "sessionStart" => :on_session_start,
      "sessionEnd" => :on_session_end,
      "errorOccurred" => :on_error_occurred
    }

    field = Map.fetch!(field_map, hook_type)
    Map.put(%SessionHooks{}, field, handler)
  end
end
