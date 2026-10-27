# Read only helper output for the runner's unique context. Prefer the latest
# opener result, so attached/pending windows do not get stale attach guidance.
def blocks:
  .message.content? // [] | if type == "string" then [{type:"text",text:.}] else . end;
reduce (inputs | fromjson? | select(type == "object")) as $entry (null;
  if $entry.type == "user" then
    reduce ($entry | blocks[]? | select(.type == "tool_result") | .content |
      if type == "string" then . else .[]? | .text? // empty end |
      split("\n")[] | fromjson? |
      select(type == "object" and (.context_file? | type == "string")) |
      select(.context_file | split("/")[-2] as $id | $ids | index($id)) |
      select(.user_message? | type == "string" and length > 0)) as $view (.; $view)
  else . end)
