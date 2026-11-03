# AutoStopping Automation

Harness pipelines that manage Harness CCM AutoStopping through the Lightwing API: register tag-based onboarding configs, create EC2 rules with fixed uptime schedules, report on existing rules, and delete rules.

All four pipelines are CI stages on Harness Cloud. Each runs one `Run` step in an `alpine:3.20` container that installs `curl` and `jq` and calls `https://app.harness.io/gateway/lw/api/...`.

| Pipeline | Identifier | Writes anything? | Purpose |
|---|---|---|---|
| AutoStopping Onboarding Config | `autostopping_onboarding_config` | Yes | Registers an onboarding config. A Harness background job (hourly) then creates rules for matching instances. |
| AutoStopping Rule Create | `autostopping_rule_create` | Yes | Creates one tag-based EC2 rule and attaches a fixed uptime schedule. |
| AutoStopping Rules Report | `autostopping_rules_report` | No | Lists rules, shows rules on one connector, and finds rules that filter on a given tag. |
| AutoStopping Rule Delete | `autostopping_rule_delete` | Yes | Prints one rule by ID, then deletes it. |

```
pipelines/   Pipeline YAML (import these into Harness)
examples/    Runtime input YAML for each pipeline, ready to run
scripts/     import_pipelines.sh and run_pipeline.sh (Harness REST API helpers)
```

## Prerequisites

1. **A Harness project.** The YAML uses placeholder org `my_org` and project `my_project`. To target your project, change `orgIdentifier` / `projectIdentifier` in each file, or let `scripts/import_pipelines.sh` rewrite them.
2. **Harness Cloud build infrastructure** enabled for CI. The step image is pulled through the built-in `account.harnessImage` Docker connector.
3. **An API key secret** named `harness_api_key` at account scope. It must hold a Harness API key (PAT or service-account token) with CCM AutoStopping view/create/delete permissions. The pipelines read it with `<+secrets.getValue("account.harness_api_key")>`; change that line in each pipeline if your secret has a different identifier or scope.
4. **A CCM AWS connector with Optimization (AutoStopping) enabled.** The examples use placeholder connector identifier `my_aws_ccm_connector` and display name `my-aws-ccm-connector`; replace both with your connector's values (**Account Settings → Connectors**).

## Install the pipelines

**Option A, Harness UI:** in the project go to **Pipelines → Create a Pipeline → Import from YAML** (or create an empty pipeline, switch to the YAML view and paste) for each file in `pipelines/`.

**Option B, script:**

```sh
export HARNESS_API_KEY=pat.xxxxx      # key with pipeline create permission
export HARNESS_ACCOUNT_ID=<your account id>
export HARNESS_ORG=my_org
export HARNESS_PROJECT=my_project
scripts/import_pipelines.sh
```

The script POSTs each file to `/pipeline/api/pipelines/v2`. A pipeline that already exists returns an error for that file; edit it in the UI or delete it first.

## How to run a pipeline

Every pipeline takes its settings as **pipeline variables** that are runtime inputs (`<+input>`). You can supply them three ways.

**1. Harness UI:** open the pipeline → **Run** → fill in the variables → **Run Pipeline**. Fields with a default are pre-filled.

**2. Script with an example file:**

```sh
scripts/run_pipeline.sh autostopping_rules_report examples/rules_report.yaml
```

It prints the execution ID and a link to the run. Copy an example file and edit the values to make your own.

**3. Raw API call:**

```sh
curl -X POST \
  "https://app.harness.io/pipeline/api/pipeline/execute/autostopping_rules_report?accountIdentifier=$HARNESS_ACCOUNT_ID&orgIdentifier=$HARNESS_ORG&projectIdentifier=$HARNESS_PROJECT&moduleType=ci" \
  -H "x-api-key: $HARNESS_API_KEY" \
  -H "Content-Type: application/yaml" \
  --data-binary @examples/rules_report.yaml
```

**Always quote values in input YAML.** Unquoted `yes`, `no`, `true` and `on` are parsed as YAML booleans and Harness rejects them as String variables. Write `value: "yes"`, not `value: yes`.

To see a step's output, open the execution → **Create Rule / Report / Delete Rule** stage → the Run step → **Logs**.

---

## AutoStopping Rules Report

Read-only. Use it before creating anything, to see what already exists.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `CONNECTOR_ID` | yes | `my_aws_ccm_connector` | CCM connector identifier whose rules are printed in full |
| `TAG_KEY` | yes | `autostopping` | Prints every rule whose definition mentions this tag key |

Example (`examples/rules_report.yaml`):

```yaml
pipeline:
  identifier: autostopping_rules_report
  variables:
    - name: CONNECTOR_ID
      type: String
      value: "my_aws_ccm_connector"
    - name: TAG_KEY
      type: String
      value: "autostopping"
```

Output sections in the log:

1. **Onboarding configs.** Currently returns HTTP 404 `route not found`, because the API has no list endpoint for onboarding configs. This is expected.
2. **All AutoStopping rules (summary).** One tab-separated line per rule: `id  name  kind  connector  disabled  dry_run  status`.
3. **Rules on connector `<CONNECTOR_ID>`.** Full JSON for those rules.
4. **Rules whose definition mentions tag `<TAG_KEY>`.** ID, name, connector and the instance filter.

Known limitation: the list endpoint (`GET /autostopping/rules`) does **not** return rules created through the v2 API, including rules made by the Rule Create pipeline. Check those in **Cloud Costs → AutoStopping Rules** in the UI.

---

## AutoStopping Rule Create

Creates one EC2 rule that selects instances by tag, then attaches a fixed **uptime** schedule. There is no load balancer or proxy, so Harness treats the instances as idle and stops them outside the uptime window. Inside the window they are kept running.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `RULE_NAME` | yes | | Rule name shown in the UI |
| `CONNECTOR_ID` | yes | `my_aws_ccm_connector` | CCM AWS connector identifier |
| `CONNECTOR_NAME` | yes | `my-aws-ccm-connector` | Connector display name (stored in rule metadata) |
| `TAG_KEY` | yes | | EC2 tag key used to select instances |
| `TAG_VALUE` | yes | | EC2 tag value used to select instances (quote it) |
| `REGION` | yes | `us-east-1` | AWS region of the instances; one region per rule |
| `IDLE_TIME` | yes | `15` | Idle minutes before stopping (number) |
| `DRY_RUN` | yes | `true` | `true` simulates and estimates savings only; `false` really stops instances |
| `SCHEDULE_NAME` | yes | | Name of the uptime schedule |
| `TIME_ZONE` | yes | `Asia/Kolkata` | IANA time zone for the schedule, e.g. `UTC`, `America/New_York` |
| `UPTIME_DAYS` | yes | `1,2,3,4,5` | Comma-separated days, `0`=Sunday … `6`=Saturday |
| `UPTIME_START` | yes | `09:00` | Start of the uptime window, `HH:MM` 24-hour |
| `UPTIME_END` | yes | `18:00` | End of the uptime window, `HH:MM` 24-hour |

**Example 1: 9 AM–6 PM IST on weekdays, dry run** (`examples/rule_create_business_hours_ist.yaml`).
```yaml
pipeline:
  identifier: autostopping_rule_create
  variables:
    - name: RULE_NAME
      type: String
      value: "autostopping-business-hours"
    - name: CONNECTOR_ID
      type: String
      value: "my_aws_ccm_connector"
    - name: CONNECTOR_NAME
      type: String
      value: "my-aws-ccm-connector"
    - name: TAG_KEY
      type: String
      value: "autostopping"
    - name: TAG_VALUE
      type: String
      value: "yes"
    - name: REGION
      type: String
      value: "us-east-1"
    - name: IDLE_TIME
      type: String
      value: "15"
    - name: DRY_RUN
      type: String
      value: "true"
    - name: SCHEDULE_NAME
      type: String
      value: "business-hours-ist"
    - name: TIME_ZONE
      type: String
      value: "Asia/Kolkata"
    - name: UPTIME_DAYS
      type: String
      value: "1,2,3,4,5"
    - name: UPTIME_START
      type: String
      value: "09:00"
    - name: UPTIME_END
      type: String
      value: "18:00"
```

```sh
scripts/run_pipeline.sh autostopping_rule_create examples/rule_create_business_hours_ist.yaml
```

**Example 2: 8 AM–8 PM New York time every day, different tag and region** (`examples/rule_create_us_hours_every_day.yaml`). The values that differ are `TAG_KEY=Schedule`, `TAG_VALUE=us-work-hours`, `REGION=us-west-2`, `IDLE_TIME=30`, `TIME_ZONE=America/New_York`, `UPTIME_DAYS=0,1,2,3,4,5,6`, `UPTIME_START=08:00` and `UPTIME_END=20:00`.

What the step does:

1. Lists rules and looks for one on `CONNECTOR_ID` whose filter already has `TAG_KEY=TAG_VALUE`. If found, it reuses that rule instead of creating one.
2. Otherwise it POSTs `/autostopping/v2/rules` and logs `Created rule <id>`.
3. Lists schedules on the rule and stops if one named `SCHEDULE_NAME` is already attached.
4. Otherwise it POSTs `/schedules` and logs `Attached schedule <id> to rule <id>`.

Things to know:

- **Do not re-run for the same tag.** Because of the list limitation described under the report pipeline, step 1 cannot see rules created by this pipeline, so a re-run creates a duplicate rule. If that happens, delete the extra one with the Delete pipeline.
- **Going live:** create with `DRY_RUN` `"false"`, or turn off dry run on the rule in the UI after checking the simulated savings.
- **A failed schedule step leaves the rule in place.** Fix the inputs, delete the rule (or attach a schedule in the UI), then run again.
- If the onboarding config below is also active for the same tag, it may create its own rule for the same instances. Keep only one.

---

## AutoStopping Rule Delete

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `RULE_ID` | yes | | Numeric rule ID (from the Create log, the Report, or the rule URL in the UI) |

Example (`examples/rule_delete.yaml`):

```yaml
pipeline:
  identifier: autostopping_rule_delete
  variables:
    - name: RULE_ID
      type: String
      value: "12345"
```

```sh
scripts/run_pipeline.sh autostopping_rule_delete examples/rule_delete.yaml
```

The step first GETs `/autostopping/v2/rules/<RULE_ID>` and prints the rule's ID, name, connector, status and tag filter, then calls `DELETE /autostopping/rules/<RULE_ID>`. It fails if the delete returns a non-2xx status. **Deletion is immediate and there is no confirmation**, so check the ID with the Report pipeline or the UI first. Schedules attached to the rule are no longer applied once the rule is gone.

---

## AutoStopping Onboarding Config

Registers an onboarding config. It does not create rules itself: a Harness background job runs about every hour, finds instances on matching connectors that carry the tag, and creates rules for them (up to `RULE_LIMIT`).

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `NAME` | yes | | Config name |
| `KIND` | yes | | Resource kind; `instance` for EC2 |
| `ENABLED` | yes | `true` | Enable the config |
| `CONNECTOR_NAME_REGEX` | no | `.*` | Regex on connector **display names**; `^my-aws-ccm-connector$` matches one connector |
| `ALLOWED_PROVIDERS` | yes | | `aws`, `azure` or `gcp` |
| `TIME_ZONE` | yes | `UTC` | Time zone for schedules |
| `RULE_LIMIT` | yes | `10` | Maximum rules the job may create |
| `DRY_RUN` | yes | `true` | Created rules run in dry-run mode |
| `TAG_KEY` / `TAG_VALUE` | no | empty | Only instances with this tag are onboarded; empty means no tag filter |
| `IDLE_TIME` | yes | `15` | Idle minutes for created rules |
| `DEFAULT_SCHEDULE` | effectively yes | empty | Uptime hours as `start-end`, e.g. `9-17`. The API rejects empty values and day prefixes such as `Mon:9-17` |
| `SCHEDULE_TAG_KEY` | no | empty | Instance tag holding a per-instance schedule, e.g. `EC2Schedule` with value `Mon:9-17.Tue:9-17.Sat:off` |
| `CONNECTOR_NAME_EXCLUDE` | no | empty | Connector names to skip |
| `PATCH_KEY` | no | empty | Tag key for schedule overrides; `patch_schedule` is only sent when this is set |
| `PATCH_VALUE_1` / `PATCH_SCHEDULE_1` | no | empty | First override: instances with `PATCH_KEY=PATCH_VALUE_1` get `PATCH_SCHEDULE_1` |
| `PATCH_VALUE_2` / `PATCH_SCHEDULE_2` | no | empty | Second override; entries with an empty value are dropped |

Example (`examples/onboarding_config_tag.yaml`):

```sh
scripts/run_pipeline.sh autostopping_onboarding_config examples/onboarding_config_tag.yaml
```

Key values in that file: `NAME="aws-autostopping-onboarding"`, `KIND="instance"`, `CONNECTOR_NAME_REGEX="^my-aws-ccm-connector$"`, `ALLOWED_PROVIDERS="aws"`, `TAG_KEY="autostopping"`, `TAG_VALUE="yes"`, `DEFAULT_SCHEDULE="9-17"`, `SCHEDULE_TAG_KEY="EC2Schedule"`, `DRY_RUN="true"`.

The step logs the request body and the API response, and fails on a non-2xx status.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| HTTP 401 from the Lightwing API | Secret doesn't hold a valid key for this account | Put a valid key in `harness_api_key`, or point the pipelines at another secret |
| Step exits with status 2 right after `apk add` | A JSON value (`ENABLED`, `DRY_RUN`, `RULE_LIMIT`, `IDLE_TIME`) isn't valid JSON | Use `true`/`false` and plain numbers |
| `parameter null` / unbound variable errors | Harness doesn't export environment variables whose value is empty | The pipelines already default optional variables; keep that line if you edit the script |
| Run rejected before starting: value is not a string | Unquoted `yes`/`true` in input YAML | Quote every value |
| `default_schedule is required` or invalid schedule | Empty or day-prefixed `DEFAULT_SCHEDULE` | Use `start-end`, e.g. `9-17` |
| `parsing time ... as "2006-01-02T15:04:05Z07:00"` on schedules | Non-RFC 3339 timestamp | Already fixed in Rule Create; keep the `date -u '+%Y-%m-%dT%H:%M:%SZ'` format |
| Duplicate rules after re-running Rule Create | List API doesn't return v2-created rules | Delete the extra rule with Rule Delete |
