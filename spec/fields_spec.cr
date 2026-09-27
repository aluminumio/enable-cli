require "spec"
require "../src/enable/fields"

describe "Enable.task_record" do
  it "shows a task whose optional fields are null" do
    data = JSON.parse(File.read(Path[__DIR__, "fixtures", "task_nulls.json"]))
    Enable.task_record(data).to_h.should eq({
      "ID" => "7a2957a1-26f5-4ce5-a588-532e3007cca0", "Title" => "Fix PR #23", "Status" => "done",
      "Priority" => "high", "Assignee" => "(unassigned)", "Due" => "(none)", "Created" => "2026-09-20",
    })
  end

  it "shows the assignee's name and the due date when they are set" do
    data = JSON.parse(%({"id":"x","title":"t","status":"todo","priority":"low","created_at":"2026-09-20T10:00:00Z",
      "assignee":{"name":"Amy"},"due_date":"2026-10-01"}))
    rows = Enable.task_record(data).to_h
    rows["Assignee"].should eq("Amy")
    rows["Due"].should eq("2026-10-01")
  end
end
