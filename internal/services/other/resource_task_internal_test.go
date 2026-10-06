package other

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/datadrivers/go-nexus-client/nexus3/schema/task"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
)

// readFixture decodes a real GET /v1/tasks/{id} response (Nexus 3.94.1).
func readFixture(t *testing.T, name string) *task.Task {
	t.Helper()
	raw, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	var got task.Task
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	return &got
}

func TestSetTaskToResourceDataCronReadsBackAsCron(t *testing.T) {
	d := schema.TestResourceDataRaw(t, ResourceTask().Schema, map[string]interface{}{
		"type": "blobstore.compact",
		"name": "x",
		"frequency": []interface{}{map[string]interface{}{
			"schedule":        "cron",
			"cron_expression": "0 15 4 * * ?",
		}},
	})
	if err := setTaskToResourceData(readFixture(t, "get_task_cron.json"), d); err != nil {
		t.Fatal(err)
	}
	if got := d.Get("frequency.0.schedule"); got != "cron" {
		t.Errorf("schedule = %q, want cron (API returns advanced)", got)
	}
	if got := d.Get("frequency.0.cron_expression"); got != "0 15 4 * * ?" {
		t.Errorf("cron_expression = %q", got)
	}
	// Server-set startDate/timeZoneOffset must not leak into state.
	if got := d.Get("frequency.0.time_zone_offset"); got != "" {
		t.Errorf("time_zone_offset = %q, want empty (not configured)", got)
	}
	if got := d.Get("frequency.0.start_date"); got != 0 {
		t.Errorf("start_date = %v, want 0 (not configured)", got)
	}
	if got := d.Get("properties.blobsOlderThan"); got != "3" {
		t.Errorf("properties.blobsOlderThan = %q", got)
	}
	if d.Id() != "ac6e3877-01f6-4809-a826-31af110013ee" {
		t.Errorf("id = %q", d.Id())
	}
}

func TestSetTaskToResourceDataDaily(t *testing.T) {
	d := schema.TestResourceDataRaw(t, ResourceTask().Schema, map[string]interface{}{})
	if err := setTaskToResourceData(readFixture(t, "get_task_daily.json"), d); err != nil {
		t.Fatal(err)
	}
	if got := d.Get("frequency.0.schedule"); got != "daily" {
		t.Errorf("schedule = %q, want daily", got)
	}
	if got := d.Get("frequency.0.cron_expression"); got != "" {
		t.Errorf("cron_expression = %q, want empty", got)
	}
}

func TestScheduleDiffSuppressed(t *testing.T) {
	f := ResourceTask().Schema["frequency"].Elem.(*schema.Resource).Schema["schedule"].DiffSuppressFunc
	for _, c := range [][2]string{{"advanced", "cron"}, {"cron", "advanced"}, {"CRON", "cron"}} {
		if !f("frequency.0.schedule", c[0], c[1], nil) {
			t.Errorf("%q -> %q should be suppressed", c[0], c[1])
		}
	}
	if f("frequency.0.schedule", "daily", "cron", nil) {
		t.Error("daily -> cron must not be suppressed")
	}
}

func TestGetTaskFromResourceDataBuildsCreatePayload(t *testing.T) {
	d := schema.TestResourceDataRaw(t, ResourceTask().Schema, map[string]interface{}{
		"type": "blobstore.compact",
		"name": "Compact all blob stores daily",
		"frequency": []interface{}{map[string]interface{}{
			"schedule":        "cron",
			"cron_expression": "0 15 4 * * ?",
		}},
		"properties": map[string]interface{}{"blobstoreName": "(All Blob Stores)", "blobsOlderThan": "3"},
	})
	got := getTaskFromResourceData(d)
	b, _ := json.Marshal(got)
	var m map[string]interface{}
	_ = json.Unmarshal(b, &m)
	freq, _ := m["frequency"].(map[string]interface{})
	if freq["schedule"] != "cron" || freq["cronExpression"] != "0 15 4 * * ?" {
		t.Errorf("frequency = %v", freq)
	}
	if m["enabled"] != true || m["notificationCondition"] != "FAILURE" {
		t.Errorf("defaults not applied: %s", b)
	}
	if props, _ := m["properties"].(map[string]interface{}); props["blobsOlderThan"] != "3" {
		t.Errorf("properties = %v", m["properties"])
	}
}
