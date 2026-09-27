require "json"

module Enable
  # A field as a string, or nil when the key is missing or its value is null.
  # `data["x"]?.try(&.as_s)` raises on `"x": null`: `[]?` returns JSON::Any(nil), not nil.
  def self.str(data : JSON::Any?, key : String) : String?
    data.try(&.as_h?).try(&.[key]?).try(&.as_s?)
  end

  # The "name" of a nested object such as "assignee", or nil when that object is null.
  def self.name(data : JSON::Any, key : String) : String?
    str(data.as_h?.try(&.[key]?), "name")
  end

  # The rows `enbl tasks:show` prints.
  def self.task_record(data : JSON::Any) : Array(Tuple(String, String))
    [
      {"ID", data["id"].as_s},
      {"Title", data["title"].as_s},
      {"Status", data["status"].as_s},
      {"Priority", data["priority"].as_s},
      {"Assignee", name(data, "assignee") || "(unassigned)"},
      {"Due", str(data, "due_date") || "(none)"},
      {"Created", data["created_at"].as_s[0..9]},
    ]
  end
end
