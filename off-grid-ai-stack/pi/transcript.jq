# pi --mode json (one JSON event per line) as a short transcript: each tool call pi runs, its
# result, and the assistant's text.   pi --mode json ... | jq -rf pi/transcript.jq
if .type == "tool_execution_start" then "-> \(.toolName) \(.args | tojson)"
elif .type == "tool_execution_end" then
  "<- \(.toolName)\(if .isError then " (error)" else "" end): \([.result.content[]? | .text // empty] | join(" ") | gsub("\\s+"; " "))"
elif .type == "message_end" and .message.role == "assistant" then
  ([.message.content[]? | select(.type == "text") | .text] | join("")) as $t
  | if ($t | test("\\S")) then "assistant: \($t)" else empty end
else empty end
