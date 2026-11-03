# AutoStopping Automation

Ready-made Harness pipelines that turn your cloud machines off when nobody needs them, so you stop paying for idle servers.

## What is this?

Harness has a feature called **AutoStopping**. You tell it which machines to manage and when they should be running. Outside those hours, Harness shuts the machines down and starts them again later.

Setting this up by hand in the Harness website is slow when you have many machines. This repository gives you four pipelines that do it for you:

| Pipeline | What it does | Changes anything? |
|---|---|---|
| **AutoStopping Rules Report** | Shows the AutoStopping rules you already have. | No, it only reads. |
| **AutoStopping Rule Create** | Creates a rule for all machines with a certain tag, and sets the hours they should stay on. | Yes |
| **AutoStopping Rule Delete** | Deletes one rule. | Yes |
| **AutoStopping Onboarding Config** | Tells Harness to find tagged machines by itself and create rules for them automatically, about once an hour. | Yes |

**Not sure where to start?** Run the **Report** first to see what exists, then use **Rule Create**.

## A few words you'll see

- **Pipeline**: a saved set of steps in Harness that you can run with one click.
- **Rule**: an AutoStopping setting that says "manage these machines".
- **Schedule**: the hours a rule's machines should stay **on**. Outside these hours they are stopped.
- **Tag**: a label on a cloud machine, written as `key = value`, for example `autostopping = yes`. Rules use tags to pick which machines to manage.
- **Connector**: the link between Harness and your cloud account (for example, your AWS account).
- **Dry run**: a practice mode. Harness pretends to stop the machines and shows how much you would save, but nothing is actually turned off. **All examples here use dry run, so they're safe to try.**
- **Variables / inputs**: the values you fill in each time you run a pipeline, such as the tag or the hours.

## What's in this repository

```
pipelines/   The four pipelines, ready to add to Harness
examples/    Filled-in example inputs for each pipeline
scripts/     Two optional helper scripts for running things from a terminal
```

---

## Setup (one time)

You need four things in Harness before the pipelines will work.

### 1. A Harness project

Pick the Harness project where the pipelines will live. You'll need its **org ID** and **project ID**. They're shown in the project's URL and under **Project Settings**.

The pipeline files use the placeholders `my_org` and `my_project`. Replace them with your own IDs, or let the import script (step 5 below) do it for you.

### 2. Harness Cloud builds

The pipelines run on machines that Harness provides ("Harness Cloud"), so you don't need your own build servers. Make sure Harness Cloud is turned on for your account. If you're not sure, ask your Harness admin.

### 3. An API key saved as a secret

The pipelines talk to Harness on your behalf, so they need an API key.

1. In Harness, create an API key: click your profile picture → **My API Keys** → **+ API Key** → **+ Token**, then copy the token.
   The key must be allowed to view, create and delete AutoStopping rules.
2. Save it as a secret: **Account Settings → Secrets → + New Secret → Text**.
   - Name it exactly **`harness_api_key`**.
   - Paste the token as the value.

If you want a different name, change `account.harness_api_key` in each pipeline file to match.

### 4. A cloud connector with AutoStopping turned on

Go to **Account Settings → Connectors** and find your AWS (Cloud Cost) connector. Make sure **Optimization / AutoStopping** is enabled on it.

Note down two things:
- the connector's **ID** (used for `CONNECTOR_ID`), and
- its **name** as shown on screen (used for `CONNECTOR_NAME`).

The examples use the placeholders `my_aws_ccm_connector` and `my-aws-ccm-connector`. Replace them with your values.

### 5. Add the pipelines to Harness

Choose **one** of these:

**Using the Harness website (easiest)**

For each file in the `pipelines/` folder:
1. In your project, go to **Pipelines → + Create a Pipeline**.
2. Give it any name, then switch from **Visual** to **YAML** at the top.
3. Delete what's there, paste the file's contents, and change `my_org` / `my_project` to your IDs.
4. Click **Save**.

**Using the script (if you're comfortable with a terminal)**

```sh
export HARNESS_API_KEY=pat.xxxxx          # your API key
export HARNESS_ACCOUNT_ID=your-account-id # shown in Account Settings → Overview
export HARNESS_ORG=my_org                 # your org ID
export HARNESS_PROJECT=my_project         # your project ID
scripts/import_pipelines.sh
```

The script adds all four pipelines and fills in your org and project for you. If a pipeline with the same name already exists, it reports an error for that one and moves on.

---

## How to run a pipeline

### Option 1: From the Harness website (recommended)

1. Open the pipeline in Harness.
2. Click **Run**.
3. Fill in the boxes. Some are already filled with a sensible default.
4. Click **Run Pipeline**.

To see what happened, open the run, click the stage, click the step, and open **Logs**.

### Option 2: From a terminal, using an example file

Copy a file from `examples/`, change the values, then run:

```sh
scripts/run_pipeline.sh <pipeline-id> <your-inputs-file>

# for example:
scripts/run_pipeline.sh autostopping_rules_report examples/rules_report.yaml
```

The script prints a link to the run so you can watch it in Harness. It uses the same four `export` lines shown in the setup step above.

### Important: put quotes around values in example files

Always write values in quotes, like `value: "yes"`, never `value: yes`. Without quotes, words like `yes`, `no`, `true` and `on` are read as true/false and Harness rejects the run.

---

## Pipeline 1: AutoStopping Rules Report

**When to use it:** to see which rules already exist before you create or delete anything. It changes nothing.

**What to fill in:**

| Input | Example | What it means |
|---|---|---|
| `CONNECTOR_ID` | `my_aws_ccm_connector` | Show full details of every rule on this connector. |
| `TAG_KEY` | `autostopping` | Also list any rule that uses this tag. |

**Example file:** `examples/rules_report.yaml`

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

**What you'll see in the logs:**

1. **Onboarding configs:** this always shows a "route not found" message. That's normal, because Harness doesn't offer a way to list them.
2. **All AutoStopping rules:** one line per rule, showing its ID, name, type, connector, whether it's disabled, whether it's a dry run, and its status.
3. **Rules on your connector:** full details for each one.
4. **Rules using your tag:** the matching rules and which machines they pick.

**Heads-up:** rules made by the **Rule Create** pipeline don't appear in this report, because of a limitation in Harness. To see them, open **Cloud Costs → AutoStopping Rules** in Harness.

---

## Pipeline 2: AutoStopping Rule Create

**When to use it:** you want machines with a certain tag to run only during set hours, for example office hours.

**What it does:**
1. Creates a rule that manages every machine with your tag, in one AWS region.
2. Adds a schedule that keeps those machines **on** during the hours you choose.
3. Outside those hours, Harness stops the machines, or only pretends to if dry run is on.

**What to fill in:**

| Input | Example | What it means |
|---|---|---|
| `RULE_NAME` | `autostopping-business-hours` | Any name you like. It's shown in Harness. |
| `CONNECTOR_ID` | `my_aws_ccm_connector` | Your connector's ID (from setup step 4). |
| `CONNECTOR_NAME` | `my-aws-ccm-connector` | Your connector's name as shown on screen. |
| `TAG_KEY` | `autostopping` | The tag name on your machines. |
| `TAG_VALUE` | `yes` | The tag value on your machines. |
| `REGION` | `us-east-1` | The AWS region the machines are in. One region per rule. |
| `IDLE_TIME` | `15` | How many minutes to wait before stopping an unused machine. |
| `DRY_RUN` | `true` | `true` = practice mode, nothing is stopped. `false` = really stop machines. |
| `SCHEDULE_NAME` | `business-hours-ist` | Any name for the schedule. |
| `TIME_ZONE` | `Asia/Kolkata` | The time zone for the hours below, e.g. `UTC`, `Europe/London`, `America/New_York`. |
| `UPTIME_DAYS` | `1,2,3,4,5` | Which days machines stay on. `0` = Sunday, `1` = Monday … `6` = Saturday. |
| `UPTIME_START` | `09:00` | When machines turn on (24-hour clock). |
| `UPTIME_END` | `18:00` | When machines turn off (24-hour clock). |

**Example 1: weekdays, 9 AM to 6 PM India time, practice mode**
File: `examples/rule_create_business_hours_ist.yaml`

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

**Example 2: every day, 8 AM to 8 PM New York time**
File: `examples/rule_create_us_hours_every_day.yaml`

Same as above, but with these values changed:

| Input | Value |
|---|---|
| `TAG_KEY` / `TAG_VALUE` | `Schedule` / `us-work-hours` |
| `REGION` | `us-west-2` |
| `IDLE_TIME` | `30` |
| `TIME_ZONE` | `America/New_York` |
| `UPTIME_DAYS` | `0,1,2,3,4,5,6` (every day) |
| `UPTIME_START` / `UPTIME_END` | `08:00` / `20:00` |

**What you'll see in the logs:** `Created rule <number>` and then `Attached schedule <number> to rule <number>`. Note the rule number; you'll need it to delete the rule later.

**Good to know:**
- **Run it only once per tag.** Running it again with the same tag creates a second, duplicate rule. If that happens, delete the extra one with the **Rule Delete** pipeline.
- **Ready to save money for real?** Check the estimated savings in **Cloud Costs → AutoStopping Rules** first. Then switch off dry run on the rule there, or create it with `DRY_RUN` set to `false`.
- **If the run fails after "Created rule…"**, the rule exists but has no schedule. Delete it, fix the inputs, and run again.
- **Don't combine with the Onboarding Config pipeline for the same tag.** Both would create rules for the same machines. Use one or the other.

---

## Pipeline 3: AutoStopping Rule Delete

**When to use it:** to remove a rule you no longer want, or a duplicate.

**What to fill in:**

| Input | Example | What it means |
|---|---|---|
| `RULE_ID` | `12345` | The rule's number. Find it in the Rule Create logs, in the Report, or at the end of the rule's web address in Harness. |

**Example file:** `examples/rule_delete.yaml`

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

**What it does:** shows you the rule's name and tag first (so you can confirm in the logs it was the right one), then deletes it.

> **Careful:** the delete happens straight away and can't be undone. Double-check the rule number before running.

---

## Pipeline 4: AutoStopping Onboarding Config

**When to use it:** you want Harness to keep finding tagged machines and create rules for them **automatically**, including machines added later.

**How it's different from Rule Create:** Rule Create makes one rule right now. This pipeline sets up a standing instruction. About once an hour, Harness looks for machines with your tag and creates rules for any it finds, up to a limit you choose.

**What to fill in:**

| Input | Example | What it means |
|---|---|---|
| `NAME` | `aws-autostopping-onboarding` | Any name for this setup. |
| `KIND` | `instance` | What to manage. Use `instance` for normal AWS machines (EC2). |
| `ENABLED` | `true` | `true` to turn it on. |
| `CONNECTOR_NAME_REGEX` | `^my-aws-ccm-connector$` | Which connectors to look in, by name. `^name$` means "exactly this one"; `.*` means "all". |
| `ALLOWED_PROVIDERS` | `aws` | Which cloud: `aws`, `azure` or `gcp`. |
| `TIME_ZONE` | `UTC` | Time zone for the schedule hours. |
| `RULE_LIMIT` | `10` | The most rules it's allowed to create. |
| `DRY_RUN` | `true` | Practice mode for the rules it creates. |
| `TAG_KEY` / `TAG_VALUE` | `autostopping` / `yes` | Only machines with this tag are picked up. Leave empty for no tag filter. |
| `IDLE_TIME` | `15` | Minutes of no use before stopping. |
| `DEFAULT_SCHEDULE` | `9-17` | Hours to stay on, written as `start-end` with no days (e.g. `9-17` means 9 AM to 5 PM). **Don't leave this empty.** |
| `SCHEDULE_TAG_KEY` | `EC2Schedule` | Optional. Lets a machine have its own hours through a tag, e.g. `EC2Schedule = Mon:9-17.Tue:9-17.Sat:off`. |
| `CONNECTOR_NAME_EXCLUDE` | *(empty)* | Optional. Connector names to skip. |
| `PATCH_KEY`, `PATCH_VALUE_1/2`, `PATCH_SCHEDULE_1/2` | *(empty)* | Optional. Give machines with a certain tag value different hours. Leave empty if you don't need it. |

**Example file:** `examples/onboarding_config_tag.yaml`

```sh
scripts/run_pipeline.sh autostopping_onboarding_config examples/onboarding_config_tag.yaml
```

**What happens next:** the run finishes in about a minute, but rules appear later, usually within an hour. Check **Cloud Costs → AutoStopping Rules** in Harness.

---

## Something went wrong?

| What you see | What it means | What to do |
|---|---|---|
| `HTTP 401` in the logs | The API key isn't valid, or it's in the wrong secret. | Check the `harness_api_key` secret holds a working key (setup step 3). |
| The run is rejected before it starts | A value like `yes` or `true` wasn't in quotes. | Put every value in quotes: `value: "yes"`. |
| The step fails straight after it starts, with "exit status 2" | A number or true/false box has something else in it. | Use only numbers for `IDLE_TIME` / `RULE_LIMIT`, and only `true` or `false` for `DRY_RUN` / `ENABLED`. |
| `default_schedule is required` or "invalid schedule" | `DEFAULT_SCHEDULE` is empty or includes days. | Use just hours, like `9-17`. |
| Two rules for the same tag | Rule Create was run twice. | Delete one with the Rule Delete pipeline. |
| A new rule isn't in the Report | Known Harness limitation. | Look in **Cloud Costs → AutoStopping Rules** instead. |
