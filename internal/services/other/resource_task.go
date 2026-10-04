package other

import (
	"fmt"
	"strings"

	nexus "github.com/datadrivers/go-nexus-client/nexus3"
	"github.com/datadrivers/go-nexus-client/nexus3/schema/task"
	"github.com/datadrivers/terraform-provider-nexus/internal/schema/common"
	"github.com/datadrivers/terraform-provider-nexus/internal/tools"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/validation"
)

func ResourceTask() *schema.Resource {
	return &schema.Resource{
		Description: "Use this resource to manage Nexus scheduled tasks.",

		Create: resourceTaskCreate,
		Read:   resourceTaskRead,
		Update: resourceTaskUpdate,
		Delete: resourceTaskDelete,
		Exists: resourceTaskExists,
		Importer: &schema.ResourceImporter{
			StateContext: schema.ImportStatePassthroughContext,
		},

		Schema: map[string]*schema.Schema{
			"id": common.ResourceID,
			"type": {
				Description: "The type of task (e.g., 'blobstore.compact', 'repository.docker.gc').",
				Type:        schema.TypeString,
				Required:    true,
				ForceNew:    true,
			},
			"name": {
				Description: "The name of the task.",
				Type:        schema.TypeString,
				Required:    true,
			},
			"enabled": {
				Description: "Whether the task is enabled.",
				Type:        schema.TypeBool,
				Optional:    true,
				Default:     true,
			},
			"alert_email": {
				Description: "Email address to send alerts to.",
				Type:        schema.TypeString,
				Optional:    true,
			},
			"notification_condition": {
				Description:  "When to send notifications. Possible values: `FAILURE`, `SUCCESS_FAILURE`. Default: `FAILURE`",
				Type:         schema.TypeString,
				Optional:     true,
				Default:      "FAILURE",
				ValidateFunc: validation.StringInSlice([]string{"FAILURE", "SUCCESS_FAILURE"}, false),
			},
			"frequency": {
				Description: "Frequency configuration for the task.",
				Type:        schema.TypeList,
				Required:    true,
				MaxItems:    1,
				Elem: &schema.Resource{
					Schema: map[string]*schema.Schema{
						"schedule": {
							Description:  "Schedule type. Possible values: `manual`, `cron`, `once`, `hourly`, `daily`, `weekly`, `monthly` (case-insensitive)",
							Type:         schema.TypeString,
							Required:     true,
							ValidateFunc: validation.StringInSlice([]string{"manual", "cron", "once", "hourly", "daily", "weekly", "monthly"}, true),
							DiffSuppressFunc: func(k, old, new string, d *schema.ResourceData) bool {
								// Normalize "advanced" from API to "cron" in state
								if strings.EqualFold(old, "advanced") && strings.EqualFold(new, "cron") {
									return true
								}
								if strings.EqualFold(old, "cron") && strings.EqualFold(new, "advanced") {
									return true
								}
								return strings.EqualFold(old, new)
							},
						},
						"cron_expression": {
							Description: "Cron expression (required when schedule is 'cron').",
							Type:        schema.TypeString,
							Optional:    true,
						},
						"start_date": {
							Description: "Start date for the schedule (Unix timestamp in milliseconds).",
							Type:        schema.TypeInt,
							Optional:    true,
						},
						"time_zone_offset": {
							Description: "Time zone offset (e.g., '-08:00').",
							Type:        schema.TypeString,
							Optional:    true,
						},
						"recurring_days": {
							Description: "Days of the week for recurring tasks (1=Sunday, 2=Monday, etc.).",
							Type:        schema.TypeList,
							Optional:    true,
							Elem: &schema.Schema{
								Type: schema.TypeInt,
							},
						},
					},
				},
			},
			"properties": {
				Description: "Task-specific configuration properties.",
				Type:        schema.TypeMap,
				Optional:    true,
				Elem: &schema.Schema{
					Type: schema.TypeString,
				},
			},
			"current_state": {
				Description: "Current state of the task (computed).",
				Type:        schema.TypeString,
				Computed:    true,
			},
			"last_run": {
				Description: "Timestamp of last run (computed).",
				Type:        schema.TypeString,
				Computed:    true,
			},
			"next_run": {
				Description: "Timestamp of next scheduled run (computed).",
				Type:        schema.TypeString,
				Computed:    true,
			},
			"last_run_result": {
				Description: "Result of last run (computed).",
				Type:        schema.TypeString,
				Computed:    true,
			},
		},
	}
}

func getTaskFromResourceData(d *schema.ResourceData) *task.TaskCreateStruct {
	t := &task.TaskCreateStruct{
		Type:                  d.Get("type").(string),
		Name:                  d.Get("name").(string),
		Enabled:               d.Get("enabled").(bool),
		AlertEmail:            d.Get("alert_email").(string),
		NotificationCondition: d.Get("notification_condition").(string),
	}

	if v, ok := d.GetOk("frequency"); ok {
		freqList := v.([]interface{})
		if len(freqList) > 0 {
			freqMap := freqList[0].(map[string]interface{})
			freq := &task.FrequencyXO{
				Schedule: freqMap["schedule"].(string),
			}

			if cronExpr, ok := freqMap["cron_expression"].(string); ok && cronExpr != "" {
				freq.CronExpression = cronExpr
			}
			if startDate, ok := freqMap["start_date"].(int); ok && startDate != 0 {
				freq.StartDate = startDate
			}
			if tzOffset, ok := freqMap["time_zone_offset"].(string); ok && tzOffset != "" {
				freq.TimeZoneOffset = tzOffset
			}
			if recurringDays, ok := freqMap["recurring_days"].([]interface{}); ok && len(recurringDays) > 0 {
				freq.RecurringDays = recurringDays
			}

			t.Frequency = freq
		}
	}

	if props, ok := d.GetOk("properties"); ok {
		properties := make(map[string]interface{})
		for k, v := range props.(map[string]interface{}) {
			properties[k] = v.(string)
		}
		t.Properties = properties
	}

	return t
}

func setTaskToResourceData(t *task.Task, d *schema.ResourceData) error {
	d.SetId(t.ID)
	d.Set("type", t.Type)
	d.Set("name", t.Name)
	d.Set("enabled", t.Enabled)
	d.Set("alert_email", t.AlertEmail)
	d.Set("notification_condition", t.NotificationCondition)
	d.Set("current_state", t.CurrentState)
	d.Set("last_run", t.LastRun)
	d.Set("next_run", t.NextRun)
	d.Set("last_run_result", t.LastRunResult)

	if t.Frequency != nil {
		// Normalize "advanced" schedule to "cron" to prevent perpetual drift
		schedule := t.Frequency.Schedule
		if strings.EqualFold(schedule, "advanced") {
			schedule = "cron"
		}

		freq := map[string]interface{}{
			"schedule": schedule,
		}
		if t.Frequency.CronExpression != "" {
			freq["cron_expression"] = t.Frequency.CronExpression
		}
		if t.Frequency.StartDate != 0 {
			freq["start_date"] = t.Frequency.StartDate
		}
		if t.Frequency.TimeZoneOffset != "" {
			freq["time_zone_offset"] = t.Frequency.TimeZoneOffset
		}
		if len(t.Frequency.RecurringDays) > 0 {
			freq["recurring_days"] = t.Frequency.RecurringDays
		}
		d.Set("frequency", []interface{}{freq})
	}

	if t.Properties != nil {
		properties := make(map[string]string)
		for k, v := range t.Properties {
			if str, ok := v.(string); ok {
				properties[k] = str
			} else {
				properties[k] = fmt.Sprintf("%v", v)
			}
		}
		d.Set("properties", properties)
	}

	return nil
}

func resourceTaskCreate(d *schema.ResourceData, m interface{}) error {
	client := m.(*nexus.NexusClient)
	taskData := getTaskFromResourceData(d)

	createdTask, err := client.Task.CreateTask(taskData)
	if err != nil {
		return err
	}

	d.SetId(createdTask.ID)
	return resourceTaskRead(d, m)
}

func resourceTaskRead(d *schema.ResourceData, m interface{}) error {
	client := m.(*nexus.NexusClient)

	t, err := client.Task.GetTask(d.Id())
	if err != nil {
		return err
	}

	if t == nil {
		d.SetId("")
		return nil
	}

	return setTaskToResourceData(t, d)
}

func resourceTaskUpdate(d *schema.ResourceData, m interface{}) error {
	client := m.(*nexus.NexusClient)
	taskData := getTaskFromResourceData(d)

	if err := client.Task.UpdateTask(d.Id(), taskData); err != nil {
		return err
	}

	return resourceTaskRead(d, m)
}

func resourceTaskDelete(d *schema.ResourceData, m interface{}) error {
	client := m.(*nexus.NexusClient)

	if err := client.Task.DeleteTask(d.Id()); err != nil {
		return err
	}

	d.SetId("")
	return nil
}

func resourceTaskExists(d *schema.ResourceData, m interface{}) (bool, error) {
	client := m.(*nexus.NexusClient)

	t, err := client.Task.GetTask(d.Id())
	return t != nil, err
}
