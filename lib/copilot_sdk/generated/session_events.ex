defmodule CopilotSdk.Generated.SessionEventType do
  @moduledoc "Session event types mapped from wire strings to Elixir atoms."

  @event_types %{
    "abort" => :abort,
    "assistant.intent" => :assistant_intent,
    "assistant.message" => :assistant_message,
    "assistant.message_delta" => :assistant_message_delta,
    "assistant.reasoning" => :assistant_reasoning,
    "assistant.reasoning_delta" => :assistant_reasoning_delta,
    "assistant.streaming_delta" => :assistant_streaming_delta,
    "assistant.turn_end" => :assistant_turn_end,
    "assistant.turn_start" => :assistant_turn_start,
    "assistant.usage" => :assistant_usage,
    "command.completed" => :command_completed,
    "command.queued" => :command_queued,
    "elicitation.completed" => :elicitation_completed,
    "elicitation.requested" => :elicitation_requested,
    "exit_plan_mode.completed" => :exit_plan_mode_completed,
    "exit_plan_mode.requested" => :exit_plan_mode_requested,
    "external_tool.completed" => :external_tool_completed,
    "external_tool.requested" => :external_tool_requested,
    "hook.end" => :hook_end,
    "hook.start" => :hook_start,
    "pending_messages.modified" => :pending_messages_modified,
    "permission.completed" => :permission_completed,
    "permission.requested" => :permission_requested,
    "session.compaction_complete" => :session_compaction_complete,
    "session.compaction_start" => :session_compaction_start,
    "session.context_changed" => :session_context_changed,
    "session.error" => :session_error,
    "session.handoff" => :session_handoff,
    "session.idle" => :session_idle,
    "session.info" => :session_info,
    "session.model_change" => :session_model_change,
    "session.mode_changed" => :session_mode_changed,
    "session.plan_changed" => :session_plan_changed,
    "session.resume" => :session_resume,
    "session.shutdown" => :session_shutdown,
    "session.snapshot_rewind" => :session_snapshot_rewind,
    "session.start" => :session_start,
    "session.task_complete" => :session_task_complete,
    "session.title_changed" => :session_title_changed,
    "session.truncation" => :session_truncation,
    "session.usage_info" => :session_usage_info,
    "session.warning" => :session_warning,
    "session.workspace_file_changed" => :session_workspace_file_changed,
    "skill.invoked" => :skill_invoked,
    "subagent.completed" => :subagent_completed,
    "subagent.deselected" => :subagent_deselected,
    "subagent.failed" => :subagent_failed,
    "subagent.selected" => :subagent_selected,
    "subagent.started" => :subagent_started,
    "system.message" => :system_message,
    "system.notification" => :system_notification,
    "tool.execution_complete" => :tool_execution_complete,
    "tool.execution_partial_result" => :tool_execution_partial_result,
    "tool.execution_progress" => :tool_execution_progress,
    "tool.execution_start" => :tool_execution_start,
    "tool.user_requested" => :tool_user_requested,
    "user_input.completed" => :user_input_completed,
    "user_input.requested" => :user_input_requested,
    "user.message" => :user_message
  }

  @doc "Convert wire string to atom. Unknown types return :unknown (forward compatibility)."
  @spec from_string(String.t()) :: atom()
  def from_string(type) when is_binary(type), do: Map.get(@event_types, type, :unknown)

  @doc "Convert atom back to wire string."
  @spec to_string(atom()) :: String.t()
  def to_string(type) when is_atom(type) do
    case Enum.find(@event_types, fn {_k, v} -> v == type end) do
      {k, _} -> k
      nil -> "unknown"
    end
  end

  @doc "List all known event type atoms."
  @spec all() :: [atom()]
  def all, do: Map.values(@event_types)
end
